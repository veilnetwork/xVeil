import 'dart:collection';
import 'dart:math';

import 'package:meta/meta.dart' show visibleForTesting;

/// RAM-only indirection between a notification and what it is about.
///
/// ## Why this exists
///
/// `NotificationPreview.hidden` neutralises the title and body, so the lock
/// screen says only that something arrived. The PAYLOAD did not follow: the
/// conversation / group / space identifier was handed to the OS regardless, so
/// the system notification database accumulated a record of who the user talks
/// to — outside the hidden volume, readable by any forensic tool that dumps it,
/// and surviving long after the app is locked (audit XV-03).
///
/// A neutral banner over a stored social graph is worse than no hiding at all:
/// it tells the user they are covered when the durable artifact says otherwise.
///
/// So in hidden mode the OS gets a random token that means nothing to anyone
/// but this process, and the mapping back lives here — in memory, for this
/// unlocked session only. Lock the app and the tokens stop resolving, which is
/// the same lifetime the rest of the unlocked state has.
///
/// Full-preview mode is unchanged: the title already names the sender, so an
/// opaque payload would cost tap-routing and buy nothing.
class OpaqueNotificationPayloads {
  OpaqueNotificationPayloads({Random? random, this.capacity = _defaultCapacity})
      : _random = random ?? Random.secure();


  /// Tokens kept before the oldest is dropped.
  ///
  /// One id is reused for message alerts, but spaces, groups and comments each
  /// mint their own, and a mailbox replay can produce a burst. This bounds what
  /// a long session accumulates; a dropped token means a tap opens the app
  /// rather than the exact chat, which is a far smaller cost than unbounded
  /// growth.
  static const _defaultCapacity = 256;

  final Random _random;
  final int capacity;

  /// token → the real payload. Insertion-ordered so eviction is oldest-first.
  final LinkedHashMap<String, String> _live = LinkedHashMap<String, String>();

  /// Mint a token standing in for [payload].
  ///
  /// Repeated calls for the same payload return a NEW token: a stable one would
  /// be a per-conversation identifier by another name, and the OS database
  /// would once again hold something that correlates alerts to each other.
  String mint(String payload) {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final token =
        'op:${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    _live[token] = payload;
    while (_live.length > capacity) {
      _live.remove(_live.keys.first);
    }
    return token;
  }

  /// Resolve a token back to its payload, or null if it is not ours.
  ///
  /// Does NOT consume: the OS may deliver the same notification tap more than
  /// once (a re-tap after the app is foregrounded), and refusing the second one
  /// would look like a broken notification. The token dies with the session.
  String? resolve(String token) => _live[token];

  /// Forget every token. Called on lock, alongside cancelling the alerts
  /// themselves — a token that outlived its session would be a dangling
  /// reference to a conversation this process may no longer be able to open.
  void clear() => _live.clear();

  /// Test-facing: a map that only grows is the failure this cap exists for.
  int get length => _live.length;
}

/// Whether [payload] is one of our opaque tokens.
bool isOpaqueNotificationToken(String payload) => payload.startsWith('op:');

/// Which identity a shown notification belongs to.
///
/// A notification outlives the session that posted it: Android keeps it until
/// somebody dismisses it, and the app can switch identity underneath — through
/// the local API, in the background, with nobody looking. The inline reply
/// callback then took the CURRENT services and sent from whichever identity
/// happened to be active.
///
/// That is not a wrong-window mistake. It is a message going out from an
/// identity that never had that conversation, which tells the person on the
/// other end that the two identities are the same device — the one thing a
/// deniable app must not say (report16 X16-H2).
///
/// So a reply is attributable or it is not sent. Kept in memory only, and by
/// design: a restart leaves every earlier notification unattributable, and
/// refusing there is the safe direction. Opening the chat still works — that
/// costs nothing and says nothing.
class NotificationOwners {
  NotificationOwners({this.capacity = 256});

  /// Bounded like the token store beside it, and for the same reason: a long
  /// session with a mailbox replay must not grow without limit. The oldest
  /// entry falling out means a reply is refused, not misattributed.
  final int capacity;

  final _owners = <String, String>{};

  /// Remember that [payload] was shown while [identity] was active.
  void remember(String payload, String? identity) {
    if (identity == null || identity.isEmpty) return;
    _owners.remove(payload);
    _owners[payload] = identity;
    while (_owners.length > capacity) {
      _owners.remove(_owners.keys.first);
    }
  }

  /// Whether [payload] may be replied to from [identity].
  ///
  /// False for a payload nobody recorded: an unattributable reply is the case
  /// this exists to refuse, not a case to wave through.
  bool mayReplyAs(String payload, String? identity) =>
      identity != null && identity.isNotEmpty && _owners[payload] == identity;

  void clear() => _owners.clear();

  @visibleForTesting
  int get debugLength => _owners.length;
}
