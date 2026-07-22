// Group service (groups epic, phase 0, brick 3): create groups, sign + append
// control-log ops and messages, persist everything in the deniable store, and
// expose the folded state + validated message list. No wire/DHT yet — this is
// the local substance a peer-sync brick will later drive.
//
// Persistence (settings JSON in the deniable store):
//   'groups.index'      -> ["<groupId hex>", ...]
//   'group:<id>'        -> manifest + control/messages/posts/reactions/epochs
//
// The identity crypto (native ed25519) sits behind an injectable [GroupSigner]
// so the whole service is unit-tested with a fake — the real signer wraps
// group_crypto + the app's deniable identity TOML.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:veil_flutter/veil_ffi.dart' as veil;

import '../core/ids.dart';
import '../core/log.dart';
import '../domain/chat.dart' show ContactStatus;
import '../domain/call_signal.dart';
import '../domain/device_sync.dart';
import '../domain/device_link.dart';
import '../domain/group.dart';
import '../domain/group_call.dart';
import '../domain/group_content.dart';
import '../domain/group_epoch.dart';
import '../domain/group_message.dart';
import '../domain/group_payload.dart';
import '../domain/group_policy.dart';
import '../domain/group_reaction.dart';
import '../domain/inline_custom_emoji.dart';
import '../domain/space_channel.dart';
import '../domain/space_invite.dart';
import '../domain/space_join_request.dart';
import '../domain/space_lifecycle.dart';
import '../domain/space_moderation.dart';
import '../domain/space_post.dart';
import '../domain/space_recommendation.dart';
import '../domain/space_retention.dart';
import '../domain/space_rules.dart';
import '../data/transport/bootstrap_invite.dart';
import '../data/storage/storage.dart';
import 'group_crypto.dart';
import 'group_epoch_service.dart';

bool _listEquals<T>(List<T>? left, List<T>? right) {
  if (identical(left, right)) return true;
  if (left == null || right == null || left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final RegExp _channelKeyIdPattern = RegExp(r'^[0-9a-f]{64}:[1-9][0-9]*$');
final RegExp _spacePostIdPattern = RegExp(r'^[0-9a-f]{64}:[0-9]+$');

String _channelKeyId(NodeId channelId, int epoch) => '${channelId.hex}:$epoch';

bool _validChannelKeyId(String value) {
  if (!_channelKeyIdPattern.hasMatch(value)) return false;
  final separator = value.lastIndexOf(':');
  final epoch = int.tryParse(value.substring(separator + 1));
  return epoch != null && epoch > 0 && epoch <= 0xffffffff;
}

/// SHA-256 here hashes only public manifests and encrypted credential blobs.
/// Keep this protocol primitive in the pure-Dart group core so ordinary group
/// and adoption tests do not require loading the native identity library.
Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(crypto.sha256.convert(bytes).bytes);

int _compareXorDistance(NodeId origin, NodeId left, NodeId right) {
  for (var i = 0; i < origin.bytes.length; i++) {
    final l = origin.bytes[i] ^ left.bytes[i];
    final r = origin.bytes[i] ^ right.bytes[i];
    if (l != r) return l.compareTo(r);
  }
  return left.hex.compareTo(right.hex);
}

/// Deterministically selects the [k] node ids closest to [self] by XOR
/// distance. Duplicate ids and [self] are ignored; callers do not need to
/// preserve any particular membership iteration order.
List<NodeId> nearestGroupNodesByXor(
  NodeId self,
  Iterable<NodeId> members, {
  int k = GroupService.kGroupSyncNeighbors,
}) {
  if (k <= 0) return const [];
  final unique = <String, NodeId>{
    for (final member in members)
      if (member != self) member.hex: member,
  }.values.toList();
  unique.sort((left, right) => _compareXorDistance(self, left, right));
  return unique.length <= k ? unique : unique.sublist(0, k);
}

/// Flutter-free change signal used by both the GUI provider and headless host.
/// It intentionally mirrors the tiny `ValueNotifier<int>` surface the group
/// list needs without pulling the Flutter engine into the group core.
final class GroupChangeSignal {
  int _value = 0;
  bool _disposed = false;
  final List<void Function()> _listeners = <void Function()>[];
  final StreamController<int> _controller = StreamController<int>.broadcast(
    sync: true,
  );

  int get value => _value;
  Stream<int> get stream => _controller.stream;

  set value(int next) {
    if (_disposed || next == _value) return;
    _value = next;
    _controller.add(next);
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void addListener(void Function() listener) {
    if (_disposed) return;
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    unawaited(_controller.close());
  }
}

/// The identity operations the service needs — injectable for tests.
abstract class GroupSigner {
  /// Our own node id + public key (the genesis material when we create).
  NodeId get selfId;
  Uint8List get selfPubKey;

  SpaceManifest signSpaceManifest(SpaceManifest unsigned);
  ControlEntry signControl(ControlEntry unsigned);
  GroupMessage signMessage(GroupMessage unsigned);
  GroupReaction signReaction(GroupReaction unsigned);
  SpacePost signPost(SpacePost unsigned);
  GroupContentRequest signContentRequest(GroupContentRequest unsigned);
  GroupCallSignal signCallSignal(GroupCallSignal unsigned);
  bool verifyControl(ControlEntry e);
  bool verifyMessage(GroupMessage m);
  bool verifyReaction(GroupReaction r);
  bool verifyPost(SpacePost post);
  bool verifyContentRequest(GroupContentRequest r);
  bool verifyCallSignal(GroupCallSignal signal);
  bool verifySpaceManifest(SpaceManifest manifest);
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  });
}

abstract class SovereignGroupSigner {
  String get algorithm;
  NodeId get nodeId;
  Uint8List get publicKey;
  Uint8List sign(Uint8List message);
  void close();
}

/// Opaque native recovery signer. The eventual normal path decrypts the local
/// sovereign bundle; this phrase-derived path remains the recovery bootstrap.
final class NativeSovereignGroupSigner implements SovereignGroupSigner {
  NativeSovereignGroupSigner._(this._inner);
  final veil.VeilSovereignSigner _inner;

  factory NativeSovereignGroupSigner.openRecoveryPhrase(String phrase) =>
      NativeSovereignGroupSigner._(veil.VeilSovereignSigner.open(phrase));

  factory NativeSovereignGroupSigner.openBundle(
    Uint8List bundle,
    String phrase,
  ) => NativeSovereignGroupSigner._(
    veil.VeilSovereignSigner.openBundle(bundle, phrase),
  );

  factory NativeSovereignGroupSigner.openRecoveryCertificate(
    Uint8List certificate,
    String recoveryCode,
  ) => NativeSovereignGroupSigner._(
    veil.VeilSovereignSigner.openRecoveryCertificate(certificate, recoveryCode),
  );

  @override
  String get algorithm => _inner.algorithm;
  @override
  NodeId get nodeId => NodeId(Uint8List.fromList(_inner.nodeId));
  @override
  Uint8List get publicKey => Uint8List.fromList(_inner.publicKey);
  @override
  Uint8List sign(Uint8List message) => _inner.sign(message);
  @override
  void close() => _inner.close();
}

/// Real signer: native ed25519 over the deniable identity TOML.
class NativeGroupSigner implements GroupSigner {
  NativeGroupSigner({
    required this.identityToml,
    required this._selfId,
    required this._selfPubKey,
    this.lib,
  });

  final String identityToml;
  final DynamicLibrary? lib;
  final NodeId _selfId;
  final Uint8List _selfPubKey;

  @override
  NodeId get selfId => _selfId;
  @override
  Uint8List get selfPubKey => _selfPubKey;

  @override
  SpaceManifest signSpaceManifest(SpaceManifest unsigned) =>
      signSpaceGenesisManifest(
        identityToml: identityToml,
        unsigned: unsigned,
        lib: lib,
      );

  @override
  ControlEntry signControl(ControlEntry unsigned) => signControlEntry(
    identityToml: identityToml,
    unsigned: unsigned,
    lib: lib,
  );
  @override
  GroupMessage signMessage(GroupMessage unsigned) => signGroupMessage(
    identityToml: identityToml,
    unsigned: unsigned,
    lib: lib,
  );
  @override
  GroupReaction signReaction(GroupReaction unsigned) => signGroupReaction(
    identityToml: identityToml,
    unsigned: unsigned,
    lib: lib,
  );
  @override
  SpacePost signPost(SpacePost unsigned) =>
      signSpacePost(identityToml: identityToml, unsigned: unsigned, lib: lib);
  @override
  GroupContentRequest signContentRequest(GroupContentRequest unsigned) =>
      signGroupContentRequest(
        identityToml: identityToml,
        unsigned: unsigned,
        lib: lib,
      );
  @override
  GroupCallSignal signCallSignal(GroupCallSignal unsigned) =>
      signGroupCallSignal(
        identityToml: identityToml,
        unsigned: unsigned,
        lib: lib,
      );
  @override
  bool verifyControl(ControlEntry e) => verifyControlEntry(e, lib: lib);
  @override
  bool verifyMessage(GroupMessage m) => verifyGroupMessage(m, lib: lib);
  @override
  bool verifyReaction(GroupReaction r) => verifyGroupReaction(r, lib: lib);
  @override
  bool verifyPost(SpacePost post) => verifySpacePost(post, lib: lib);
  @override
  bool verifyContentRequest(GroupContentRequest r) =>
      verifyGroupContentRequest(r, lib: lib);
  @override
  bool verifyCallSignal(GroupCallSignal signal) =>
      verifyGroupCallSignal(signal, lib: lib);
  @override
  bool verifySpaceManifest(SpaceManifest manifest) =>
      verifySpaceGenesisManifest(manifest, lib: lib);
  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) {
    return veil.verifySovereignSignature(
      algorithm: algorithm,
      nodeId: nodeId.bytes,
      publicKey: publicKey,
      message: message,
      signature: signature,
    );
  }
}

/// One group's stored data.
class GroupBundle {
  GroupBundle({
    required this.manifest,
    required this.control,
    required this.messages,
    this.posts = const [],
    this.reactions = const [],
    this.epochEnvelopes = const [],
    this.localEpochKeys = const {},
    this.channelEpochEnvelopes = const [],
    this.localChannelEpochKeys = const {},
    this.sovereignBundle,
  });
  final GroupManifest manifest;
  final List<ControlEntry> control;
  final List<GroupMessage> messages;
  final List<SpacePost> posts;
  final List<GroupReaction> reactions;

  /// Recipient-specific ML-KEM records. A creator keeps every record it
  /// minted so direct fanout can be tailored per recipient; a receiver stores
  /// only records addressed to itself. These are sealed and safe to persist.
  final List<GroupEpochRecipientEnvelope> epochEnvelopes;

  /// Decrypted epoch keys live only in the deniable hidden-volume bundle.
  /// They are deliberately omitted from every wire snapshot/delta.
  final Map<int, Uint8List> localEpochKeys;

  /// Same recipient-specific ML-KEM primitive, scoped by channel id rather
  /// than Space id. Unauthorized members never receive one of these records.
  final List<GroupEpochRecipientEnvelope> channelEpochEnvelopes;

  /// `<channelId hex>:<epoch>` -> decrypted 32-byte key, hidden-volume only.
  final Map<String, Uint8List> localChannelEpochKeys;
  final Uint8List? sovereignBundle;

  GroupBundle copyWith({
    GroupManifest? manifest,
    List<ControlEntry>? control,
    List<GroupMessage>? messages,
    List<SpacePost>? posts,
    List<GroupReaction>? reactions,
    List<GroupEpochRecipientEnvelope>? epochEnvelopes,
    Map<int, Uint8List>? localEpochKeys,
    List<GroupEpochRecipientEnvelope>? channelEpochEnvelopes,
    Map<String, Uint8List>? localChannelEpochKeys,
    Uint8List? sovereignBundle,
  }) => GroupBundle(
    manifest: manifest ?? this.manifest,
    control: control ?? this.control,
    messages: messages ?? this.messages,
    posts: posts ?? this.posts,
    reactions: reactions ?? this.reactions,
    epochEnvelopes: epochEnvelopes ?? this.epochEnvelopes,
    localEpochKeys: localEpochKeys ?? this.localEpochKeys,
    channelEpochEnvelopes: channelEpochEnvelopes ?? this.channelEpochEnvelopes,
    localChannelEpochKeys: localChannelEpochKeys ?? this.localChannelEpochKeys,
    sovereignBundle: sovereignBundle ?? this.sovereignBundle,
  );
}

class GroupLogCompaction {
  const GroupLogCompaction({
    required this.messagesBefore,
    required this.messagesAfter,
    required this.postsBefore,
    required this.postsAfter,
    required this.controlBefore,
    required this.controlAfter,
    required this.reactionsBefore,
    required this.reactionsAfter,
  });

  final int messagesBefore;
  final int messagesAfter;
  final int postsBefore;
  final int postsAfter;
  final int controlBefore;
  final int controlAfter;
  final int reactionsBefore;
  final int reactionsAfter;

  bool get changed =>
      messagesBefore != messagesAfter ||
      postsBefore != postsAfter ||
      controlBefore != controlAfter ||
      reactionsBefore != reactionsAfter;
}

class SpaceDeletionSweep {
  const SpaceDeletionSweep({
    required this.scanned,
    required this.purged,
    required this.pending,
    required this.failed,
  });

  final int scanned;
  final int purged;
  final int pending;
  final int failed;
}

/// Result of an idempotent local legacy-group -> signed-Space migration.
class SpaceManifestMigration {
  const SpaceManifestMigration({
    required this.scanned,
    required this.upgraded,
    required this.alreadyCurrent,
    required this.notOwner,
    required this.failed,
  });

  final int scanned;
  final int upgraded;
  final int alreadyCurrent;
  final int notOwner;
  final int failed;
}

/// Ships a group snapshot [bundleJson] durably to [peer] (direct fanout, v1).
typedef GroupSnapshotSender =
    Future<void> Function(NodeId peer, NodeId groupId, String bundleJson);

typedef SpaceInviteSender =
    Future<void> Function(NodeId peer, String inviteId, String inviteJson);
typedef SpaceInviteDecisionSender =
    Future<void> Function(NodeId peer, String inviteId, String decisionJson);
typedef SpaceJoinRequestSender =
    Future<void> Function(NodeId peer, String requestId, String requestJson);
typedef SpaceJoinDecisionSender =
    Future<void> Function(NodeId peer, String requestId, String decisionJson);
typedef SpaceRecommendationSender =
    Future<bool> Function(NodeId peer, SpaceRecommendationCard card);

typedef GroupCallFrameSender =
    Future<void> Function(
      NodeId peer,
      GroupCallSignal signal,
      String frameJson,
    );

class GroupService {
  GroupService(
    this._storage,
    this._signer, {
    this._send,
    this.sendSpaceInvite,
    this.sendSpaceInviteDecision,
    this.sendSpaceJoinRequest,
    this.sendSpaceJoinDecision,
    this.sendSpaceRecommendation,
    this._epochService,
    this.ourCertVersion = 1,
    this.sendContentRequest,
    this.sendGroupCallFrame,
    this.grantContentServe,
    this.startContentPull,
    this.startContentPullFromAny,
    this.contentRequestFanoutTimeout = const Duration(seconds: 8),
    this.contentGrantDelay = const Duration(seconds: 4),
  });
  final Storage _storage;
  final GroupSigner _signer;
  final GroupSnapshotSender? _send;
  final SpaceInviteSender? sendSpaceInvite;
  final SpaceInviteDecisionSender? sendSpaceInviteDecision;
  final SpaceJoinRequestSender? sendSpaceJoinRequest;
  final SpaceJoinDecisionSender? sendSpaceJoinDecision;
  final SpaceRecommendationSender? sendSpaceRecommendation;
  final GroupEpochService? _epochService;
  final int ourCertVersion;

  /// Ships a signed content-fetch request to the holder (wire layer).
  final Future<void> Function(NodeId holder, String requestJson)?
  sendContentRequest;

  /// Ships a short-lived encrypted call-control frame to one current member.
  final GroupCallFrameSender? sendGroupCallFrame;

  /// Opens the serve gate for an authorized member (wire layer grant).
  final void Function(NodeId peer, String cid)? grantContentServe;

  /// Starts the standard content pull of [cid] from a holder (wire layer).
  final Future<void> Function(NodeId holder, String cid)? startContentPull;

  /// Starts a membership-scoped pull from every current candidate member.
  /// The messaging layer tries holders until one actually has the verified
  /// blob; no persistent/read-receipt holder advertisement is created.
  final Future<void> Function(List<NodeId> holders, String cid)?
  startContentPullFromAny;

  /// Bounds only the foreground wait for durable request fanout. The durable
  /// sends keep running after this deadline; an offline member must not delay
  /// a reachable seeder indefinitely.
  final Duration contentRequestFanoutTimeout;

  /// Gives durable membership requests time to reach candidate holders before
  /// the first stream open. Injectable so closed-loop tests need no wall clock.
  final Duration contentGrantDelay;

  /// Bumped on every persisted mutation (local op/post OR an ingested
  /// snapshot) so open group screens re-fetch. Cheap: the UI reads on change.
  final GroupChangeSignal changes = GroupChangeSignal();
  Timer? _spaceDeletionMaintenanceTimer;
  bool _spaceDeletionMaintenanceRunning = false;

  /// Our own node id — the composer uses it to align outgoing bubbles.
  NodeId get selfId => _signer.selfId;

  static const String _spaceInvitesSetting = 'spaces.invites.v1';
  static const int _maxSpaceInvites = 256;
  Future<void> _spaceInviteMutationTail = Future<void>.value();
  Future<void> _spacePostDraftMutationTail = Future<void>.value();

  Future<T> _serializeSpaceInvites<T>(Future<T> Function() action) async {
    final previous = _spaceInviteMutationTail;
    final gate = Completer<void>();
    _spaceInviteMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<T> _serializeSpacePostDrafts<T>(Future<T> Function() action) async {
    final previous = _spacePostDraftMutationTail;
    final gate = Completer<void>();
    _spacePostDraftMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<({List<PendingSpaceInvite> incoming, List<SpaceInvite> outgoing})>
  _loadSpaceInvites() async {
    final raw = await _storage.getSetting(_spaceInvitesSetting);
    if (raw == null || raw.isEmpty) {
      return (incoming: <PendingSpaceInvite>[], outgoing: <SpaceInvite>[]);
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1) {
        return (incoming: <PendingSpaceInvite>[], outgoing: <SpaceInvite>[]);
      }
      final incoming = (value['incoming'] as List? ?? const [])
          .map(PendingSpaceInvite.fromJson)
          .whereType<PendingSpaceInvite>()
          .take(_maxSpaceInvites)
          .toList();
      final outgoing = (value['outgoing'] as List? ?? const [])
          .map(SpaceInvite.fromJson)
          .whereType<SpaceInvite>()
          .take(_maxSpaceInvites)
          .toList();
      return (incoming: incoming, outgoing: outgoing);
    } catch (_) {
      return (incoming: <PendingSpaceInvite>[], outgoing: <SpaceInvite>[]);
    }
  }

  Future<void> _saveSpaceInvites({
    required List<PendingSpaceInvite> incoming,
    required List<SpaceInvite> outgoing,
  }) => _storage.putSetting(
    _spaceInvitesSetting,
    jsonEncode({
      'v': 1,
      'incoming': [
        for (final invite in incoming.take(_maxSpaceInvites)) invite.toJson(),
      ],
      'outgoing': [
        for (final invite in outgoing.take(_maxSpaceInvites)) invite.toJson(),
      ],
    }),
  );

  String _newSpaceInviteId() {
    final random = Random.secure();
    return List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Propose Space membership to one accepted contact. No membership state,
  /// history or epoch envelope is sent before the recipient explicitly accepts.
  Future<bool> inviteToSpace(
    NodeId spaceId,
    NodeId invitee, {
    GroupRole role = GroupRole.member,
  }) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace || role == GroupRole.owner) {
      return false;
    }
    if (invitee == selfId) return false;
    if ((await _storage.getContact(invitee))?.status !=
        ContactStatus.accepted) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    final authorRole = state.roleOf(selfId);
    if (authorRole == null ||
        state.isMember(invitee) ||
        !canApply(
          authorRole: authorRole,
          op: ControlOp.addMember,
          newRole: role,
        )) {
      return false;
    }
    final sender = sendSpaceInvite;
    if (sender == null) return false;
    final now = _now();
    final invite = SpaceInvite(
      inviteId: _newSpaceInviteId(),
      spaceId: spaceId,
      inviter: selfId,
      invitee: invitee,
      spaceName: bundle.manifest.visibility == SpaceVisibility.secret
          ? ''
          : state.name,
      visibility: bundle.manifest.visibility!,
      role: role,
      createdAtMs: now,
      expiresAtMs: now + const Duration(days: 7).inMilliseconds,
    );
    await _serializeSpaceInvites(() async {
      final store = await _loadSpaceInvites();
      final outgoing = [
        invite,
        for (final old in store.outgoing)
          if (!(old.spaceId == spaceId && old.invitee == invitee)) old,
      ];
      await _saveSpaceInvites(incoming: store.incoming, outgoing: outgoing);
    });
    changes.value++;
    try {
      await sender(invitee, invite.inviteId, jsonEncode(invite.toJson()));
      return true;
    } catch (_) {
      // The proposal remains durable locally so a later explicit retry can use
      // the same consent id instead of silently adding the member.
      return false;
    }
  }

  /// Store a minimal proposal from the authenticated accepted contact.
  Future<bool> receiveSpaceInvite(NodeId peer, String inviteJson) async {
    final SpaceInvite? invite;
    try {
      invite = SpaceInvite.fromJson(jsonDecode(inviteJson));
    } catch (_) {
      return false;
    }
    final now = _now();
    if (invite == null ||
        (await _storage.getContact(peer))?.status != ContactStatus.accepted ||
        invite.inviter != peer ||
        invite.invitee != selfId ||
        invite.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        invite.isExpiredAt(now) ||
        await load(invite.spaceId) != null) {
      return false;
    }
    final receivedInvite = invite;
    await _serializeSpaceInvites(() async {
      final store = await _loadSpaceInvites();
      PendingSpaceInvite? same;
      for (final old in store.incoming) {
        if (old.invite.inviteId == receivedInvite.inviteId) same = old;
      }
      final incoming = [
        same ?? PendingSpaceInvite(invite: receivedInvite),
        for (final old in store.incoming)
          if (old.invite.inviteId != receivedInvite.inviteId &&
              old.invite.spaceId != receivedInvite.spaceId)
            old,
      ];
      await _saveSpaceInvites(incoming: incoming, outgoing: store.outgoing);
    });
    changes.value++;
    return true;
  }

  Future<List<PendingSpaceInvite>> pendingSpaceInvites() async {
    final now = _now();
    final store = await _loadSpaceInvites();
    final result =
        store.incoming.where((entry) => !entry.invite.isExpiredAt(now)).toList()
          ..sort(
            (left, right) =>
                right.invite.createdAtMs.compareTo(left.invite.createdAtMs),
          );
    return result;
  }

  Future<bool> decideSpaceInvite(
    String inviteId, {
    required bool accept,
  }) async {
    final sender = sendSpaceInviteDecision;
    if (sender == null) return false;
    final prepared =
        await _serializeSpaceInvites<
          ({SpaceInvite invite, SpaceInviteDecision decision})?
        >(() async {
          final store = await _loadSpaceInvites();
          PendingSpaceInvite? pending;
          for (final candidate in store.incoming) {
            if (candidate.invite.inviteId == inviteId) pending = candidate;
          }
          if (pending == null || pending.invite.isExpiredAt(_now())) {
            return null;
          }
          final decidedAt = _now();
          final decision = SpaceInviteDecision(
            inviteId: inviteId,
            spaceId: pending.invite.spaceId,
            accepted: accept,
            decidedAtMs: decidedAt,
          );
          final incoming = <PendingSpaceInvite>[
            for (final entry in store.incoming)
              if (entry.invite.inviteId != inviteId)
                entry
              else if (accept)
                PendingSpaceInvite(
                  invite: entry.invite,
                  acceptedAtMs: decidedAt,
                ),
          ];
          await _saveSpaceInvites(incoming: incoming, outgoing: store.outgoing);
          changes.value++;
          return (invite: pending.invite, decision: decision);
        });
    if (prepared == null) return false;
    try {
      await sender(
        prepared.invite.inviter,
        inviteId,
        jsonEncode(prepared.decision.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Match an authenticated invitee decision to our durable proposal. Only a
  /// valid current control-log authority can turn acceptance into membership.
  Future<bool> receiveSpaceInviteDecision(
    NodeId peer,
    String decisionJson,
  ) async {
    final SpaceInviteDecision? decision;
    try {
      decision = SpaceInviteDecision.fromJson(jsonDecode(decisionJson));
    } catch (_) {
      return false;
    }
    if (decision == null) return false;
    final matchedDecision = decision;
    if ((await _storage.getContact(peer))?.status != ContactStatus.accepted) {
      return false;
    }
    final store = await _loadSpaceInvites();
    SpaceInvite? invite;
    for (final candidate in store.outgoing) {
      if (candidate.inviteId == matchedDecision.inviteId &&
          candidate.spaceId == matchedDecision.spaceId &&
          candidate.invitee == peer) {
        invite = candidate;
      }
    }
    final now = _now();
    if (invite == null ||
        invite.isExpiredAt(now) ||
        matchedDecision.decidedAtMs < invite.createdAtMs ||
        matchedDecision.decidedAtMs > invite.expiresAtMs ||
        matchedDecision.decidedAtMs >
            now + const Duration(minutes: 5).inMilliseconds) {
      return false;
    }
    final matchedInvite = invite;
    if (matchedDecision.accepted) {
      final added = await addControlOp(
        matchedInvite.spaceId,
        ControlOp.addMember,
        target: peer,
        role: matchedInvite.role,
      );
      if (!added) return false;
    }
    await _serializeSpaceInvites(() async {
      final latest = await _loadSpaceInvites();
      await _saveSpaceInvites(
        incoming: latest.incoming,
        outgoing: [
          for (final entry in latest.outgoing)
            if (entry.inviteId != matchedDecision.inviteId) entry,
        ],
      );
    });
    changes.value++;
    return true;
  }

  static const String _spaceJoinRequestsSetting = 'spaces.join_requests.v1';
  static const int _maxSpaceJoinRecords = 256;
  Future<void> _spaceJoinMutationTail = Future<void>.value();

  Future<T> _serializeSpaceJoins<T>(Future<T> Function() action) async {
    final previous = _spaceJoinMutationTail;
    final gate = Completer<void>();
    _spaceJoinMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<
    ({
      List<SpaceJoinTicket> tickets,
      List<SpaceJoinInboxEntry> incoming,
      List<SpaceJoinOutboxEntry> outgoing,
    })
  >
  _loadSpaceJoins() async {
    final raw = await _storage.getSetting(_spaceJoinRequestsSetting);
    if (raw == null || raw.isEmpty) {
      return (
        tickets: <SpaceJoinTicket>[],
        incoming: <SpaceJoinInboxEntry>[],
        outgoing: <SpaceJoinOutboxEntry>[],
      );
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1) throw const FormatException();
      return (
        tickets: (value['tickets'] as List? ?? const [])
            .map(SpaceJoinTicket.fromJson)
            .whereType<SpaceJoinTicket>()
            .take(_maxSpaceJoinRecords)
            .toList(),
        incoming: (value['incoming'] as List? ?? const [])
            .map(SpaceJoinInboxEntry.fromJson)
            .whereType<SpaceJoinInboxEntry>()
            .take(_maxSpaceJoinRecords)
            .toList(),
        outgoing: (value['outgoing'] as List? ?? const [])
            .map(SpaceJoinOutboxEntry.fromJson)
            .whereType<SpaceJoinOutboxEntry>()
            .take(_maxSpaceJoinRecords)
            .toList(),
      );
    } catch (_) {
      return (
        tickets: <SpaceJoinTicket>[],
        incoming: <SpaceJoinInboxEntry>[],
        outgoing: <SpaceJoinOutboxEntry>[],
      );
    }
  }

  Future<void> _saveSpaceJoins({
    required List<SpaceJoinTicket> tickets,
    required List<SpaceJoinInboxEntry> incoming,
    required List<SpaceJoinOutboxEntry> outgoing,
  }) => _storage.putSetting(
    _spaceJoinRequestsSetting,
    jsonEncode({
      'v': 1,
      'tickets': [
        for (final ticket in tickets.take(_maxSpaceJoinRecords))
          ticket.toJson(),
      ],
      'incoming': [
        for (final entry in incoming.take(_maxSpaceJoinRecords)) entry.toJson(),
      ],
      'outgoing': [
        for (final entry in outgoing.take(_maxSpaceJoinRecords)) entry.toJson(),
      ],
    }),
  );

  /// Create or reuse a capability-bound join link for one active public Space.
  /// Only an actor who can currently add a member may issue it. The link itself
  /// grants no data and is useless after the local ticket is revoked/expired.
  Future<String?> createSpaceJoinCode(NodeId spaceId) async {
    final bundle = await load(spaceId);
    if (bundle == null ||
        !bundle.manifest.isSpace ||
        bundle.manifest.visibility != SpaceVisibility.public) {
      return null;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final role = state.roleOf(selfId);
    if (!state.isActive ||
        role == null ||
        !canApply(
          authorRole: role,
          op: ControlOp.addMember,
          newRole: GroupRole.member,
        )) {
      return null;
    }
    return _serializeSpaceJoins(() async {
      final now = _now();
      final store = await _loadSpaceJoins();
      SpaceJoinTicket? current;
      for (final ticket in store.tickets) {
        if (ticket.spaceId == spaceId &&
            ticket.approver == selfId &&
            !ticket.isExpiredAt(now)) {
          current = ticket;
          break;
        }
      }
      current ??= SpaceJoinTicket(
        ticketId: _newSpaceInviteId(),
        spaceId: spaceId,
        approver: selfId,
        spaceName: state.name,
        createdAtMs: now,
        expiresAtMs: now + kSpaceJoinTicketLifetime.inMilliseconds,
      );
      final tickets = <SpaceJoinTicket>[
        current,
        for (final ticket in store.tickets)
          if (ticket.spaceId != spaceId && !ticket.isExpiredAt(now)) ticket,
      ];
      await _saveSpaceJoins(
        tickets: tickets,
        incoming: store.incoming,
        outgoing: store.outgoing,
      );
      changes.value++;
      return SpaceJoinCode.encode(current);
    });
  }

  Future<bool> revokeSpaceJoinCode(NodeId spaceId) => _serializeSpaceJoins(
    () async {
      final store = await _loadSpaceJoins();
      final tickets = [
        for (final ticket in store.tickets)
          if (!(ticket.spaceId == spaceId && ticket.approver == selfId)) ticket,
      ];
      if (tickets.length == store.tickets.length) return false;
      await _saveSpaceJoins(
        tickets: tickets,
        incoming: store.incoming,
        outgoing: store.outgoing,
      );
      changes.value++;
      return true;
    },
  );

  /// Create a signed, public recommendation campaign. The capability is
  /// issued by an admin, while any current member with distribute permission
  /// may later carry the resulting card to explicitly selected contacts.
  Future<SpaceRecommendationCampaign?> createSpaceRecommendationCampaign(
    NodeId spaceId,
    String text,
  ) async {
    final normalized = text.trim();
    if (normalized.isEmpty || normalized.length > 1000) return null;
    final joinCode = await createSpaceJoinCode(spaceId);
    if (joinCode == null) return null;
    try {
      final ticket = SpaceJoinCode.parse(joinCode);
      if (ticket.isExpiredAt(_now())) return null;
    } catch (_) {
      return null;
    }
    return _serialized(spaceId, () async {
      final bundle = await load(spaceId);
      if (bundle == null ||
          !bundle.manifest.isSpace ||
          bundle.manifest.visibility != SpaceVisibility.public) {
        return null;
      }
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
        initialDescription: bundle.manifest.description ?? '',
      ).state;
      if (!state.isActive ||
          !SpaceAcl(
            state,
          ).allows(selfId, SpacePermission.manageRecommendations)) {
        return null;
      }
      final now = _now();
      final campaign = SpaceRecommendationCampaign(
        campaignId: _newSpaceInviteId(),
        spaceId: spaceId,
        createdBy: selfId,
        text: normalized,
        joinCode: joinCode,
        createdAtMs: now,
        changedAtMs: now,
        active: true,
      );
      final applied = await _addControlOp(
        spaceId,
        ControlOp.setRecommendationCampaign,
        recommendationCampaign: campaign,
        createdAtMs: now,
      );
      return applied ? campaign : null;
    });
  }

  Future<List<SpaceRecommendationCampaign>> spaceRecommendationCampaigns(
    NodeId spaceId, {
    bool includeRevoked = false,
  }) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(state).allows(selfId, SpacePermission.view)) return const [];
    final now = _now();
    final campaigns = state.recommendationCampaigns.values.where((campaign) {
      if (includeRevoked) return true;
      if (!campaign.active) return false;
      try {
        return !SpaceJoinCode.parse(campaign.joinCode).isExpiredAt(now);
      } catch (_) {
        return false;
      }
    }).toList();
    campaigns.sort((a, b) => b.changedAtMs.compareTo(a.changedAtMs));
    return List.unmodifiable(campaigns);
  }

  Future<bool> revokeSpaceRecommendationCampaign(
    NodeId spaceId,
    String campaignId,
  ) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(
          state,
        ).allows(selfId, SpacePermission.manageRecommendations) ||
        !state.isActive) {
      return false;
    }
    final current = state.recommendationCampaignFor(campaignId);
    if (current == null || !current.active) return false;
    final now = _now();
    return _addControlOp(
      spaceId,
      ControlOp.setRecommendationCampaign,
      recommendationCampaign: SpaceRecommendationCampaign(
        campaignId: current.campaignId,
        spaceId: current.spaceId,
        createdBy: current.createdBy,
        text: current.text,
        joinCode: '',
        createdAtMs: current.createdAtMs,
        changedAtMs: now,
        active: false,
      ),
      createdAtMs: now,
    );
  });

  static const String _spaceRecommendationAuditSetting =
      'spaces.recommendations.audit.v1';
  static const int _maxSpaceRecommendationAudit = 512;
  static const int _spaceRecommendationCampaignHourlyLimit = 5;
  static const int _spaceRecommendationDailyLimit = 20;
  static const Duration _spaceRecommendationDuplicateWindow = Duration(days: 7);
  Future<void> _spaceRecommendationMutationTail = Future<void>.value();

  Future<T> _serializeSpaceRecommendations<T>(
    Future<T> Function() action,
  ) async {
    final previous = _spaceRecommendationMutationTail;
    final gate = Completer<void>();
    _spaceRecommendationMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<List<SpaceRecommendationShareAudit>>
  spaceRecommendationShareAudit() async {
    final raw = await _storage.getSetting(_spaceRecommendationAuditSetting);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1 || value['records'] is! List) {
        return const [];
      }
      return List.unmodifiable(
        (value['records'] as List)
            .map(SpaceRecommendationShareAudit.fromJson)
            .whereType<SpaceRecommendationShareAudit>()
            .take(_maxSpaceRecommendationAudit),
      );
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveSpaceRecommendationShareAudit(
    List<SpaceRecommendationShareAudit> records,
  ) => _storage.putSetting(
    _spaceRecommendationAuditSetting,
    jsonEncode({
      'v': 1,
      'records': [
        for (final record in records.take(_maxSpaceRecommendationAudit))
          record.toJson(),
      ],
    }),
  );

  /// Explicitly share one current public campaign with one accepted contact.
  /// Membership/role is never included in the card, so a member's hidden role
  /// cannot leak through recommendation metadata.
  Future<SpaceRecommendationShareResult> shareSpaceRecommendation(
    NodeId spaceId,
    String campaignId,
    NodeId recipient,
  ) => _serializeSpaceRecommendations(() async {
    final sender = sendSpaceRecommendation;
    if (sender == null || recipient == selfId) {
      return SpaceRecommendationShareResult.invalidRecipient;
    }
    final contact = await _storage.getContact(recipient);
    if (contact == null || contact.status != ContactStatus.accepted) {
      return SpaceRecommendationShareResult.invalidRecipient;
    }
    final bundle = await load(spaceId);
    if (bundle == null ||
        !bundle.manifest.isSpace ||
        bundle.manifest.visibility != SpaceVisibility.public) {
      return SpaceRecommendationShareResult.invalidCampaign;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!state.isActive ||
        !SpaceAcl(state).allows(selfId, SpacePermission.distributeContent)) {
      return SpaceRecommendationShareResult.notAllowed;
    }
    if (state.isMember(recipient)) {
      return SpaceRecommendationShareResult.alreadyMember;
    }
    final campaign = state.recommendationCampaignFor(campaignId);
    if (campaign == null || !campaign.active) {
      return SpaceRecommendationShareResult.invalidCampaign;
    }
    final now = _now();
    try {
      final ticket = SpaceJoinCode.parse(campaign.joinCode);
      if (ticket.spaceId != spaceId || ticket.isExpiredAt(now)) {
        return SpaceRecommendationShareResult.invalidCampaign;
      }
    } catch (_) {
      return SpaceRecommendationShareResult.invalidCampaign;
    }
    final records = await spaceRecommendationShareAudit();
    final duplicateCutoff =
        now - _spaceRecommendationDuplicateWindow.inMilliseconds;
    if (records.any(
      (record) =>
          record.campaignId == campaignId &&
          record.recipient == recipient &&
          record.sentAtMs >= duplicateCutoff,
    )) {
      return SpaceRecommendationShareResult.duplicate;
    }
    final hourlyCutoff = now - const Duration(hours: 1).inMilliseconds;
    final dailyCutoff = now - const Duration(days: 1).inMilliseconds;
    if (records.where((record) => record.sentAtMs >= dailyCutoff).length >=
            _spaceRecommendationDailyLimit ||
        records
                .where(
                  (record) =>
                      record.campaignId == campaignId &&
                      record.sentAtMs >= hourlyCutoff,
                )
                .length >=
            _spaceRecommendationCampaignHourlyLimit) {
      return SpaceRecommendationShareResult.rateLimited;
    }
    final card = SpaceRecommendationCard(
      campaignId: campaignId,
      spaceId: spaceId,
      name: state.name,
      description: state.description,
      text: campaign.text,
      joinCode: campaign.joinCode,
    );
    try {
      if (!await sender(recipient, card)) {
        return SpaceRecommendationShareResult.failed;
      }
    } catch (_) {
      return SpaceRecommendationShareResult.failed;
    }
    final updated = <SpaceRecommendationShareAudit>[
      SpaceRecommendationShareAudit(
        campaignId: campaignId,
        spaceId: spaceId,
        recipient: recipient,
        sentAtMs: now,
      ),
      for (final record in records)
        if (record.sentAtMs >= duplicateCutoff) record,
    ];
    await _saveSpaceRecommendationShareAudit(updated);
    changes.value++;
    return SpaceRecommendationShareResult.sent;
  });

  /// Receiver-side card suppression. A locally held Space cannot be joined via
  /// the public ticket flow, so showing the card would be both redundant and
  /// misleading. The card never becomes authority by itself.
  Future<bool> acceptsSpaceRecommendationCard(
    NodeId sender,
    SpaceRecommendationCard card,
  ) async {
    if (sender == selfId) return false;
    final contact = await _storage.getContact(sender);
    if (contact == null || contact.status != ContactStatus.accepted) {
      return false;
    }
    try {
      final ticket = SpaceJoinCode.parse(card.joinCode);
      if (ticket.spaceId != card.spaceId || ticket.isExpiredAt(_now())) {
        return false;
      }
    } catch (_) {
      return false;
    }
    return await load(card.spaceId) == null;
  }

  Future<String?> currentSpaceJoinCode(NodeId spaceId) async {
    final now = _now();
    for (final ticket in (await _loadSpaceJoins()).tickets) {
      if (ticket.spaceId == spaceId &&
          ticket.approver == selfId &&
          !ticket.isExpiredAt(now)) {
        return SpaceJoinCode.encode(ticket);
      }
    }
    return null;
  }

  /// Send a requester-authenticated intent using a public bearer link. No
  /// contact relationship is required; blocked peers are still rejected.
  Future<bool> requestToJoinSpace(String code) async {
    final SpaceJoinTicket ticket;
    try {
      ticket = SpaceJoinCode.parse(code);
    } catch (_) {
      return false;
    }
    final now = _now();
    if (ticket.approver == selfId ||
        ticket.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        ticket.isExpiredAt(now) ||
        await load(ticket.spaceId) != null ||
        (await _storage.getContact(ticket.approver))?.status ==
            ContactStatus.blocked ||
        sendSpaceJoinRequest == null) {
      return false;
    }
    final prepared = await _serializeSpaceJoins(() async {
      final store = await _loadSpaceJoins();
      for (final existing in store.outgoing) {
        if (existing.ticket.spaceId == ticket.spaceId &&
            !existing.declined &&
            !existing.ticket.isExpiredAt(now)) {
          return existing;
        }
      }
      final request = SpaceJoinRequest(
        requestId: _newSpaceInviteId(),
        ticketId: ticket.ticketId,
        ticketHash: spaceJoinTicketHash(ticket),
        spaceId: ticket.spaceId,
        requester: selfId,
        approver: ticket.approver,
        createdAtMs: now < ticket.createdAtMs ? ticket.createdAtMs : now,
      );
      final entry = SpaceJoinOutboxEntry(ticket: ticket, request: request);
      if (!entry.isStructurallyValid) return null;
      await _saveSpaceJoins(
        tickets: store.tickets,
        incoming: store.incoming,
        outgoing: [
          entry,
          for (final old in store.outgoing)
            if (old.ticket.spaceId != ticket.spaceId) old,
        ],
      );
      changes.value++;
      return entry;
    });
    if (prepared == null) return false;
    try {
      await sendSpaceJoinRequest!(
        prepared.request.approver,
        prepared.request.requestId,
        jsonEncode(prepared.request.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<SpaceJoinOutboxEntry>> outgoingSpaceJoinRequests() async {
    final now = _now();
    final result = <SpaceJoinOutboxEntry>[];
    for (final entry in (await _loadSpaceJoins()).outgoing) {
      if (entry.ticket.isExpiredAt(now) ||
          await load(entry.ticket.spaceId) != null) {
        continue;
      }
      if (entry.declined &&
          now - entry.decision!.decidedAtMs >
              kSpaceJoinRequestRetryDelay.inMilliseconds) {
        continue;
      }
      result.add(entry);
    }
    result.sort(
      (left, right) =>
          right.request.createdAtMs.compareTo(left.request.createdAtMs),
    );
    return result;
  }

  Future<bool> dismissSpaceJoinRequest(String requestId) =>
      _serializeSpaceJoins(() async {
        final store = await _loadSpaceJoins();
        final outgoing = [
          for (final entry in store.outgoing)
            if (entry.request.requestId != requestId) entry,
        ];
        if (outgoing.length == store.outgoing.length) return false;
        await _saveSpaceJoins(
          tickets: store.tickets,
          incoming: store.incoming,
          outgoing: outgoing,
        );
        changes.value++;
        return true;
      });

  /// Validate and durably persist one capability-bound request from an
  /// authenticated Veil sender. The ticket, current public Space policy and
  /// per-requester cooldown all have to pass before an ACK is permitted.
  Future<bool> receiveSpaceJoinRequest(NodeId peer, String requestJson) async {
    final SpaceJoinRequest? request;
    try {
      request = SpaceJoinRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      return false;
    }
    final now = _now();
    if (request == null ||
        request.requester != peer ||
        request.approver != selfId ||
        request.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        (await _storage.getContact(peer))?.status == ContactStatus.blocked) {
      return false;
    }
    final bundle = await load(request.spaceId);
    if (bundle == null ||
        !bundle.manifest.isSpace ||
        bundle.manifest.visibility != SpaceVisibility.public) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final role = state.roleOf(selfId);
    if (!state.isActive ||
        role == null ||
        state.isMember(peer) ||
        !canApply(
          authorRole: role,
          op: ControlOp.addMember,
          newRole: GroupRole.member,
        )) {
      return false;
    }
    final acceptedRequest = request;
    return _serializeSpaceJoins(() async {
      final store = await _loadSpaceJoins();
      SpaceJoinTicket? ticket;
      for (final candidate in store.tickets) {
        if (candidate.ticketId == acceptedRequest.ticketId &&
            candidate.spaceId == acceptedRequest.spaceId &&
            candidate.approver == selfId) {
          ticket = candidate;
          break;
        }
      }
      if (ticket == null ||
          ticket.isExpiredAt(now) ||
          acceptedRequest.ticketHash != spaceJoinTicketHash(ticket) ||
          acceptedRequest.createdAtMs < ticket.createdAtMs ||
          acceptedRequest.createdAtMs >= ticket.expiresAtMs) {
        return false;
      }
      for (final old in store.incoming) {
        if (old.request.requestId == acceptedRequest.requestId) {
          return old.request.requester == peer &&
              old.request.spaceId == acceptedRequest.spaceId;
        }
        if (old.request.requester == peer &&
            old.request.spaceId == acceptedRequest.spaceId &&
            (old.pending ||
                now - old.decision!.decidedAtMs <
                    kSpaceJoinRequestRetryDelay.inMilliseconds)) {
          return false;
        }
      }
      final entry = SpaceJoinInboxEntry(
        request: acceptedRequest,
        receivedAtMs: now < acceptedRequest.createdAtMs
            ? acceptedRequest.createdAtMs
            : now,
      );
      await _saveSpaceJoins(
        tickets: store.tickets,
        incoming: [
          entry,
          for (final old in store.incoming)
            if (!(old.request.requester == peer &&
                old.request.spaceId == acceptedRequest.spaceId))
              old,
        ],
        outgoing: store.outgoing,
      );
      changes.value++;
      return true;
    });
  }

  Future<List<SpaceJoinInboxEntry>> pendingSpaceJoinRequests(
    NodeId spaceId,
  ) async {
    final result =
        (await _loadSpaceJoins()).incoming
            .where((entry) => entry.pending && entry.request.spaceId == spaceId)
            .toList()
          ..sort(
            (left, right) => right.receivedAtMs.compareTo(left.receivedAtMs),
          );
    return result;
  }

  Future<bool> decideSpaceJoinRequest(
    String requestId, {
    required bool accept,
  }) async {
    final sender = sendSpaceJoinDecision;
    if (sender == null) return false;
    final prepared =
        await _serializeSpaceJoins<
          ({SpaceJoinRequest request, SpaceJoinDecision decision})?
        >(() async {
          final store = await _loadSpaceJoins();
          SpaceJoinInboxEntry? pending;
          for (final candidate in store.incoming) {
            if (candidate.request.requestId == requestId && candidate.pending) {
              pending = candidate;
              break;
            }
          }
          if (pending == null) return null;
          if (accept) {
            final added = await addControlOp(
              pending.request.spaceId,
              ControlOp.addMember,
              target: pending.request.requester,
              role: GroupRole.member,
            );
            if (!added) return null;
          }
          final now = _now();
          final decision = SpaceJoinDecision(
            requestId: requestId,
            spaceId: pending.request.spaceId,
            accepted: accept,
            decidedAtMs: now < pending.receivedAtMs
                ? pending.receivedAtMs
                : now,
          );
          await _saveSpaceJoins(
            tickets: store.tickets,
            incoming: [
              for (final entry in store.incoming)
                if (entry.request.requestId == requestId)
                  SpaceJoinInboxEntry(
                    request: entry.request,
                    receivedAtMs: entry.receivedAtMs,
                    decision: decision,
                  )
                else
                  entry,
            ],
            outgoing: store.outgoing,
          );
          changes.value++;
          return (request: pending.request, decision: decision);
        });
    if (prepared == null) return false;
    try {
      await sender(
        prepared.request.requester,
        prepared.request.requestId,
        jsonEncode(prepared.decision.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> receiveSpaceJoinDecision(
    NodeId peer,
    String decisionJson,
  ) async {
    final SpaceJoinDecision? decision;
    try {
      decision = SpaceJoinDecision.fromJson(jsonDecode(decisionJson));
    } catch (_) {
      return false;
    }
    if (decision == null ||
        (await _storage.getContact(peer))?.status == ContactStatus.blocked) {
      return false;
    }
    final acceptedDecision = decision;
    return _serializeSpaceJoins(() async {
      final store = await _loadSpaceJoins();
      SpaceJoinOutboxEntry? matched;
      for (final entry in store.outgoing) {
        if (entry.request.requestId == acceptedDecision.requestId &&
            entry.request.spaceId == acceptedDecision.spaceId &&
            entry.request.approver == peer) {
          matched = entry;
          break;
        }
      }
      if (matched == null ||
          acceptedDecision.decidedAtMs < matched.request.createdAtMs ||
          acceptedDecision.decidedAtMs >
              matched.ticket.expiresAtMs +
                  const Duration(minutes: 5).inMilliseconds) {
        return false;
      }
      if (matched.decision != null) {
        return matched.decision!.accepted == acceptedDecision.accepted &&
            matched.decision!.decidedAtMs == acceptedDecision.decidedAtMs;
      }
      await _saveSpaceJoins(
        tickets: store.tickets,
        incoming: store.incoming,
        outgoing: [
          for (final entry in store.outgoing)
            if (entry.request.requestId == acceptedDecision.requestId)
              SpaceJoinOutboxEntry(
                ticket: entry.ticket,
                request: entry.request,
                decision: acceptedDecision,
              )
            else
              entry,
        ],
      );
      changes.value++;
      return true;
    });
  }

  final Map<String, Future<void>> _mutationTails = <String, Future<void>>{};

  // Overlay deltas are flooded transitively across each node's sparse XOR
  // links. This bounded RAM set makes the flood exactly-once per live process;
  // the underlying log merge remains the durable/idempotent safety net.
  static const int _kSeenOverlayDeltaLimit = 4096;
  final Set<String> _seenOverlayDeltas = <String>{};

  final StreamController<GroupCallSignal> _groupCallIncomingCtl =
      StreamController.broadcast();
  Stream<GroupCallSignal> get groupCallIncoming => _groupCallIncomingCtl.stream;

  /// Replay ids are RAM-only: wire frame dedup is the first line, while this
  /// signed-signal set also catches a malicious re-wrapping under a fresh AEAD
  /// nonce/frame id. Signals expire quickly, so restart persistence is neither
  /// useful nor desirable.
  final Map<String, int> _seenGroupCallSignals = <String, int>{};

  /// Serialize every read-modify-write of one group. Wire ingest and local UI
  /// actions share this gate, so a concurrently arriving delta cannot restore
  /// an older bundle and erase a freshly persisted message/epoch key.
  Future<T> _serialized<T>(NodeId groupId, Future<T> Function() action) async {
    final id = groupId.hex;
    final previous = _mutationTails[id] ?? Future<void>.value();
    final gate = Completer<void>();
    _mutationTails[id] = gate.future;
    try {
      try {
        await previous;
      } catch (_) {
        // A prior mutation reports its own failure; the queue must keep moving.
      }
      return await action();
    } finally {
      gate.complete();
      if (identical(_mutationTails[id], gate.future)) {
        _mutationTails.remove(id);
      }
    }
  }

  int _lastTimestampMs = -1;

  /// Signed entries created by one service instance must retain local causal
  /// order even when several mutations land in one wall-clock millisecond (or
  /// the OS clock steps backwards). Distributed fold still uses author/seq;
  /// this monotonic timestamp additionally makes `fromJoin` boundaries exact.
  int _now() {
    final wall = DateTime.now().millisecondsSinceEpoch;
    _lastTimestampMs = wall > _lastTimestampMs ? wall : _lastTimestampMs + 1;
    return _lastTimestampMs;
  }

  bool _validManifest(GroupManifest manifest) {
    if (manifest.isLegacyGroup) return manifest.genesisPubKey.length == 32;
    if (manifest.version == SpaceManifest.spaceVersion) {
      return manifest.isSpace && _signer.verifySpaceManifest(manifest);
    }
    if (!manifest.isSovereignDevice ||
        manifest.name != kDeviceGroupName ||
        manifest.signatureAlgorithm == null) {
      return false;
    }
    if (manifest.signatureAlgorithm != 'ed25519' &&
        manifest.sovereignBundleHash == null) {
      return false;
    }
    return _signer.verifySovereign(
      algorithm: manifest.signatureAlgorithm!,
      nodeId: manifest.owner,
      publicKey: manifest.genesisPubKey,
      message: manifest.canonicalBytes(),
      signature: manifest.signature,
    );
  }

  bool _validSovereignBundle(
    GroupManifest manifest,
    Uint8List? encryptedBundle,
  ) {
    final expected = manifest.sovereignBundleHash;
    if (expected == null) return encryptedBundle == null;
    if (encryptedBundle == null || encryptedBundle.length > 16 * 1024) {
      return false;
    }
    return _listEquals(_sha256(encryptedBundle), expected);
  }

  /// Select the one authoritative manifest during snapshot merge. The only
  /// permitted change is an owner-signed v1 -> Space v3 upgrade over exactly
  /// the same immutable root. Signed Spaces never downgrade or fork.
  GroupManifest? _mergeManifest(
    GroupManifest existing,
    GroupManifest incoming,
  ) {
    if (existing.isSovereignDevice || incoming.isSovereignDevice) {
      return existing.isSovereignDevice &&
              incoming.isSovereignDevice &&
              existing.sameGenesis(incoming)
          ? existing
          : null;
    }
    if (!existing.sameImmutableRoot(incoming)) return null;
    if (existing.isSpace) {
      if (incoming.isSpace && !existing.sameGenesis(incoming)) return null;
      return existing;
    }
    if (!existing.isLegacyGroup) return null;
    if (incoming.isSpace) return incoming;
    return incoming.isLegacyGroup ? existing : null;
  }

  bool _validControlFor(GroupManifest manifest, ControlEntry e) {
    if (!e.isStructurallyValid) return false;
    if ((e.op == ControlOp.transferOwnership ||
            e.op == ControlOp.setDescription ||
            e.op == ControlOp.publishRules ||
            e.op == ControlOp.acceptRules ||
            e.op == ControlOp.setRetention) &&
        !manifest.isSpace) {
      return false;
    }
    if (manifest.isSovereignDevice) {
      final membershipOp =
          e.op == ControlOp.addMember || e.op == ControlOp.removeMember;
      final shapeOk =
          e.target != null &&
          (e.op != ControlOp.addMember || e.role == GroupRole.member) &&
          (e.op != ControlOp.removeMember || e.role == null);
      return _validManifest(manifest) &&
          e.groupId == manifest.groupId &&
          e.author == manifest.owner &&
          _listEquals(e.authorPubKey, manifest.genesisPubKey) &&
          membershipOp &&
          shapeOk &&
          _signer.verifySovereign(
            algorithm: manifest.signatureAlgorithm!,
            nodeId: e.author,
            publicKey: e.authorPubKey,
            message: e.canonicalBytes(),
            signature: e.signature,
          );
    }
    return (e.groupId == null || e.groupId == manifest.groupId) &&
        _signer.verifyControl(e);
  }

  bool _validMessageFor(NodeId groupId, GroupMessage m) =>
      m.groupId == groupId && _signer.verifyMessage(m);

  bool _validReactionFor(NodeId groupId, GroupReaction r) =>
      r.groupId == groupId &&
      r.isStructurallyValid &&
      _signer.verifyReaction(r);

  bool _validPostFor(NodeId spaceId, SpacePost post) =>
      post.spaceId == spaceId &&
      post.isStructurallyValid &&
      _signer.verifyPost(post);

  bool _validGroupCallShape(GroupCallSignal signal) {
    switch (signal.type) {
      case GroupCallSignalType.announce:
      case GroupCallSignalType.join:
        // These establish the room capability for a newly-seeing peer.
        if (signal.media == null || signal.media!.isEmpty) return false;
        break;
      case GroupCallSignalType.renegotiate:
        // Current posture is required but may be all-off.
        if (signal.media == null) return false;
        break;
      case GroupCallSignalType.heartbeat:
        // Legacy heartbeats omit media; new ones repeat current posture so a
        // lost live renegotiation converges at the next tick.
        break;
      case GroupCallSignalType.leave:
      case GroupCallSignalType.end:
      case GroupCallSignalType.busy:
      case GroupCallSignalType.unknown:
        if (signal.media != null) return false;
        break;
    }
    return signal.isStructurallyValid;
  }

  String _freshGroupCallNonce() {
    final random = Random.secure();
    return List<int>.generate(
      12,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  void _pruneSeenGroupCallSignals(int nowMs) {
    _seenGroupCallSignals.removeWhere(
      (_, seenAt) => nowMs - seenAt > const Duration(minutes: 3).inMilliseconds,
    );
    while (_seenGroupCallSignals.length > 2048) {
      _seenGroupCallSignals.remove(_seenGroupCallSignals.keys.first);
    }
  }

  /// Sign, epoch-encrypt and fan one ephemeral call-control event to every
  /// other CURRENT member. No call plaintext or key is persisted.
  Future<GroupCallSignal?> broadcastGroupCallSignal(
    NodeId groupId, {
    NodeId? channelId,
    required String callId,
    required GroupCallSignalType type,
    CallMedia? media,
    CallEndReason? reason,
  }) => _serialized(groupId, () async {
    final sender = sendGroupCallFrame;
    final bundle = await load(groupId);
    if (sender == null || bundle == null || bundle.manifest.isSovereignDevice) {
      return null;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (bundle.manifest.isSpace) {
      if (channelId != null) {
        final channel = state.channels[channelId.hex];
        if (channel == null ||
            channel.kind != SpaceChannelKind.voice ||
            channel.archived) {
          return null;
        }
      }
    } else if (channelId != null) {
      return null;
    }
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.view) ||
        !SpaceAcl(state).allows(
          _signer.selfId,
          SpacePermission.enterVoice,
          channelId: channelId,
        ) ||
        !_encryptionEstablished(bundle.manifest, bundle.control)) {
      return null;
    }
    final descriptor = state.epochDescriptor;
    final key = bundle.localEpochKeys[state.epoch];
    if (descriptor == null ||
        descriptor.epoch != state.epoch ||
        key == null ||
        !_validLocalEpochKey(
          bundle.manifest,
          bundle.control,
          state.epoch,
          key,
        )) {
      return null;
    }
    final unsigned = GroupCallSignal(
      groupId: groupId,
      channelId: channelId,
      callId: callId,
      author: _signer.selfId,
      membershipEpoch: state.epoch,
      type: type,
      media: media,
      reason: reason,
      sentAtMs: _now(),
      nonce: _freshGroupCallNonce(),
      signature: Uint8List(0),
      authorPubKey: Uint8List(0),
      protocolVersion: channelId == null
          ? kLegacyGroupCallProtocolVersion
          : kSpaceVoiceSessionProtocolVersion,
    );
    if (!_validGroupCallShape(unsigned)) return null;
    final signed = _signer.signCallSignal(unsigned);
    if (!_validGroupCallShape(signed) || !_signer.verifyCallSignal(signed)) {
      return null;
    }
    final clear = Uint8List.fromList(utf8.encode(signed.encode()));
    try {
      final encrypted = await encryptGroupCallPayload(
        groupId: groupId,
        membershipEpoch: state.epoch,
        author: _signer.selfId,
        clearText: clear,
        epochKey: key,
      );
      final frame = GroupCallWireFrame(
        groupId: groupId,
        membershipEpoch: state.epoch,
        payload: encrypted,
      ).encode();
      for (final member in state.members.values) {
        if (member.nodeId == _signer.selfId) continue;
        await sender(member.nodeId, signed, frame);
      }
      return signed;
    } catch (_) {
      return null;
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  });

  /// Authenticate and decrypt an inbound group-call frame. Every refusal is a
  /// silent false: callers must not learn whether a gid, member or epoch exists.
  Future<bool> ingestGroupCallFrame(NodeId peer, String frameJson) async {
    final frame = GroupCallWireFrame.tryDecode(frameJson);
    if (frame == null) return false;
    return _serialized(frame.groupId, () async {
      final bundle = await load(frame.groupId);
      if (bundle == null || bundle.manifest.isSovereignDevice) return false;
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
      ).state;
      if (!SpaceAcl(state).allows(peer, SpacePermission.view) ||
          frame.membershipEpoch != state.epoch ||
          state.epochDescriptor?.epoch != state.epoch) {
        return false;
      }
      final key = bundle.localEpochKeys[state.epoch];
      if (key == null ||
          !_validLocalEpochKey(
            bundle.manifest,
            bundle.control,
            state.epoch,
            key,
          )) {
        return false;
      }
      Uint8List? clear;
      try {
        clear = await decryptGroupCallPayload(
          groupId: frame.groupId,
          membershipEpoch: frame.membershipEpoch,
          author: peer,
          payload: frame.payload,
          epochKey: key,
        );
        if (clear.length > maxGroupCallSignalBytes) return false;
        final signal = GroupCallSignal.tryDecode(utf8.decode(clear));
        if (signal == null ||
            signal.groupId != frame.groupId ||
            signal.membershipEpoch != frame.membershipEpoch ||
            signal.author != peer ||
            !_validGroupCallShape(signal) ||
            !_signer.verifyCallSignal(signal) ||
            !SpaceAcl(state).allows(
              peer,
              SpacePermission.enterVoice,
              atMs: signal.sentAtMs,
              channelId: signal.channelId,
            )) {
          return false;
        }
        if (bundle.manifest.isSpace) {
          if (signal.channelId == null) {
            if (signal.protocolVersion != kLegacyGroupCallProtocolVersion) {
              return false;
            }
          } else {
            final channel = state.channels[signal.channelId!.hex];
            if (signal.protocolVersion != kSpaceVoiceSessionProtocolVersion ||
                channel == null ||
                channel.kind != SpaceChannelKind.voice ||
                channel.archived) {
              return false;
            }
          }
        } else if (signal.channelId != null ||
            signal.protocolVersion != kLegacyGroupCallProtocolVersion) {
          return false;
        }
        final nowMs = _now();
        final ageMs = nowMs - signal.sentAtMs;
        if (ageMs < -const Duration(seconds: 30).inMilliseconds ||
            ageMs > const Duration(minutes: 2).inMilliseconds) {
          return false;
        }
        _pruneSeenGroupCallSignals(nowMs);
        final replayId =
            '${signal.author.hex}:${signal.callId}:${signal.nonce}';
        if (_seenGroupCallSignals.containsKey(replayId)) return false;
        _seenGroupCallSignals[replayId] = nowMs;
        if (!_groupCallIncomingCtl.isClosed) {
          _groupCallIncomingCtl.add(signal);
        }
        return true;
      } catch (_) {
        return false;
      } finally {
        clear?.fillRange(0, clear.length, 0);
      }
    });
  }

  bool _sameEpochDescriptor(
    GroupEpochDescriptor left,
    GroupEpochDescriptor right,
  ) =>
      left.groupId == right.groupId &&
      left.epoch == right.epoch &&
      left.keyCommitment == right.keyCommitment &&
      left.envelopeRoot == right.envelopeRoot &&
      left.recipientCount == right.recipientCount;

  List<ControlEntry> _acceptedControl(
    GroupManifest manifest,
    List<ControlEntry> control,
  ) {
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
    );
    return folded.accepted;
  }

  List<SpaceControlHead> _controlHeads(Iterable<ControlEntry> accepted) {
    final heads = <String, ControlEntry>{};
    for (final entry in accepted) {
      final current = heads[entry.author.hex];
      if (current == null || entry.seq > current.seq) {
        heads[entry.author.hex] = entry;
      }
    }
    final ordered = heads.values.toList()
      ..sort((left, right) => left.author.hex.compareTo(right.author.hex));
    return [
      for (final entry in ordered)
        SpaceControlHead(
          author: entry.author,
          seq: entry.seq,
          hash: controlEntryHash(entry),
        ),
    ];
  }

  SpaceControlCheckpoint? _controlCheckpoint(Iterable<ControlEntry> accepted) {
    final heads = _controlHeads(accepted);
    if (heads.length > kSpaceControlCheckpointHeadsMax) return null;
    return SpaceControlCheckpoint(heads);
  }

  GroupFoldResult? _foldAtControlHeads(
    GroupManifest manifest,
    List<ControlEntry> control,
    List<SpaceControlHead> controlHeads,
  ) {
    final heads = {for (final head in controlHeads) head.author.hex: head};
    if (heads.length != controlHeads.length) return null;
    final selected = <ControlEntry>[];
    for (final entry in control) {
      final head = heads[entry.author.hex];
      if (head != null &&
          entry.seq <= head.seq &&
          _validControlFor(manifest, entry)) {
        selected.add(entry);
      }
    }
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: selected,
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
    );
    final acceptedHashes = {
      for (final entry in folded.accepted) controlEntryHash(entry),
    };
    for (final head in controlHeads) {
      if (!acceptedHashes.contains(head.hash) ||
          !folded.accepted.any(
            (entry) =>
                entry.author == head.author &&
                entry.seq == head.seq &&
                controlEntryHash(entry) == head.hash,
          )) {
        return null;
      }
    }
    return folded;
  }

  GroupFoldResult? _foldAtPostFrontier(
    GroupManifest manifest,
    List<ControlEntry> control,
    SpaceControlFrontier frontier,
  ) {
    if (!frontier.isStructurallyValid) return null;
    return _foldAtControlHeads(manifest, control, frontier.heads);
  }

  GroupFoldResult? _foldAtControlCheckpoint(
    GroupManifest manifest,
    List<ControlEntry> control,
    ControlEntry entry,
  ) {
    final checkpoint = entry.controlCheckpoint;
    if (entry.op != ControlOp.checkpoint ||
        checkpoint == null ||
        !checkpoint.isStructurallyValid) {
      return null;
    }
    final historical = _foldAtControlHeads(manifest, control, checkpoint.heads);
    if (historical == null ||
        historical.state.policyVersion != entry.policyVersion ||
        !historical.state.isMember(entry.author)) {
      return null;
    }
    SpaceControlHead? predecessor;
    for (final head in checkpoint.heads) {
      if (head.author == entry.author) {
        predecessor = head;
        break;
      }
    }
    if (predecessor == null) {
      if (entry.seq != 0 || entry.prevHash.isNotEmpty) return null;
    } else if (entry.seq != predecessor.seq + 1 ||
        entry.prevHash != predecessor.hash) {
      return null;
    }
    return historical;
  }

  ({int seq, String prevHash, bool blocked}) _nextControlLink(
    GroupManifest manifest,
    List<ControlEntry> control,
    NodeId author,
  ) {
    final authored =
        _acceptedControl(
            manifest,
            control,
          ).where((entry) => entry.author == author).toList()
          ..sort((left, right) => left.seq.compareTo(right.seq));
    final acceptedHeadSeq = authored.isEmpty ? -1 : authored.last.seq;
    final hasRejectedSuffix = control.any(
      (entry) =>
          entry.author == author &&
          _validControlFor(manifest, entry) &&
          entry.seq > acceptedHeadSeq,
    );
    if (authored.isEmpty) {
      return (seq: 0, prevHash: '', blocked: hasRejectedSuffix);
    }
    final head = authored.last;
    return (
      seq: head.seq + 1,
      prevHash: controlEntryHash(head),
      blocked: hasRejectedSuffix,
    );
  }

  ControlEntry? _descriptorEntry(
    GroupManifest manifest,
    List<ControlEntry> control,
    GroupEpochDescriptor descriptor,
  ) {
    for (final entry in _acceptedControl(manifest, control)) {
      final candidate = entry.epochDescriptor;
      if (candidate != null && _sameEpochDescriptor(candidate, descriptor)) {
        return entry;
      }
    }
    return null;
  }

  bool _encryptionEstablished(
    GroupManifest manifest,
    List<ControlEntry> control,
  ) => _acceptedControl(
    manifest,
    control,
  ).any((entry) => entry.epochDescriptor != null);

  bool _validLocalEpochKey(
    GroupManifest manifest,
    List<ControlEntry> control,
    int epoch,
    Uint8List key,
  ) {
    if (key.length != 32) return false;
    for (final entry in _acceptedControl(manifest, control)) {
      final descriptor = entry.epochDescriptor;
      if (descriptor == null || descriptor.epoch != epoch) continue;
      return descriptor.keyCommitment ==
          groupEpochKeyCommitment(
            groupId: manifest.groupId,
            epoch: epoch,
            key: key,
          );
    }
    return false;
  }

  Future<GroupMessage?> _materializeEncryptedMessage(
    GroupBundle bundle,
    GroupMessage message,
  ) async {
    if (!message.isEncrypted) return message;
    if (message.isChannelEncrypted) {
      final channelId = message.channelId!;
      final epoch = message.channelEpoch!;
      final key = bundle.localChannelEpochKeys[_channelKeyId(channelId, epoch)];
      if (key == null ||
          !_validLocalChannelEpochKey(
            bundle.manifest,
            bundle.control,
            channelId,
            epoch,
            key,
          )) {
        return null;
      }
      Uint8List? clear;
      try {
        clear = await decryptSpaceChannelMessagePayload(
          spaceId: bundle.manifest.groupId,
          channelId: channelId,
          channelEpoch: epoch,
          author: message.author,
          seq: message.seq,
          prevHash: message.prevHash,
          policyVersion: message.policyVersion,
          createdAtMs: message.createdAtMs,
          payload: message.encryptedPayload!,
          channelKey: key,
        );
        final decoded = GroupMessageCleartext.decode(clear);
        return decoded == null ? null : message.withDecryptedContent(decoded);
      } catch (_) {
        return null;
      } finally {
        clear?.fillRange(0, clear.length, 0);
      }
    }
    final epoch = message.membershipEpoch!;
    final key = bundle.localEpochKeys[epoch];
    if (key == null ||
        !_validLocalEpochKey(bundle.manifest, bundle.control, epoch, key)) {
      return null;
    }
    Uint8List? clear;
    try {
      clear = await decryptGroupPayload(
        groupId: bundle.manifest.groupId,
        membershipEpoch: epoch,
        author: message.author,
        seq: message.seq,
        prevHash: message.prevHash,
        policyVersion: message.policyVersion,
        createdAtMs: message.createdAtMs,
        payload: message.encryptedPayload!,
        epochKey: key,
      );
      final decoded = GroupMessageCleartext.decode(clear);
      return decoded == null ? null : message.withDecryptedContent(decoded);
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<SpaceChannelControlCleartext?> _materializeProtectedChannel(
    GroupBundle bundle,
    GroupState state,
    SpaceChannelControlEnvelope envelope, {
    bool requireCurrentAcl = true,
  }) async {
    final id = _channelKeyId(envelope.channelId, envelope.channelEpoch);
    final key = bundle.localChannelEpochKeys[id];
    if (key == null ||
        !_validLocalChannelEpochKey(
          bundle.manifest,
          bundle.control,
          envelope.channelId,
          envelope.channelEpoch,
          key,
        )) {
      return null;
    }
    final entry = _channelDescriptorEntry(
      bundle.manifest,
      bundle.control,
      envelope.keyDescriptor,
    );
    if (entry == null ||
        jsonEncode(entry.channelControl?.toJson()) !=
            jsonEncode(envelope.toJson())) {
      return null;
    }
    Uint8List? clear;
    try {
      clear = await decryptSpaceChannelControlPayload(
        spaceId: envelope.spaceId,
        channelId: envelope.channelId,
        channelEpoch: envelope.channelEpoch,
        keyCommitment: envelope.keyDescriptor.keyCommitment,
        author: entry.author,
        policyVersion: entry.policyVersion,
        createdAtMs: entry.createdAtMs,
        payload: envelope.encryptedControl,
        channelKey: key,
      );
      final decoded = SpaceChannelControlCleartext.decode(clear);
      if (decoded == null ||
          decoded.channel.spaceId != bundle.manifest.groupId ||
          decoded.channel.channelId != envelope.channelId ||
          decoded.channel.kind != SpaceChannelKind.text ||
          decoded.channel.categoryId != null ||
          decoded.channel.isDefault ||
          !decoded.recipients.contains(_signer.selfId) ||
          decoded.recipients.length != envelope.keyDescriptor.recipientCount ||
          (requireCurrentAcl &&
              decoded.recipients.any(
                (recipient) => !state.isMember(recipient),
              ))) {
        return null;
      }
      // V1 keeps every current owner/admin able to revoke access and rotate
      // the channel after a membership mutation. Omitting one would strand an
      // undecryptable ACL subtree and make revocation depend on the creator.
      if (requireCurrentAcl) {
        for (final member in state.members.values) {
          if (member.role.rank >= GroupRole.admin.rank &&
              !decoded.recipients.contains(member.nodeId)) {
            return null;
          }
        }
      }
      return decoded;
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<Map<String, SpaceChannelControlCleartext>> _protectedChannelsOf(
    GroupBundle bundle,
    GroupState state,
  ) async {
    final result = <String, SpaceChannelControlCleartext>{};
    for (final envelope in state.protectedChannels.values) {
      final clear = await _materializeProtectedChannel(bundle, state, envelope);
      if (clear != null) result[envelope.channelId.hex] = clear;
    }
    return result;
  }

  Future<GroupReaction?> _materializeEncryptedReaction(
    GroupBundle bundle,
    GroupReaction reaction,
  ) async {
    if (!reaction.isEncrypted) return reaction;
    final epoch = reaction.membershipEpoch!;
    final key = bundle.localEpochKeys[epoch];
    if (key == null ||
        !_validLocalEpochKey(bundle.manifest, bundle.control, epoch, key)) {
      return null;
    }
    Uint8List? clear;
    try {
      clear = await decryptGroupReactionPayload(
        groupId: bundle.manifest.groupId,
        membershipEpoch: epoch,
        author: reaction.author,
        seq: reaction.seq,
        createdAtMs: reaction.createdAtMs,
        reactionVersion: reaction.version,
        lifecycleGeneration: reaction.lifecycleGeneration ?? '',
        payload: reaction.encryptedPayload!,
        epochKey: key,
      );
      final decoded = GroupReactionCleartext.decode(clear);
      final expectedSchema = reaction.version == 2 ? 1 : 2;
      return decoded == null || decoded.schemaVersion != expectedSchema
          ? null
          : reaction.withDecryptedContent(decoded);
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<SpacePost?> _materializeEncryptedPost(
    GroupBundle bundle,
    SpacePost post,
  ) async {
    if (!post.isEncrypted) return post;
    final epoch = post.membershipEpoch!;
    final key = bundle.localEpochKeys[epoch];
    if (key == null ||
        !_validLocalEpochKey(bundle.manifest, bundle.control, epoch, key)) {
      return null;
    }
    Uint8List? clear;
    try {
      clear = await decryptSpacePostPayload(
        spaceId: post.spaceId,
        membershipEpoch: epoch,
        author: post.author,
        seq: post.seq,
        prevHash: post.prevHash,
        postType: post.type.name,
        visibility: post.visibility.name,
        policyVersion: post.policyVersion,
        createdAtMs: post.createdAtMs,
        publishedAtMs: post.publishedAtMs,
        controlFrontier: post.controlFrontier?.toJson() ?? const [],
        controlCheckpointHash: post.controlCheckpointHash ?? '',
        postOperation: post.version >= 7 ? post.operation.name : '',
        targetSeq: post.version >= 7 ? post.targetSeq : null,
        lifecycleGeneration: post.lifecycleGeneration ?? '',
        payload: post.encryptedPayload!,
        epochKey: key,
      );
      final decoded = SpacePostCleartext.decode(clear);
      if (decoded == null ||
          decoded.isTombstone !=
              (post.operation == SpacePostOperation.delete)) {
        return null;
      }
      return post.withDecryptedContent(decoded);
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<
    ({List<GroupEpochRecipientEnvelope> envelopes, Map<int, Uint8List> keys})
  >
  _mergeEpochMaterial({
    required GroupManifest manifest,
    required List<ControlEntry> control,
    required List<GroupEpochRecipientEnvelope> existingEnvelopes,
    required Map<int, Uint8List> existingKeys,
    required List<GroupEpochRecipientEnvelope> incomingEnvelopes,
  }) async {
    final accepted = _acceptedControl(manifest, control);
    final keys = <int, Uint8List>{
      for (final entry in existingKeys.entries)
        if (_validLocalEpochKey(manifest, control, entry.key, entry.value))
          entry.key: entry.value,
    };
    final envelopes = <GroupEpochRecipientEnvelope>[];
    final seen = <String>{};
    void acceptEnvelope(
      GroupEpochRecipientEnvelope envelope, {
      required bool fromWire,
    }) {
      GroupEpochDescriptor? descriptor;
      for (final entry in accepted) {
        final candidate = entry.epochDescriptor;
        if (candidate != null &&
            candidate.groupId == envelope.groupId &&
            candidate.epoch == envelope.epoch &&
            candidate.keyCommitment == envelope.keyCommitment &&
            candidate.recipientCount == envelope.recipientCount &&
            verifyGroupEpochEnvelope(
              descriptor: candidate,
              envelope: envelope,
            )) {
          descriptor = candidate;
          break;
        }
      }
      if (descriptor == null ||
          (fromWire && envelope.recipient != _signer.selfId) ||
          !verifyGroupEpochEnvelope(
            descriptor: descriptor,
            envelope: envelope,
          )) {
        return;
      }
      final identity =
          '${envelope.epoch}:${envelope.recipient.hex}:${envelope.keyCommitment}';
      if (seen.add(identity)) envelopes.add(envelope);
    }

    for (final envelope in existingEnvelopes) {
      acceptEnvelope(envelope, fromWire: false);
    }
    for (final envelope in incomingEnvelopes) {
      acceptEnvelope(envelope, fromWire: true);
    }

    final opener = _epochService;
    if (opener != null) {
      for (final envelope in envelopes) {
        if (envelope.recipient != _signer.selfId ||
            keys.containsKey(envelope.epoch)) {
          continue;
        }
        GroupEpochDescriptor? descriptor;
        for (final entry in accepted) {
          final candidate = entry.epochDescriptor;
          if (candidate != null &&
              candidate.epoch == envelope.epoch &&
              candidate.keyCommitment == envelope.keyCommitment &&
              verifyGroupEpochEnvelope(
                descriptor: candidate,
                envelope: envelope,
              )) {
            descriptor = candidate;
            break;
          }
        }
        if (descriptor == null) continue;
        final issuer = _descriptorEntry(manifest, control, descriptor)?.author;
        if (issuer == null) continue;
        try {
          final opened = await opener.openEpoch(
            descriptor: descriptor,
            envelope: envelope,
            recipient: _signer.selfId,
            expectedIssuer: issuer,
            ourCertVersion: ourCertVersion,
          );
          keys[opened.epoch] = opened.key;
        } catch (_) {
          // Invalid, copied, stale or wrong-recipient epoch material is a
          // terminal silent drop: never reveal membership/key possession.
        }
      }
    }
    return (envelopes: envelopes, keys: keys);
  }

  ControlEntry? _channelDescriptorEntry(
    GroupManifest manifest,
    List<ControlEntry> control,
    GroupEpochDescriptor descriptor,
  ) {
    for (final entry in _acceptedControl(manifest, control)) {
      final candidate = entry.channelControl?.keyDescriptor;
      if (candidate != null && _sameEpochDescriptor(candidate, descriptor)) {
        return entry;
      }
    }
    return null;
  }

  bool _validLocalChannelEpochKey(
    GroupManifest manifest,
    List<ControlEntry> control,
    NodeId channelId,
    int epoch,
    Uint8List key,
  ) {
    if (key.length != 32) return false;
    for (final entry in _acceptedControl(manifest, control)) {
      final descriptor = entry.channelControl?.keyDescriptor;
      if (descriptor == null ||
          descriptor.groupId != channelId ||
          descriptor.epoch != epoch) {
        continue;
      }
      return descriptor.keyCommitment ==
          groupEpochKeyCommitment(groupId: channelId, epoch: epoch, key: key);
    }
    return false;
  }

  Future<
    ({List<GroupEpochRecipientEnvelope> envelopes, Map<String, Uint8List> keys})
  >
  _mergeChannelEpochMaterial({
    required GroupManifest manifest,
    required List<ControlEntry> control,
    required List<GroupEpochRecipientEnvelope> existingEnvelopes,
    required Map<String, Uint8List> existingKeys,
    required List<GroupEpochRecipientEnvelope> incomingEnvelopes,
  }) async {
    final accepted = _acceptedControl(manifest, control);
    final descriptors =
        <String, ({GroupEpochDescriptor value, NodeId issuer})>{};
    for (final entry in accepted) {
      final descriptor = entry.channelControl?.keyDescriptor;
      if (descriptor != null) {
        descriptors[_channelKeyId(descriptor.groupId, descriptor.epoch)] = (
          value: descriptor,
          issuer: entry.author,
        );
      }
    }
    final keys = <String, Uint8List>{
      for (final entry in existingKeys.entries)
        if (_validChannelKeyId(entry.key)) entry.key: entry.value,
    };
    keys.removeWhere((id, key) {
      final separator = id.lastIndexOf(':');
      try {
        return !_validLocalChannelEpochKey(
          manifest,
          control,
          NodeId.fromHex(id.substring(0, separator)),
          int.parse(id.substring(separator + 1)),
          key,
        );
      } catch (_) {
        return true;
      }
    });
    final envelopes = <GroupEpochRecipientEnvelope>[];
    final seen = <String>{};
    final authorizedIncomingScopes = <String>{};
    for (final envelope in incomingEnvelopes) {
      final id = _channelKeyId(envelope.groupId, envelope.epoch);
      final descriptor = descriptors[id]?.value;
      if (envelope.recipient == _signer.selfId &&
          descriptor != null &&
          verifyGroupEpochEnvelope(
            descriptor: descriptor,
            envelope: envelope,
          )) {
        authorizedIncomingScopes.add(id);
      }
    }

    void acceptEnvelope(
      GroupEpochRecipientEnvelope envelope, {
      required bool fromWire,
    }) {
      final descriptor =
          descriptors[_channelKeyId(envelope.groupId, envelope.epoch)]?.value;
      if (descriptor == null ||
          (fromWire &&
              !authorizedIncomingScopes.contains(
                _channelKeyId(envelope.groupId, envelope.epoch),
              )) ||
          !verifyGroupEpochEnvelope(
            descriptor: descriptor,
            envelope: envelope,
          )) {
        return;
      }
      final identity =
          '${envelope.groupId.hex}:${envelope.epoch}:'
          '${envelope.recipient.hex}:${envelope.keyCommitment}';
      if (seen.add(identity)) envelopes.add(envelope);
    }

    for (final envelope in existingEnvelopes) {
      acceptEnvelope(envelope, fromWire: false);
    }
    for (final envelope in incomingEnvelopes) {
      acceptEnvelope(envelope, fromWire: true);
    }

    final opener = _epochService;
    if (opener != null) {
      for (final envelope in envelopes) {
        final id = _channelKeyId(envelope.groupId, envelope.epoch);
        if (envelope.recipient != _signer.selfId || keys.containsKey(id)) {
          continue;
        }
        final source = descriptors[id];
        if (source == null) continue;
        try {
          final opened = await opener.openEpoch(
            descriptor: source.value,
            envelope: envelope,
            recipient: _signer.selfId,
            expectedIssuer: source.issuer,
            ourCertVersion: ourCertVersion,
          );
          keys[id] = opened.key;
        } catch (_) {
          // Wrong recipient, copied scope or invalid proof: silent drop.
        }
      }
    }
    return (envelopes: envelopes, keys: keys);
  }

  Future<List<GroupReaction>> _compactReactions(GroupBundle bundle) async {
    final latest = <String, GroupReaction>{};
    final heads = <String, GroupReaction>{};
    for (final stored in bundle.reactions) {
      if (!_validReactionFor(bundle.manifest.groupId, stored)) continue;
      final r = await _materializeEncryptedReaction(bundle, stored);
      if (r == null) continue;
      final key = '${r.author.hex}|${r.targetKind.name}|${r.target}';
      final current = latest[key];
      if (current == null || isNewerGroupReaction(r, current)) {
        latest[key] = r;
      }
      final headKey = '${_reactionGeneration(stored)}|${r.author.hex}';
      final head = heads[headKey];
      if (head == null || r.seq > head.seq) heads[headKey] = r;
    }
    final keep = <String>{
      for (final r in latest.values) '${r.author.hex}:${r.seq}',
      for (final r in heads.values) '${r.author.hex}:${r.seq}',
    };
    return [
      for (final r in bundle.reactions)
        if (_validReactionFor(bundle.manifest.groupId, r) &&
            keep.contains('${r.author.hex}:${r.seq}'))
          r,
    ];
  }

  List<GroupMessage> _compactDeviceMessages(
    NodeId groupId,
    List<GroupMessage> input,
  ) {
    final latest =
        <
          (DeviceSyncKind, String),
          ({DeviceSyncEvent event, GroupMessage message})
        >{};
    final heads = <String, GroupMessage>{};
    final unknown = <String>{};
    for (final m in input) {
      if (!_validMessageFor(groupId, m)) continue;
      final head = heads[m.author.hex];
      if (head == null || m.seq > head.seq) heads[m.author.hex] = m;
      final event = DeviceSyncEvent.fromBody(m.body);
      if (event == null) {
        // Forward-compatible: an older build must not erase a newer event kind.
        unknown.add(m.ref);
        continue;
      }
      final key = (event.kind, event.key);
      final current = latest[key];
      if (current == null ||
          isNewerDeviceSync(event, current.event) ||
          (!isNewerDeviceSync(current.event, event) &&
              _messageIdentityCompare(m, current.message) > 0)) {
        latest[key] = (event: event, message: m);
      }
    }
    final keep = <String>{
      ...unknown,
      for (final v in latest.values) v.message.ref,
      for (final m in heads.values) m.ref,
    };
    return [
      for (final m in input)
        if (_validMessageFor(groupId, m) && keep.contains(m.ref)) m,
    ];
  }

  int _messageIdentityCompare(GroupMessage a, GroupMessage b) {
    final author = a.author.hex.compareTo(b.author.hex);
    return author != 0 ? author : a.seq.compareTo(b.seq);
  }

  /// Compact only logs whose old entries are superseded state. Ordinary group
  /// messages are chat history and are never removed. Reaction winners and
  /// device-sync LWW winners are retained together with each author's max-seq
  /// row, preserving the current fold, next-seq allocation, and gap-fill
  /// high-water. Invalid/cross-group rows are scrubbed as part of the rewrite.
  Future<GroupLogCompaction?> compactStateLogs(NodeId groupId) async {
    return _serialized(groupId, () => _compactStateLogs(groupId));
  }

  Future<GroupLogCompaction?> _compactStateLogs(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return null;
    final control = [
      for (final e in b.control)
        if (_validControlFor(b.manifest, e)) e,
    ];
    final messages = b.manifest.name == kDeviceGroupName
        ? _compactDeviceMessages(groupId, b.messages)
        : _retainedMessageRows(b.manifest, b.messages);
    final reactions = await _compactReactions(b);
    final posts = _retainedPostRows(groupId, b.posts);
    final result = GroupLogCompaction(
      messagesBefore: b.messages.length,
      messagesAfter: messages.length,
      postsBefore: b.posts.length,
      postsAfter: posts.length,
      controlBefore: b.control.length,
      controlAfter: control.length,
      reactionsBefore: b.reactions.length,
      reactionsAfter: reactions.length,
    );
    if (result.changed) {
      await _save(
        b.copyWith(
          control: control,
          messages: messages,
          posts: posts,
          reactions: reactions,
        ),
      );
    }
    return result;
  }

  Future<List<String>> _index() async {
    final raw = await _storage.getSetting('groups.index');
    if (raw == null || raw.isEmpty) return [];
    try {
      final d = jsonDecode(raw);
      return d is List ? d.whereType<String>().toList() : [];
    } catch (_) {
      return [];
    }
  }

  Future<void> _setIndex(List<String> ids) =>
      _storage.putSetting('groups.index', jsonEncode(ids));

  String _spaceDeletionTombstoneKey(NodeId spaceId) =>
      'space.deleted:${spaceId.hex}.v1';

  Future<SpaceDeletionTombstone?> deletedSpaceTombstone(NodeId spaceId) async {
    final raw = await _storage.getSetting(_spaceDeletionTombstoneKey(spaceId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final tombstone = SpaceDeletionTombstone.fromJson(jsonDecode(raw));
      return tombstone?.spaceId == spaceId ? tombstone : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDeletedSpaceTombstone(SpaceDeletionTombstone tombstone) =>
      _storage.putSetting(
        _spaceDeletionTombstoneKey(tombstone.spaceId),
        jsonEncode(tombstone.toJson()),
      );

  Future<void> _clearDeletedSpaceTombstone(NodeId spaceId) =>
      _storage.putSetting(_spaceDeletionTombstoneKey(spaceId), '');

  String _key(NodeId groupId) => 'group:${groupId.hex}';

  /// Read a group's serialized bundle. It lives in the CHUNKED file-store, not a
  /// single setting: an inline image attachment can push the JSON well past the
  /// ~4 KB single-setting cap (HvException.PayloadTooLarge). Falls back to the
  /// legacy settings key for groups written before the store moved.
  Future<String?> _loadBundleRaw(NodeId groupId) async {
    final blob = await _storage.loadFile(_key(groupId));
    if (blob != null) return utf8.decode(blob);
    return _storage.getSetting(_key(groupId));
  }

  Future<GroupBundle?> load(NodeId groupId) async {
    final raw = await _loadBundleRaw(groupId);
    if (raw == null) return null;
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      final manifest = GroupManifest.fromJson(d['m']);
      if (manifest == null || !_validManifest(manifest)) return null;
      final control = (d['c'] as List? ?? const [])
          .map(ControlEntry.fromJson)
          .whereType<ControlEntry>()
          .toList();
      final messages = (d['g'] as List? ?? const [])
          .map(GroupMessage.fromJson)
          .whereType<GroupMessage>()
          .toList();
      final posts = (d['p'] as List? ?? const [])
          .map(SpacePost.fromJson)
          .whereType<SpacePost>()
          .toList();
      final reactions = (d['r'] as List? ?? const [])
          .map(GroupReaction.fromJson)
          .whereType<GroupReaction>()
          .toList();
      final epochEnvelopes = (d['ke'] as List? ?? const [])
          .map(GroupEpochRecipientEnvelope.fromJson)
          .whereType<GroupEpochRecipientEnvelope>()
          .toList();
      final channelEpochEnvelopes = (d['cke'] as List? ?? const [])
          .map(GroupEpochRecipientEnvelope.fromJson)
          .whereType<GroupEpochRecipientEnvelope>()
          .toList();
      final localEpochKeys = <int, Uint8List>{};
      final rawKeys = d['kk'];
      if (rawKeys is Map) {
        for (final entry in rawKeys.entries) {
          final epoch = int.tryParse('${entry.key}');
          if (epoch == null ||
              epoch < 0 ||
              epoch > 0xffffffff ||
              entry.value is! String) {
            continue;
          }
          try {
            final key = Uint8List.fromList(base64Decode(entry.value as String));
            if (key.length == 32) localEpochKeys[epoch] = key;
          } catch (_) {
            // Corrupt local key rows are ignored; the retained sealed envelope
            // can recover the key on a later load/ingest.
          }
        }
      }
      final localChannelEpochKeys = <String, Uint8List>{};
      final rawChannelKeys = d['ckk'];
      if (rawChannelKeys is Map) {
        for (final entry in rawChannelKeys.entries) {
          final id = '${entry.key}';
          if (!_validChannelKeyId(id) || entry.value is! String) continue;
          try {
            final key = Uint8List.fromList(base64Decode(entry.value as String));
            if (key.length == 32) localChannelEpochKeys[id] = key;
          } catch (_) {
            // Corrupt local rows are ignored; a retained sealed envelope may
            // recover the key on a later load or sync.
          }
        }
      }
      final sovereignBundle = d['s'] is String
          ? Uint8List.fromList(base64Decode(d['s'] as String))
          : null;
      if (!_validSovereignBundle(manifest, sovereignBundle)) return null;
      final material = await _mergeEpochMaterial(
        manifest: manifest,
        control: control,
        existingEnvelopes: epochEnvelopes,
        existingKeys: localEpochKeys,
        incomingEnvelopes: const [],
      );
      final channelMaterial = await _mergeChannelEpochMaterial(
        manifest: manifest,
        control: control,
        existingEnvelopes: channelEpochEnvelopes,
        existingKeys: localChannelEpochKeys,
        incomingEnvelopes: const [],
      );
      return GroupBundle(
        manifest: manifest,
        control: control,
        messages: messages,
        posts: posts,
        reactions: reactions,
        epochEnvelopes: material.envelopes,
        localEpochKeys: material.keys,
        channelEpochEnvelopes: channelMaterial.envelopes,
        localChannelEpochKeys: channelMaterial.keys,
        sovereignBundle: sovereignBundle,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(GroupBundle b, {bool notify = true}) async {
    // Chunked file-store (not putSetting): the bundle carries inline media that
    // overflows the single-setting cap. storeFile replaces the prior blob (or
    // no-ops if byte-identical) and chunks large values across commits.
    final json = jsonEncode({
      'm': b.manifest.toJson(),
      'c': b.control.map((e) => e.toJson()).toList(),
      'g': b.messages.map((m) => m.toJson()).toList(),
      if (b.posts.isNotEmpty)
        'p': b.posts.map((post) => post.toJson()).toList(),
      'r': b.reactions.map((x) => x.toJson()).toList(),
      if (b.epochEnvelopes.isNotEmpty)
        'ke': b.epochEnvelopes.map((entry) => entry.toJson()).toList(),
      if (b.localEpochKeys.isNotEmpty)
        'kk': {
          for (final entry in b.localEpochKeys.entries)
            '${entry.key}': base64Encode(entry.value),
        },
      if (b.channelEpochEnvelopes.isNotEmpty)
        'cke': b.channelEpochEnvelopes.map((entry) => entry.toJson()).toList(),
      if (b.localChannelEpochKeys.isNotEmpty)
        'ckk': {
          for (final entry in b.localChannelEpochKeys.entries)
            entry.key: base64Encode(entry.value),
        },
      if (b.sovereignBundle != null) 's': base64Encode(b.sovereignBundle!),
    });
    await _storage.storeFile(
      _key(b.manifest.groupId),
      Uint8List.fromList(utf8.encode(json)),
      name: 'group',
    );
    if (notify) changes.value++;
  }

  /// Start the idempotent lifecycle maintenance loop. GUI and headless hosts
  /// call this once after constructing the service; tests can invoke
  /// [purgeDeletedSpaces] directly with a deterministic clock.
  void startSpaceLifecycleMaintenance() {
    if (_spaceDeletionMaintenanceTimer != null) return;
    unawaited(_runSpaceDeletionMaintenance());
    _spaceDeletionMaintenanceTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(_runSpaceDeletionMaintenance()),
    );
  }

  Future<void> _runSpaceDeletionMaintenance() async {
    if (_spaceDeletionMaintenanceRunning) return;
    _spaceDeletionMaintenanceRunning = true;
    try {
      await purgeDeletedSpaces();
    } finally {
      _spaceDeletionMaintenanceRunning = false;
    }
  }

  /// Physically purge expired recoverable Space bundles in bounded batches.
  /// A compact anti-resurrection tombstone is committed first, then the heavy
  /// encrypted blob is deleted and scrubbed. Re-running after any partial
  /// failure is safe and converges to the same result.
  Future<SpaceDeletionSweep> purgeDeletedSpaces({
    int? nowMs,
    int limit = 16,
  }) async {
    if (limit <= 0 || limit > 256) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..256');
    }
    final now = nowMs ?? _now();
    final ids = await _index();
    final removedIds = <String>{};
    var scanned = 0;
    var purged = 0;
    var pending = 0;
    var failed = 0;
    var budget = limit;
    for (final hex in ids) {
      if (budget == 0) {
        continue;
      }
      NodeId spaceId;
      try {
        spaceId = NodeId.fromHex(hex);
      } catch (_) {
        continue;
      }
      final bundle = await load(spaceId);
      if (bundle == null) {
        if (await deletedSpaceTombstone(spaceId) != null) removedIds.add(hex);
        continue;
      }
      if (!bundle.manifest.isSpace) {
        continue;
      }
      scanned++;
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
        initialDescription: bundle.manifest.description ?? '',
      ).state;
      final transition = state.lifecycleTransition;
      final deadline = transition?.recoveryDeadlineMs;
      if (!state.isDeleted || deadline == null || now < deadline) {
        if (state.isDeleted) pending++;
        continue;
      }
      budget--;
      try {
        final didPurge = await _serialized(spaceId, () async {
          final current = await load(spaceId);
          if (current == null || !current.manifest.isSpace) return false;
          final currentState = foldControlLog(
            owner: current.manifest.owner,
            entries: current.control,
            verify: (entry) => _validControlFor(current.manifest, entry),
            initialName: current.manifest.name,
            initialDescription: current.manifest.description ?? '',
          ).state;
          final currentDeadline =
              currentState.lifecycleTransition?.recoveryDeadlineMs;
          final transitionHash = currentState.lifecycleTransitionHash;
          if (!currentState.isDeleted ||
              currentDeadline == null ||
              now < currentDeadline) {
            return false;
          }
          if (transitionHash == null) throw StateError('missing delete hash');
          await _saveDeletedSpaceTombstone(
            SpaceDeletionTombstone(
              spaceId: spaceId,
              deleteTransitionHash: transitionHash,
              recoveryDeadlineMs: currentDeadline,
              purgedAtMs: now,
            ),
          );
          await _storage.deleteStoredFile(_key(spaceId));
          return true;
        });
        if (didPurge) {
          purged++;
          removedIds.add(hex);
          devLog(
            () =>
                'xVeil[spaces]: purged deleted Space ${spaceId.short} '
                'after recovery deadline',
          );
        } else {
          pending++;
        }
      } catch (_) {
        failed++;
      }
    }
    if (removedIds.isNotEmpty) {
      final latest = await _index();
      await _setIndex([
        for (final id in latest)
          if (!removedIds.contains(id)) id,
      ]);
    }
    if (purged > 0) {
      await _storage.scrubDeleted();
      changes.value++;
    }
    return SpaceDeletionSweep(
      scanned: scanned,
      purged: purged,
      pending: pending,
      failed: failed,
    );
  }

  /// The group chats we are STILL A MEMBER of. Spaces are
  /// deliberately excluded: they have their own list and navigation surface.
  /// (or were never/no-longer a member of, per the folded control-log) is hidden
  /// without deleting its blob — the stored data lingers deniably and a fresh
  /// re-add simply folds us back in. (An admin-removal we never received doesn't
  /// hide the group on our side: we don't learn we were removed — no oracle.)
  Future<List<GroupListEntry>> listGroups() => _listUserGroups(spaces: false);

  /// The Spaces this identity currently belongs to. Group chats are excluded.
  Future<List<GroupListEntry>> listSpaces() => _listUserGroups(spaces: true);

  Future<List<GroupListEntry>> _listUserGroups({required bool spaces}) async {
    final out =
        <
          ({
            NodeId groupId,
            String name,
            String description,
            SpaceVisibility? visibility,
            SpaceLifecycleState lifecycleState,
            bool discoverable,
            int unread,
            int postUnread,
            bool muted,
            String preview,
            int lastTs,
          })
        >[];
    for (final hex in await _index()) {
      try {
        final b = await load(NodeId.fromHex(hex));
        if (b == null) continue;
        if (b.manifest.isSpace != spaces) continue;
        final state = foldControlLog(
          owner: b.manifest.owner,
          entries: b.control,
          verify: (e) => _validControlFor(b.manifest, e),
          initialName: b.manifest.name,
          initialDescription: b.manifest.description ?? '',
        ).state;
        if (!state.isMember(_signer.selfId)) continue;
        // Device groups are infrastructure, not chats — never listed.
        if (b.manifest.name == kDeviceGroupName) continue;
        final gid = b.manifest.groupId;
        // One validated pass powers unread AND the last-message preview.
        final wm =
            int.tryParse(await _storage.getSetting('group.seen:$hex') ?? '') ??
            0;
        final msgs = await messagesOf(gid);
        final last = msgs.isEmpty ? null : msgs.last;
        final spacePosts = spaces
            ? await postsOf(gid)
            : const <SpacePostView>[];
        final lastPost = spacePosts.isEmpty ? null : spacePosts.last;
        final postIsLatest =
            lastPost != null &&
            (last == null || lastPost.publishedAtMs >= last.createdAtMs);
        out.add((
          groupId: gid,
          name: state.name,
          description: state.description,
          visibility: b.manifest.visibility,
          lifecycleState: state.lifecycleState,
          discoverable: b.manifest.discoverable ?? false,
          unread: msgs
              .where((m) => m.createdAtMs > wm && m.author != _signer.selfId)
              .length,
          postUnread: await unreadSpacePosts(gid),
          muted: await isGroupMuted(gid),
          preview: postIsLatest
              ? (lastPost.title.trim().isNotEmpty
                    ? lastPost.title
                    : lastPost.body)
              : last == null
              ? ''
              : previewOf(last),
          // A brand-new chat has no message timestamp yet, but it must still
          // participate in the shared Chats recency ordering. Using zero sent
          // it below every established direct/group conversation, which made
          // successful creation look as if the chat had disappeared.
          lastTs: postIsLatest
              ? lastPost.publishedAtMs
              : last?.createdAtMs ?? b.manifest.createdAtMs,
        ));
      } catch (_) {}
    }
    return out;
  }

  /// Create a signed Space named [name] with us as the sole owner.
  Future<NodeId> createSpace(
    String name, {
    String description = '',
    String? avatarContentId,
    String? coverContentId,
    SpaceVisibility visibility = SpaceVisibility.private,
    bool discoverable = false,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty || normalizedName.length > 160) {
      throw ArgumentError.value(name, 'name', 'must contain 1..160 characters');
    }
    if (description.length > 4096) {
      throw ArgumentError.value(
        description,
        'description',
        'must not exceed 4096 characters',
      );
    }
    if ((avatarContentId?.length ?? 0) > 512 ||
        (coverContentId?.length ?? 0) > 512) {
      throw ArgumentError('Space content id must not exceed 512 characters');
    }
    final gid = _randomGroupId();
    final createdAtMs = _now();
    final unsignedManifest = SpaceManifest.space(
      spaceId: gid,
      owner: _signer.selfId,
      genesisPubKey: _signer.selfPubKey,
      name: normalizedName,
      description: description,
      avatarContentId: avatarContentId,
      coverContentId: coverContentId,
      visibility: visibility,
      discoverable: discoverable,
      createdAtMs: createdAtMs,
    );
    final manifest = _signer.signSpaceManifest(unsignedManifest);
    if (!_validManifest(manifest)) {
      throw StateError('space genesis signature rejected');
    }
    final defaultChannel = SpaceChannel(
      spaceId: gid,
      channelId: defaultSpaceChannelId(gid),
      kind: SpaceChannelKind.text,
      name: 'general',
      description: '',
      position: 0,
      isDefault: true,
      archived: false,
      history: SpaceChannelHistory.fromJoin,
      createdBy: _signer.selfId,
      createdAtMs: createdAtMs,
    );
    final channelControl = _signer.signControl(
      ControlEntry(
        version: 2,
        groupId: gid,
        author: _signer.selfId,
        seq: 0,
        prevHash: '',
        op: ControlOp.createChannel,
        target: null,
        role: null,
        policyVersion: 0,
        createdAtMs: createdAtMs,
        signature: Uint8List(0),
        channel: defaultChannel,
      ),
    );
    final initialFold = foldControlLog(
      owner: manifest.owner,
      entries: [channelControl],
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
    );
    if (initialFold.rejected.isNotEmpty ||
        initialFold.state.channels.length != 1) {
      throw StateError('default Space channel rejected');
    }
    var bundle = GroupBundle(
      manifest: manifest,
      control: [channelControl],
      messages: [],
    );
    final epochService = _epochService;
    if (epochService != null) {
      final key = _randomEpochKey();
      try {
        final sealed = await epochService.sealEpoch(
          groupId: gid,
          epoch: 1,
          epochKey: key,
          recipients: [_signer.selfId],
        );
        final signed = _signer.signControl(
          ControlEntry(
            version: 2,
            groupId: gid,
            author: _signer.selfId,
            seq: 1,
            prevHash: controlEntryHash(channelControl),
            op: ControlOp.rotateEpoch,
            target: null,
            role: null,
            policyVersion: 0,
            createdAtMs: _now(),
            signature: Uint8List(0),
            epochDescriptor: sealed.descriptor,
          ),
        );
        final folded = foldControlLog(
          owner: manifest.owner,
          entries: [channelControl, signed],
          verify: (entry) => _validControlFor(manifest, entry),
          initialName: manifest.name,
        );
        if (folded.rejected.isNotEmpty ||
            folded.state.epochDescriptor == null) {
          throw StateError('initial group epoch rejected');
        }
        bundle = GroupBundle(
          manifest: manifest,
          control: [channelControl, signed],
          messages: const [],
          epochEnvelopes: sealed.envelopes,
          localEpochKeys: {1: Uint8List.fromList(key)},
        );
      } finally {
        key.fillRange(0, key.length, 0);
      }
    }
    // Creation is visible only after both the bundle and its index entry are
    // durable. Emitting from _save here races listGroups against the old index.
    await _save(bundle, notify: false);
    final idx = await _index();
    idx.add(gid.hex);
    await _setIndex(idx);
    // The durable bundle/index commit is the moment list consumers may expose
    // the new Space. Without this tick an already-mounted Communities screen
    // kept its old StreamProvider value until some unrelated group mutation.
    changes.value++;
    return gid;
  }

  /// Create a group chat named [name] with us as the sole owner. Group chats
  /// keep the established group-wide message log and do not acquire Space
  /// channels, publications, visibility or subscriptions.
  Future<NodeId> createGroup(String name) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty || normalizedName.length > 64) {
      throw ArgumentError.value(name, 'name', 'must contain 1..64 characters');
    }
    final gid = _randomGroupId();
    final manifest = SpaceManifest(
      groupId: gid,
      owner: _signer.selfId,
      genesisPubKey: _signer.selfPubKey,
      name: normalizedName,
      createdAtMs: _now(),
    );
    var bundle = GroupBundle(manifest: manifest, control: [], messages: []);
    final epochService = _epochService;
    if (epochService != null) {
      final key = _randomEpochKey();
      try {
        final sealed = await epochService.sealEpoch(
          groupId: gid,
          epoch: 1,
          epochKey: key,
          recipients: [_signer.selfId],
        );
        final signed = _signer.signControl(
          ControlEntry(
            groupId: gid,
            author: _signer.selfId,
            seq: 0,
            prevHash: '',
            op: ControlOp.rotateEpoch,
            target: null,
            role: null,
            policyVersion: 0,
            createdAtMs: _now(),
            signature: Uint8List(0),
            epochDescriptor: sealed.descriptor,
          ),
        );
        final folded = foldControlLog(
          owner: manifest.owner,
          entries: [signed],
          verify: (entry) => _validControlFor(manifest, entry),
          initialName: manifest.name,
        );
        if (folded.rejected.isNotEmpty ||
            folded.state.epochDescriptor == null) {
          throw StateError('initial group epoch rejected');
        }
        bundle = GroupBundle(
          manifest: manifest,
          control: [signed],
          messages: const [],
          epochEnvelopes: sealed.envelopes,
          localEpochKeys: {1: Uint8List.fromList(key)},
        );
      } finally {
        key.fillRange(0, key.length, 0);
      }
    }
    // Creation is visible only after both the bundle and its index entry are
    // durable. Emitting from _save here races listGroups against the old index.
    await _save(bundle, notify: false);
    final idx = await _index();
    idx.add(gid.hex);
    await _setIndex(idx);
    // Creation is a list mutation too. Group chat screens are opened directly
    // after this call, so the missing tick stayed invisible until Back: the
    // Chats tab then kept the pre-create provider snapshot indefinitely.
    changes.value++;
    return gid;
  }

  /// Explicitly convert every eligible legacy group owned by this identity to
  /// a signed Space without changing ids, logs, messages, media references or
  /// epoch keys. This is intentionally NOT called at boot: group chats are
  /// first-class and conversion requires a separate user-confirmed workflow.
  /// A non-owner cannot manufacture genesis authority, so their copy remains
  /// readable until an owner-signed manifest arrives through normal sync.
  Future<SpaceManifestMigration> migrateOwnedLegacyGroupsToSpaces() async {
    var upgraded = 0;
    var alreadyCurrent = 0;
    var notOwner = 0;
    var failed = 0;
    final ids = await _index();
    for (final hex in ids.toSet()) {
      NodeId groupId;
      try {
        groupId = NodeId.fromHex(hex);
      } catch (_) {
        failed++;
        continue;
      }
      final outcome = await _serialized(groupId, () async {
        final bundle = await load(groupId);
        if (bundle == null) return 'failed';
        final legacy = bundle.manifest;
        if (legacy.isSpace ||
            legacy.isSovereignDevice ||
            legacy.name == kDeviceGroupName) {
          return 'current';
        }
        if (!legacy.isLegacyGroup) return 'failed';
        if (legacy.owner != _signer.selfId) return 'not-owner';
        final unsigned = SpaceManifest.space(
          spaceId: legacy.groupId,
          owner: legacy.owner,
          genesisPubKey: legacy.genesisPubKey,
          name: legacy.name,
          createdAtMs: legacy.createdAtMs,
        );
        final signed = _signer.signSpaceManifest(unsigned);
        if (!legacy.sameImmutableRoot(signed) || !_validManifest(signed)) {
          return 'failed';
        }
        final state = foldControlLog(
          owner: legacy.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(legacy, entry),
          initialName: legacy.name,
        ).state;
        final channelCreatedAt = _now();
        final defaultChannel = SpaceChannel(
          spaceId: legacy.groupId,
          channelId: defaultSpaceChannelId(legacy.groupId),
          kind: SpaceChannelKind.text,
          name: 'general',
          description: '',
          position: 0,
          isDefault: true,
          archived: false,
          history: SpaceChannelHistory.fromJoin,
          createdBy: _signer.selfId,
          createdAtMs: channelCreatedAt,
        );
        final link = _nextControlLink(legacy, bundle.control, _signer.selfId);
        if (link.blocked) return 'failed';
        final createChannel = _signer.signControl(
          ControlEntry(
            version: 2,
            groupId: legacy.groupId,
            author: _signer.selfId,
            seq: link.seq,
            prevHash: link.prevHash,
            op: ControlOp.createChannel,
            target: null,
            role: null,
            policyVersion: state.policyVersion,
            createdAtMs: channelCreatedAt,
            signature: Uint8List(0),
            channel: defaultChannel,
          ),
        );
        final candidate = [...bundle.control, createChannel];
        final folded = foldControlLog(
          owner: signed.owner,
          entries: candidate,
          verify: (entry) => _validControlFor(signed, entry),
          initialName: signed.name,
        );
        if (folded.rejected.any(
          (entry) =>
              entry.author == createChannel.author &&
              entry.seq == createChannel.seq,
        )) {
          return 'failed';
        }
        await _save(bundle.copyWith(manifest: signed, control: candidate));
        return 'upgraded';
      });
      switch (outcome) {
        case 'upgraded':
          upgraded++;
        case 'current':
          alreadyCurrent++;
        case 'not-owner':
          notOwner++;
        default:
          failed++;
      }
    }
    return SpaceManifestMigration(
      scanned: ids.toSet().length,
      upgraded: upgraded,
      alreadyCurrent: alreadyCurrent,
      notOwner: notOwner,
      failed: failed,
    );
  }

  NodeId _randomGroupId() {
    final rnd = Random.secure();
    return NodeId(
      Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256))),
    );
  }

  Uint8List _randomEpochKey() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
  }

  /// The current folded state of [groupId], or null if unknown.
  Future<GroupState?> stateOf(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return null;
    return foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
      initialName: b.manifest.name,
      initialDescription: b.manifest.description ?? '',
    ).state;
  }

  /// Current signed channels of one Space, ordered for presentation.
  Future<List<SpaceChannel>> channelsOf(
    NodeId spaceId, {
    bool includeArchived = false,
  }) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (state.isDeleted) return const [];
    final protected = await _protectedChannelsOf(bundle, state);
    final channels = [
      for (final channel in state.channels.values)
        if (includeArchived || !channel.archived) channel,
      for (final clear in protected.values)
        if (includeArchived || !clear.channel.archived) clear.channel,
    ];
    channels.sort((left, right) {
      final position = left.position.compareTo(right.position);
      if (position != 0) return position;
      return left.channelId.hex.compareTo(right.channelId.hex);
    });
    return channels;
  }

  Future<NodeId?> createChannel(
    NodeId spaceId, {
    required String name,
    required SpaceChannelKind kind,
    String description = '',
    NodeId? categoryId,
    int position = 0,
    bool isDefault = false,
    SpaceChannelHistory history = SpaceChannelHistory.fromJoin,
    int? historySinceMs,
    SpaceChannelAccess access = SpaceChannelAccess.space,
    Iterable<NodeId> members = const [],
  }) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (!SpaceAcl(
      state,
    ).allows(_signer.selfId, SpacePermission.manageChannels)) {
      return null;
    }
    final firstText =
        access == SpaceChannelAccess.space &&
        kind == SpaceChannelKind.text &&
        !state.channels.values.any(
          (channel) =>
              channel.kind == SpaceChannelKind.text && !channel.archived,
        );
    final createdAtMs = _now();
    final channel = SpaceChannel(
      spaceId: spaceId,
      channelId: _randomGroupId(),
      kind: kind,
      name: name.trim(),
      description: description,
      categoryId: categoryId,
      position: position,
      isDefault: kind == SpaceChannelKind.text && (isDefault || firstText),
      archived: false,
      history: history,
      historySinceMs: historySinceMs,
      createdBy: _signer.selfId,
      createdAtMs: createdAtMs,
      access: access,
    );
    if (!channel.isValid) return null;
    if (access != SpaceChannelAccess.space) {
      if (kind != SpaceChannelKind.text ||
          categoryId != null ||
          isDefault ||
          _epochService == null) {
        return null;
      }
      final applied = await _writeProtectedChannel(
        bundle,
        state,
        channel,
        requestedRecipients: members,
        create: true,
      );
      return applied ? channel.channelId : null;
    }
    final applied = await _addControlOp(
      spaceId,
      ControlOp.createChannel,
      channel: channel,
    );
    return applied ? channel.channelId : null;
  });

  /// Replace mutable channel fields while its signed identity remains fixed.
  Future<bool> updateChannel(NodeId spaceId, SpaceChannel channel) =>
      _serialized(spaceId, () async {
        final bundle = await load(spaceId);
        if (bundle == null || !bundle.manifest.isSpace) return false;
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
        ).state;
        if (!SpaceAcl(
              state,
            ).allows(_signer.selfId, SpacePermission.manageChannels) ||
            channel.spaceId != spaceId ||
            !channel.isValid) {
          return false;
        }
        if (channel.access != SpaceChannelAccess.space) {
          final protected = await _protectedChannelsOf(bundle, state);
          final current = protected[channel.channelId.hex];
          if (current == null ||
              !current.channel.sameIdentity(channel) ||
              _epochService == null) {
            return false;
          }
          return _writeProtectedChannel(
            bundle,
            state,
            channel,
            requestedRecipients: current.recipients,
            create: false,
          );
        }
        return _addControlOp(
          spaceId,
          ControlOp.updateChannel,
          channel: channel,
        );
      });

  /// Replace the explicit member portion of a protected channel ACL. Current
  /// Space owners/admins are always included so a future revocation never
  /// depends on one creator retaining the key. Every ACL mutation rotates the
  /// key and emits a new opaque signed control revision.
  Future<bool> setChannelMembers(
    NodeId spaceId,
    NodeId channelId,
    Iterable<NodeId> members,
  ) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace || _epochService == null) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (!SpaceAcl(
      state,
    ).allows(_signer.selfId, SpacePermission.manageChannels)) {
      return false;
    }
    final protected = await _protectedChannelsOf(bundle, state);
    final current = protected[channelId.hex];
    if (current == null) return false;
    return _writeProtectedChannel(
      bundle,
      state,
      current.channel,
      requestedRecipients: members,
      create: false,
    );
  });

  Future<List<NodeId>?> channelMembersOf(
    NodeId spaceId,
    NodeId channelId,
  ) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    final protected = await _protectedChannelsOf(bundle, state);
    final clear = protected[channelId.hex];
    if (clear != null) return List.unmodifiable(clear.recipients);
    if (state.channels.containsKey(channelId.hex)) {
      return List.unmodifiable(
        state.members.values.map((member) => member.nodeId),
      );
    }
    return null;
  }

  List<NodeId>? _protectedChannelRecipients(
    GroupState state,
    Iterable<NodeId> requested,
  ) {
    final recipients = <String, NodeId>{};
    for (final member in requested) {
      if (!state.isMember(member)) return null;
      recipients[member.hex] = member;
    }
    for (final member in state.members.values) {
      if (member.role.rank >= GroupRole.admin.rank) {
        recipients[member.nodeId.hex] = member.nodeId;
      }
    }
    recipients[_signer.selfId.hex] = _signer.selfId;
    final ordered = recipients.values.toList()
      ..sort((left, right) => left.hex.compareTo(right.hex));
    if (ordered.isEmpty || ordered.length > maxSpaceChannelRecipientCount) {
      return null;
    }
    return ordered;
  }

  Future<bool> _writeProtectedChannel(
    GroupBundle bundle,
    GroupState state,
    SpaceChannel channel, {
    required Iterable<NodeId> requestedRecipients,
    required bool create,
  }) async {
    final epochService = _epochService;
    if (epochService == null ||
        channel.access != SpaceChannelAccess.restricted ||
        channel.kind != SpaceChannelKind.text ||
        channel.categoryId != null ||
        channel.isDefault) {
      return false;
    }
    final recipients = _protectedChannelRecipients(state, requestedRecipients);
    if (recipients == null) return false;
    final previous = state.protectedChannels[channel.channelId.hex];
    if ((create && previous != null) || (!create && previous == null)) {
      return false;
    }
    final link = _nextControlLink(
      bundle.manifest,
      bundle.control,
      _signer.selfId,
    );
    if (link.blocked) return false;
    final channelEpoch = create ? 1 : previous!.channelEpoch + 1;
    final key = _randomEpochKey();
    Uint8List? clear;
    try {
      final sealed = await epochService.sealEpoch(
        groupId: channel.channelId,
        epoch: channelEpoch,
        epochKey: key,
        recipients: recipients,
      );
      final controlClear = SpaceChannelControlCleartext(
        channel: channel,
        recipients: recipients,
      );
      if (!controlClear.isStructurallyValid) return false;
      clear = controlClear.encode();
      final createdAtMs = _now();
      final encrypted = await encryptSpaceChannelControlPayload(
        spaceId: bundle.manifest.groupId,
        channelId: channel.channelId,
        channelEpoch: channelEpoch,
        keyCommitment: sealed.descriptor.keyCommitment,
        author: _signer.selfId,
        policyVersion: state.policyVersion,
        createdAtMs: createdAtMs,
        clearText: clear,
        channelKey: key,
      );
      final opaque = SpaceChannelControlEnvelope(
        spaceId: bundle.manifest.groupId,
        channelId: channel.channelId,
        channelEpoch: channelEpoch,
        keyDescriptor: sealed.descriptor,
        encryptedControl: encrypted,
      );
      final signed = _signer.signControl(
        ControlEntry(
          version: 5,
          groupId: bundle.manifest.groupId,
          author: _signer.selfId,
          seq: link.seq,
          prevHash: link.prevHash,
          op: create ? ControlOp.createChannel : ControlOp.updateChannel,
          target: null,
          role: null,
          policyVersion: state.policyVersion,
          createdAtMs: createdAtMs,
          signature: Uint8List(0),
          channelControl: opaque,
        ),
      );
      final candidate = [...bundle.control, signed];
      final folded = foldControlLog(
        owner: bundle.manifest.owner,
        entries: candidate,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
      );
      if (folded.rejected.any(
        (entry) => entry.author == signed.author && entry.seq == signed.seq,
      )) {
        return false;
      }
      final keyId = _channelKeyId(channel.channelId, channelEpoch);
      await _save(
        bundle.copyWith(
          control: candidate,
          channelEpochEnvelopes: [
            ...bundle.channelEpochEnvelopes,
            ...sealed.envelopes,
          ],
          localChannelEpochKeys: {
            ...bundle.localChannelEpochKeys,
            keyId: Uint8List.fromList(key),
          },
        ),
      );
      unawaited(broadcastDelta(bundle.manifest.groupId, control: [signed]));
      return true;
    } catch (_) {
      return false;
    } finally {
      clear?.fillRange(0, clear.length, 0);
      key.fillRange(0, key.length, 0);
    }
  }

  Future<void> _repairProtectedChannelEpochs(NodeId spaceId) =>
      _serialized(spaceId, () async {
        var bundle = await load(spaceId);
        if (bundle == null || !bundle.manifest.isSpace) {
          return;
        }
        var currentBundle = bundle;
        var state = foldControlLog(
          owner: currentBundle.manifest.owner,
          entries: currentBundle.control,
          verify: (entry) => _validControlFor(currentBundle.manifest, entry),
          initialName: currentBundle.manifest.name,
        ).state;
        if (state.roleOf(_signer.selfId) != GroupRole.owner) return;
        final ids = state.protectedChannels.keys.toList();
        for (final id in ids) {
          final envelope = state.protectedChannels[id];
          if (envelope == null) continue;
          final current = await _materializeProtectedChannel(
            currentBundle,
            state,
            envelope,
          );
          if (current != null) continue;
          final stale = await _materializeProtectedChannel(
            currentBundle,
            state,
            envelope,
            requireCurrentAcl: false,
          );
          if (stale == null) continue;
          final recipients = stale.recipients
              .where(state.isMember)
              .toList(growable: false);
          await _writeProtectedChannel(
            currentBundle,
            state,
            stale.channel,
            requestedRecipients: recipients,
            create: false,
          );
          final reloaded = await load(spaceId);
          if (reloaded == null) return;
          currentBundle = reloaded;
          state = foldControlLog(
            owner: currentBundle.manifest.owner,
            entries: currentBundle.control,
            verify: (entry) => _validControlFor(currentBundle.manifest, entry),
            initialName: currentBundle.manifest.name,
          ).state;
        }
      });

  Future<bool> setChannelArchived(
    NodeId spaceId,
    NodeId channelId,
    bool archived,
  ) async {
    final current = (await channelsOf(
      spaceId,
      includeArchived: true,
    )).where((channel) => channel.channelId == channelId).firstOrNull;
    if (current == null || current.archived == archived) return current != null;
    return updateChannel(spaceId, current.copyWith(archived: archived));
  }

  Future<bool> setDefaultChannel(NodeId spaceId, NodeId channelId) async {
    final current = (await channelsOf(
      spaceId,
      includeArchived: true,
    )).where((channel) => channel.channelId == channelId).firstOrNull;
    if (current == null ||
        current.kind != SpaceChannelKind.text ||
        current.archived) {
      return false;
    }
    if (current.isDefault) return true;
    return updateChannel(spaceId, current.copyWith(isDefault: true));
  }

  /// The next per-author seq for [author] in a list of entries carrying seq.
  int _nextSeq(Iterable<int> seqs) {
    var max = -1;
    for (final s in seqs) {
      if (s > max) max = s;
    }
    return max + 1;
  }

  /// Append a control op authored by us. Returns true if it was valid (signed,
  /// permitted against the current state) and persisted; false otherwise.
  Future<bool> addControlOp(
    NodeId groupId,
    ControlOp op, {
    NodeId? target,
    GroupRole? role,
    String? text,
    SpaceChannel? channel,
  }) => _serialized(
    groupId,
    () => _addControlOp(
      groupId,
      op,
      target: target,
      role: role,
      text: text,
      channel: channel,
    ),
  );

  Future<bool> _addControlOp(
    NodeId groupId,
    ControlOp op, {
    NodeId? target,
    GroupRole? role,
    String? text,
    SpaceChannel? channel,
    SpaceRulesVersion? rules,
    SpaceRulesAcceptance? rulesAcceptance,
    SpaceModerationAction? moderationAction,
    SpaceModerationRevocation? moderationRevocation,
    SpaceRetentionPolicy? retentionPolicy,
    SpaceLifecycleTransition? lifecycleTransition,
    SpacePostPin? postPin,
    SpaceRecommendationCampaign? recommendationCampaign,
    int? createdAtMs,
  }) async {
    final b = await load(groupId);
    if (b == null) return false;
    if (b.manifest.name == kDeviceGroupName) return false;
    if ((op == ControlOp.transferOwnership ||
            op == ControlOp.publishRules ||
            op == ControlOp.acceptRules ||
            op == ControlOp.moderate ||
            op == ControlOp.revokeModeration ||
            op == ControlOp.setRetention ||
            op == ControlOp.setPostPin ||
            op == ControlOp.setRecommendationCampaign ||
            op == ControlOp.archiveSpace ||
            op == ControlOp.deleteSpace ||
            op == ControlOp.restoreSpace) &&
        !b.manifest.isSpace) {
      return false;
    }
    final initialLink = _nextControlLink(b.manifest, b.control, _signer.selfId);
    if (initialLink.blocked) return false;
    var mySeq = initialLink.seq;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final protectedBefore = <SpaceChannelControlCleartext>[];
    final moderationRemovesMember =
        op == ControlOp.moderate &&
        moderationAction?.kind.removesMembership == true;
    final protectedAclMayChange =
        op == ControlOp.removeMember ||
        op == ControlOp.ban ||
        moderationRemovesMember ||
        op == ControlOp.setRole ||
        op == ControlOp.transferOwnership ||
        (op == ControlOp.addMember && role == GroupRole.admin);
    if (protectedAclMayChange) {
      for (final envelope in state.protectedChannels.values) {
        final clear = await _materializeProtectedChannel(
          b,
          state,
          envelope,
          requireCurrentAcl: false,
        );
        if (clear != null) protectedBefore.add(clear);
      }
    }
    final pv = state.policyVersion;
    final epochService = _epochService;
    final generatedKeys = <Uint8List>[];
    final controls = <ControlEntry>[];
    final envelopes = [...b.epochEnvelopes];
    final localKeys = <int, Uint8List>{
      for (final entry in b.localEpochKeys.entries) entry.key: entry.value,
    };
    try {
      GroupEpochSealSet? prepared;
      Uint8List? preparedKey;
      if (epochService != null &&
          (op == ControlOp.removeMember ||
              op == ControlOp.ban ||
              moderationRemovesMember ||
              op == ControlOp.rotateEpoch)) {
        final recipients = [
          for (final member in state.members.values)
            if ((op != ControlOp.removeMember &&
                    op != ControlOp.ban &&
                    !moderationRemovesMember) ||
                member.nodeId != target)
              member.nodeId,
        ];
        if (recipients.isEmpty) return false;
        preparedKey = _randomEpochKey();
        generatedKeys.add(preparedKey);
        prepared = await epochService.sealEpoch(
          groupId: groupId,
          epoch: state.epoch + 1,
          epochKey: preparedKey,
          recipients: recipients,
        );
      }

      final createdAt =
          createdAtMs ??
          (op == ControlOp.createChannel && channel != null
              ? channel.createdAtMs
              : _now());
      final revokesPublishing =
          op == ControlOp.mute ||
          op == ControlOp.removeMember ||
          op == ControlOp.ban ||
          (op == ControlOp.moderate &&
              moderationAction?.kind.blocksPosts == true);
      final postBoundary =
          b.manifest.isSpace && revokesPublishing && target != null
          ? _postBoundaryFor(b, target)
          : null;
      final signed = _signer.signControl(
        ControlEntry(
          version: lifecycleTransition != null
              ? lifecycleTransition.recoveryDeadlineMs == null
                    ? 10
                    : 11
              : postPin != null
              ? 12
              : recommendationCampaign != null
              ? 13
              : retentionPolicy != null
              ? 9
              : moderationAction != null || moderationRevocation != null
              ? 8
              : rules != null || rulesAcceptance != null
              ? 7
              : op == ControlOp.transferOwnership
              ? 6
              : postBoundary == null
              ? 2
              : 3,
          groupId: groupId,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: initialLink.prevHash,
          op: op,
          target: target,
          role: role,
          text: text,
          channel: channel,
          rules: rules,
          rulesAcceptance: rulesAcceptance,
          moderationAction: moderationAction,
          moderationRevocation: moderationRevocation,
          retentionPolicy: retentionPolicy,
          lifecycleTransition: lifecycleTransition,
          postPin: postPin,
          recommendationCampaign: recommendationCampaign,
          policyVersion: pv,
          createdAtMs: createdAt,
          signature: Uint8List(0),
          epochDescriptor: prepared?.descriptor,
          postBoundary: postBoundary,
        ),
      );
      controls.add(signed);
      var candidate = [...b.control, signed];
      var folded = foldControlLog(
        owner: b.manifest.owner,
        entries: candidate,
        verify: (entry) => _validControlFor(b.manifest, entry),
        initialName: b.manifest.name,
      );
      if (folded.rejected.any(
        (entry) =>
            identical(entry, signed) ||
            (entry.author == signed.author && entry.seq == signed.seq),
      )) {
        return false;
      }
      if (prepared != null && preparedKey != null) {
        envelopes.addAll(prepared.envelopes);
        localKeys[prepared.descriptor.epoch] = Uint8List.fromList(preparedKey);
      }

      // An add itself must remain readable by legacy peers, then an immediately
      // following signed rotate establishes a key for the post-add membership.
      // New members receive no older envelopes: forward secrecy is the default.
      if (op == ControlOp.addMember && epochService != null) {
        final key = _randomEpochKey();
        generatedKeys.add(key);
        final sealed = await epochService.sealEpoch(
          groupId: groupId,
          epoch: folded.state.epoch + 1,
          epochKey: key,
          recipients: folded.state.members.values.map(
            (member) => member.nodeId,
          ),
        );
        mySeq++;
        final rotate = _signer.signControl(
          ControlEntry(
            version: 2,
            groupId: groupId,
            author: _signer.selfId,
            seq: mySeq,
            prevHash: controlEntryHash(signed),
            op: ControlOp.rotateEpoch,
            target: null,
            role: null,
            policyVersion: folded.state.policyVersion,
            createdAtMs: createdAt + 1,
            signature: Uint8List(0),
            epochDescriptor: sealed.descriptor,
          ),
        );
        candidate = [...candidate, rotate];
        folded = foldControlLog(
          owner: b.manifest.owner,
          entries: candidate,
          verify: (entry) => _validControlFor(b.manifest, entry),
          initialName: b.manifest.name,
        );
        if (folded.rejected.any(
          (entry) =>
              identical(entry, rotate) ||
              (entry.author == rotate.author && entry.seq == rotate.seq),
        )) {
          return false;
        }
        controls.add(rotate);
        envelopes.addAll(sealed.envelopes);
        localKeys[sealed.descriptor.epoch] = Uint8List.fromList(key);
      }

      final savedBundle = b.copyWith(
        control: candidate,
        epochEnvelopes: envelopes,
        localEpochKeys: localKeys,
      );
      await _save(savedBundle);
      // A join needs the whole log; every other mutation is a bounded delta.
      if (protectedAclMayChange) {
        if (op == ControlOp.addMember) {
          await broadcast(groupId);
        } else {
          await broadcastDelta(groupId, control: controls);
        }
        for (final old in protectedBefore) {
          final latest = await load(groupId);
          if (latest == null) return false;
          final latestState = foldControlLog(
            owner: latest.manifest.owner,
            entries: latest.control,
            verify: (entry) => _validControlFor(latest.manifest, entry),
            initialName: latest.manifest.name,
          ).state;
          final recipients = old.recipients
              .where(latestState.isMember)
              .toList(growable: false);
          if (!await _writeProtectedChannel(
            latest,
            latestState,
            old.channel,
            requestedRecipients: recipients,
            create: false,
          )) {
            // Membership already folded, so the old ACL is unusable by
            // [requireCurrentAcl]. Keep the channel fail-closed until an admin
            // with the prior key retries; never resume with a stale epoch.
            devLog(
              () =>
                  'xVeil[spaces]: protected channel rekey failed after ACL '
                  'mutation (${old.channel.channelId.short})',
            );
          }
        }
      } else if (op == ControlOp.addMember) {
        unawaited(broadcast(groupId));
      } else {
        unawaited(broadcastDelta(groupId, control: controls));
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      for (final key in generatedKeys) {
        key.fillRange(0, key.length, 0);
      }
    }
  }

  /// Rename [groupId] (admins+). The name folds into every member's view via a
  /// signed `setName` op (delta-broadcast). Returns false if we lack permission.
  Future<bool> renameGroup(NodeId groupId, String name) {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.length > 160) {
      return Future.value(false);
    }
    return addControlOp(groupId, ControlOp.setName, text: normalized);
  }

  /// Update the public-facing Space summary through the same signed control
  /// log as the name. Empty text deliberately clears it; no mutable side-store
  /// can diverge between members.
  Future<bool> setSpaceDescription(NodeId spaceId, String description) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final normalized = description.trim();
    if (normalized.length > 4096) return false;
    return addControlOp(spaceId, ControlOp.setDescription, text: normalized);
  }

  /// Publish a typed Space-wide or open-channel retention revision. Protected
  /// channel ids are deliberately rejected here: placing one in the global
  /// control log would leak hidden metadata. Their encrypted policy envelope
  /// remains a later protocol revision.
  Future<bool> setSpaceRetentionPolicy(
    NodeId spaceId,
    SpaceRetentionPolicy policy,
  ) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null ||
        !bundle.manifest.isSpace ||
        !policy.isStructurallyValid) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(
      state,
    ).allows(_signer.selfId, SpacePermission.manageStorage)) {
      return false;
    }
    if (policy.channelId != null &&
        !state.channels.containsKey(policy.channelId!.hex)) {
      return false;
    }
    return _addControlOp(
      spaceId,
      ControlOp.setRetention,
      retentionPolicy: policy,
    );
  });

  String _localSpaceRetentionKey(NodeId spaceId) =>
      'space.retention.local.v1:${spaceId.hex}';

  Future<({int? days, int retiredBeforeMs})> _localSpaceRetention(
    NodeId spaceId,
  ) async {
    final raw = await _storage.getSetting(_localSpaceRetentionKey(spaceId));
    if (raw == null || raw.isEmpty) return (days: null, retiredBeforeMs: -1);
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1) {
        return (days: null, retiredBeforeMs: -1);
      }
      final days = value['days'];
      final retired = value['retiredBefore'];
      if ((days != null && (days is! int || days <= 0 || days > 36500)) ||
          retired is! int ||
          retired < -1) {
        return (days: null, retiredBeforeMs: -1);
      }
      return (days: days as int?, retiredBeforeMs: retired);
    } catch (_) {
      return (days: null, retiredBeforeMs: -1);
    }
  }

  Future<int?> localSpaceRetentionDays(NodeId spaceId) async =>
      (await _localSpaceRetention(spaceId)).days;

  Future<int> _localSpaceRetentionCutoff(NodeId spaceId, int atMs) async {
    final local = await _localSpaceRetention(spaceId);
    final rolling = local.days == null
        ? -1
        : atMs - Duration(days: local.days!).inMilliseconds;
    return rolling > local.retiredBeforeMs ? rolling : local.retiredBeforeMs;
  }

  /// Change only this device's materialized history window. The previously
  /// reached cutoff is retained, so extending the window never resurrects
  /// locally retired history and never mutates the signed Space policy.
  Future<bool> setLocalSpaceRetentionDays(NodeId spaceId, int? days) async {
    final bundle = await load(spaceId);
    if (bundle == null ||
        !bundle.manifest.isSpace ||
        (days != null && (days <= 0 || days > 36500))) {
      return false;
    }
    final now = _now();
    final cutoff = await _localSpaceRetentionCutoff(spaceId, now);
    await _storage.putSetting(
      _localSpaceRetentionKey(spaceId),
      jsonEncode({
        'v': 1,
        'days': ?days,
        'retiredBefore': cutoff,
        'updatedAt': now,
      }),
    );
    changes.value++;
    return true;
  }

  /// Publish a new immutable rules revision through the signed Space control
  /// log. Revisions are contiguous and keep the full previous history; a
  /// concurrent stale revision is rejected deterministically by the fold.
  Future<bool> publishSpaceRules(
    NodeId spaceId, {
    required String fullText,
    required String summary,
    int? effectiveAtMs,
  }) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(
      state,
    ).allows(_signer.selfId, SpacePermission.manageSettings)) {
      return false;
    }
    final normalizedText = fullText.trim();
    final normalizedSummary = summary.trim();
    final publishedAt = _now();
    // UI/API clocks the "effective now" choice before this signed mutation
    // receives its monotonic timestamp. Clamp a past/equal choice to the exact
    // signed publish time; preserve genuinely future activation dates.
    final requestedEffectiveAt = effectiveAtMs ?? publishedAt;
    final effectiveAt = requestedEffectiveAt > publishedAt
        ? requestedEffectiveAt
        : publishedAt;
    final nextVersion = (state.currentRules?.version ?? 0) + 1;
    final rules = SpaceRulesVersion(
      version: nextVersion,
      fullText: normalizedText,
      summary: normalizedSummary,
      author: _signer.selfId,
      publishedAtMs: publishedAt,
      effectiveAtMs: effectiveAt,
      previousVersion: nextVersion == 1 ? null : nextVersion - 1,
    );
    if (!rules.isStructurallyValid) return false;
    return _addControlOp(
      spaceId,
      ControlOp.publishRules,
      rules: rules,
      createdAtMs: publishedAt,
    );
  });

  /// Acknowledge the current rules as the active member. Publishing a later
  /// revision leaves this signed acknowledgement in history and makes
  /// [GroupState.requiresRulesAcceptance] true until the member accepts again.
  Future<bool> acceptSpaceRules(NodeId spaceId) =>
      _serialized(spaceId, () async {
        final bundle = await load(spaceId);
        if (bundle == null || !bundle.manifest.isSpace) return false;
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
          initialDescription: bundle.manifest.description ?? '',
        ).state;
        final rules = state.currentRules;
        if (rules == null || !state.isMember(_signer.selfId)) return false;
        if (!state.requiresRulesAcceptance(_signer.selfId)) return true;
        final acceptedAt = _now();
        return _addControlOp(
          spaceId,
          ControlOp.acceptRules,
          rulesAcceptance: SpaceRulesAcceptance(
            rulesVersion: rules.version,
            acceptedAtMs: acceptedAt,
          ),
          createdAtMs: acceptedAt,
        );
      });

  /// Append one signed moderation action and return its immutable audit id.
  /// The method is Space-only: group chats retain their existing lightweight
  /// membership controls and never acquire a community moderation ledger.
  Future<String?> moderateSpace(
    NodeId spaceId, {
    required SpaceModerationKind kind,
    required NodeId target,
    required SpaceModerationScope scope,
    required String reason,
    NodeId? channelId,
    int? expiresAtMs,
    SpaceModerationReference? reference,
  }) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final removesContent = {
      SpaceModerationKind.deleteMessage,
      SpaceModerationKind.deletePost,
    }.contains(kind);
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.moderate) ||
        (!state.isMember(target) &&
            !(removesContent &&
                state.roleOf(_signer.selfId) == GroupRole.owner))) {
      return null;
    }
    final createdAt = _now();
    final action = SpaceModerationAction(
      kind: kind,
      target: target,
      scope: scope,
      reason: reason.trim(),
      createdAtMs: createdAt,
      channelId: channelId,
      expiresAtMs: expiresAtMs,
      reference: reference,
    );
    if (!action.isStructurallyValid) return null;

    if (reference != null) {
      final exists = switch (reference.kind) {
        SpaceModerationReferenceKind.message => (await messagesOf(
          spaceId,
          channelId: reference.channelId,
        )).any((message) => message.ref == reference.contentId),
        SpaceModerationReferenceKind.spacePost => (await postsOf(
          spaceId,
        )).any((post) => post.postId == reference.contentId),
      };
      if (!exists) return null;
    }
    final link = _nextControlLink(
      bundle.manifest,
      bundle.control,
      _signer.selfId,
    );
    if (link.blocked) return null;
    final actionId = '${_signer.selfId.hex}:${link.seq}';
    final applied = await _addControlOp(
      spaceId,
      ControlOp.moderate,
      target: target,
      moderationAction: action,
      createdAtMs: createdAt,
    );
    return applied ? actionId : null;
  });

  /// Revoke a reversible moderation action. Content removals are deliberately
  /// irreversible; a moderator must publish new content instead of making an
  /// old signed deletion disappear. Revoking a ban only permits a later
  /// consent/invite flow — it never silently restores membership or old keys.
  Future<bool> revokeSpaceModeration(
    NodeId spaceId,
    String actionId, {
    required String reason,
  }) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final record = state.moderationRecords[actionId];
    if (record == null || record.revokedAtMs != null) return false;
    if ({
      SpaceModerationKind.deleteMessage,
      SpaceModerationKind.deletePost,
    }.contains(record.action.kind)) {
      return false;
    }
    final normalized = reason.trim();
    final revokedAt = _now();
    final revocation = SpaceModerationRevocation(
      actionAuthor: record.actor,
      actionSeq: record.actionSeq,
      reason: normalized,
      revokedAtMs: revokedAt,
    );
    if (!revocation.isStructurallyValid) return false;
    return _addControlOp(
      spaceId,
      ControlOp.revokeModeration,
      target: record.action.target,
      moderationRevocation: revocation,
      createdAtMs: revokedAt,
    );
  });

  Future<List<SpaceModerationRecord>> spaceModerationAudit(
    NodeId spaceId,
  ) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!state.isMember(_signer.selfId)) return const [];
    final records = state.moderationRecords.values.toList()
      ..sort((left, right) {
        final time = right.action.createdAtMs.compareTo(
          left.action.createdAtMs,
        );
        return time != 0 ? time : right.actionId.compareTo(left.actionId);
      });
    return records;
  }

  /// Move a Space through one owner-signed causal lifecycle transition.
  /// Group chats deliberately have no equivalent operation: their local
  /// conversation archive remains a per-device preference.
  Future<bool> _setSpaceLifecycle(
    NodeId spaceId,
    SpaceLifecycleState targetState, {
    Duration recoveryPeriod = kSpaceDeletionRecoveryPeriod,
  }) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final folded = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    );
    final state = folded.state;
    if (state.lifecycleState == targetState) return true;
    if (state.roleOf(_signer.selfId) != GroupRole.owner) return false;
    if ((targetState == SpaceLifecycleState.archived && !state.isActive) ||
        (targetState == SpaceLifecycleState.active && state.isActive) ||
        (targetState == SpaceLifecycleState.deleted && state.isDeleted) ||
        recoveryPeriod <= Duration.zero ||
        recoveryPeriod > kSpaceDeletionRecoveryMax) {
      return false;
    }
    final checkpoint = _controlCheckpoint(folded.accepted);
    if (checkpoint == null) return false;
    final previous = state.lifecycleTransition;
    final closingFromActive =
        targetState != SpaceLifecycleState.active && state.isActive;
    final messageHeads = closingFromActive
        ? _messageLifecycleHeads(bundle)
        : previous?.messageHeads;
    final postHeads = closingFromActive
        ? _postLifecycleHeads(bundle)
        : previous?.postHeads;
    final reactionHeads = closingFromActive
        ? _reactionLifecycleHeads(bundle)
        : previous?.reactionHeads;
    if (messageHeads == null || postHeads == null || reactionHeads == null) {
      return false;
    }
    final changedAt = _now();
    final recoveryDeadline = switch (targetState) {
      SpaceLifecycleState.deleted => changedAt + recoveryPeriod.inMilliseconds,
      SpaceLifecycleState.active when state.isDeleted =>
        previous?.recoveryDeadlineMs,
      _ => null,
    };
    final transition = SpaceLifecycleTransition(
      spaceId: spaceId,
      state: targetState,
      previousTransitionHash: state.lifecycleTransitionHash ?? '',
      controlCheckpoint: checkpoint,
      contentPolicyVersion: targetState != SpaceLifecycleState.active
          ? state.policyVersion
          : state.policyVersion + 1,
      messageHeads: messageHeads,
      postHeads: postHeads,
      reactionHeads: reactionHeads,
      changedAtMs: changedAt,
      recoveryDeadlineMs: recoveryDeadline,
    );
    if (!transition.isStructurallyValid) return false;
    final operation = switch (targetState) {
      SpaceLifecycleState.archived => ControlOp.archiveSpace,
      SpaceLifecycleState.deleted => ControlOp.deleteSpace,
      SpaceLifecycleState.active => ControlOp.restoreSpace,
    };
    return _addControlOp(
      spaceId,
      operation,
      lifecycleTransition: transition,
      createdAtMs: changedAt,
    );
  });

  Future<bool> setSpaceArchived(NodeId spaceId, bool archived) =>
      _setSpaceLifecycle(
        spaceId,
        archived ? SpaceLifecycleState.archived : SpaceLifecycleState.active,
      );

  Future<bool> archiveSpace(NodeId spaceId) => setSpaceArchived(spaceId, true);

  Future<bool> deleteSpace(
    NodeId spaceId, {
    Duration recoveryPeriod = kSpaceDeletionRecoveryPeriod,
  }) => _setSpaceLifecycle(
    spaceId,
    SpaceLifecycleState.deleted,
    recoveryPeriod: recoveryPeriod,
  );

  Future<bool> restoreSpace(NodeId spaceId) =>
      _setSpaceLifecycle(spaceId, SpaceLifecycleState.active);

  /// Atomically move the single effective owner role to an existing member.
  /// The immutable manifest owner remains the genesis signature root; it is
  /// deliberately not rewritten or re-signed during lifecycle operations.
  Future<bool> transferSpaceOwnership(NodeId spaceId, NodeId nextOwner) =>
      _serialized(spaceId, () async {
        final bundle = await load(spaceId);
        if (bundle == null || !bundle.manifest.isSpace) return false;
        return _addControlOp(
          spaceId,
          ControlOp.transferOwnership,
          target: nextOwner,
        );
      });

  /// Leave [groupId]: append a signed `leave` op (removes only us), tell the
  /// remaining members, and let [listGroups] hide it (the fold drops us). Idempotent
  /// if we already aren't a member; false for the owner (who cannot leave, v1).
  Future<bool> leaveGroup(NodeId groupId) =>
      _serialized(groupId, () => _leaveGroup(groupId));

  Future<bool> _leaveGroup(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return false;
    if (b.manifest.name == kDeviceGroupName) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final me = state.memberOf(_signer.selfId);
    if (me == null) return true; // already gone
    if (me.role == GroupRole.owner) return false; // owner can't leave (v1)
    final link = _nextControlLink(b.manifest, b.control, _signer.selfId);
    if (link.blocked) return false;
    final unsigned = ControlEntry(
      version: b.manifest.isSpace ? 3 : 2,
      groupId: groupId,
      author: _signer.selfId,
      seq: link.seq,
      prevHash: link.prevHash,
      op: ControlOp.leave,
      target: null,
      role: null,
      policyVersion: state.policyVersion,
      createdAtMs: _now(),
      signature: Uint8List(0),
      postBoundary: b.manifest.isSpace
          ? _postBoundaryFor(b, _signer.selfId)
          : null,
    );
    final signed = _signer.signControl(unsigned);
    final candidate = [...b.control, signed];
    final folded = foldControlLog(
      owner: b.manifest.owner,
      entries: candidate,
      verify: (e) => _validControlFor(b.manifest, e),
    );
    if (folded.rejected.any(
      (e) => e.author == signed.author && e.seq == signed.seq,
    )) {
      return false;
    }
    await _save(b.copyWith(control: candidate));
    // Tell the members who remain (broadcastDelta folds AFTER the leave, so it
    // fans out to them and never to us). They drop us from their roster.
    await broadcastDelta(groupId, control: [signed]);
    return true;
  }

  /// Post a message to [groupId]. Rejected (returns false) if we are not a
  /// non-muted member. An optional inline [attachment] rides inside the signed
  /// message (groups media brick 1) — no separate content fetch.
  Future<bool> postMessage(
    NodeId groupId,
    String body, {
    NodeId? channelId,
    GroupAttachment? attachment,
    String? replyTo,
    List<InlineCustomEmoji> customEmoji = const [],
    // Test/repro-only escape hatch: append WITHOUT the delta fanout —
    // simulates a delta lost in transit (total-outage class), so the
    // gap-fill path has a deterministic stand target.
    bool broadcast = true,
  }) => _serialized(
    groupId,
    () => _postMessage(
      groupId,
      body,
      channelId: channelId,
      attachment: attachment,
      replyTo: replyTo,
      customEmoji: customEmoji,
      broadcast: broadcast,
    ),
  );

  Future<bool> _postMessage(
    NodeId groupId,
    String body, {
    NodeId? channelId,
    GroupAttachment? attachment,
    String? replyTo,
    List<InlineCustomEmoji> customEmoji = const [],
    bool broadcast = true,
  }) async {
    if (!isValidInlineCustomEmoji(body, customEmoji)) return false;
    final b = await load(groupId);
    if (b == null) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    if (!SpaceAcl(
      state,
    ).allows(_signer.selfId, SpacePermission.publishMessages)) {
      return false;
    }
    NodeId? resolvedChannelId = channelId;
    SpaceChannelControlCleartext? protectedChannel;
    if (b.manifest.isSpace) {
      resolvedChannelId ??= state.channels.values
          .where(
            (channel) =>
                channel.kind == SpaceChannelKind.text &&
                channel.isDefault &&
                !channel.archived,
          )
          .firstOrNull
          ?.channelId;
      final protected = await _protectedChannelsOf(b, state);
      protectedChannel = resolvedChannelId == null
          ? null
          : protected[resolvedChannelId.hex];
      final channel = resolvedChannelId == null
          ? null
          : state.channels[resolvedChannelId.hex] ?? protectedChannel?.channel;
      if (channel == null ||
          channel.kind != SpaceChannelKind.text ||
          channel.archived ||
          (protectedChannel != null && attachment != null)) {
        return false;
      }
    } else if (resolvedChannelId != null) {
      return false;
    }
    final descriptor = state.epochDescriptor;
    final encryptionEstablished = _encryptionEstablished(b.manifest, b.control);
    final key = descriptor == null ? null : b.localEpochKeys[state.epoch];
    final lifecycleGeneration = b.manifest.isSpace
        ? state.lifecycleTransitionHash
        : null;
    final scopeBase = b.manifest.isSpace ? resolvedChannelId!.hex : 'group';
    final encryptionScope = protectedChannel != null
        ? '$scopeBase|channelEpoch:'
              '${state.protectedChannels[resolvedChannelId!.hex]?.channelEpoch}'
        : descriptor != null && key != null
        ? '$scopeBase|membershipEpoch:${state.epoch}'
        : '$scopeBase|clear';
    final targetScope =
        '$encryptionScope${lifecycleGeneration == null ? '' : '|lifecycle:$lifecycleGeneration'}';
    final retainedSelf = _retainedMessageRows(
      b.manifest,
      b.messages,
    ).where((message) => message.author == _signer.selfId).toList();
    if (_messageForks(
      b.manifest,
      retainedSelf,
    ).containsKey('$targetScope|${_signer.selfId.hex}')) {
      return false;
    }
    final canonicalSelf = _canonicalMessageRows(
      b.manifest,
      retainedSelf,
    ).where((message) => message.author == _signer.selfId).toList();
    final scopedSelf = canonicalSelf
        .where(
          (message) => _messageChainScope(b.manifest, message) == targetScope,
        )
        .toList();
    final acceptedScope = _acceptedMessageChain(
      b.manifest,
      canonicalSelf,
      _signer.selfId,
      targetScope,
    );
    if (acceptedScope.length != scopedSelf.length) {
      // Never author on top of a forked or broken local suffix. Gap-fill must
      // first recover the exact predecessor selected by the signed chain.
      return false;
    }
    final mySeq = _nextSeq(retainedSelf.map((message) => message.seq));
    // Sovereign device groups are compacted LWW state logs, not user history:
    // removing superseded rows is intentional there, so they retain the
    // legacy unchained shape until that CRDT gets its own checkpoint protocol.
    final prevHash = b.manifest.isSovereignDevice || acceptedScope.isEmpty
        ? ''
        : groupMessageHash(acceptedScope.last);
    if (protectedChannel == null &&
        encryptionEstablished &&
        (descriptor == null ||
            key == null ||
            !_validLocalEpochKey(b.manifest, b.control, state.epoch, key))) {
      return false;
    }
    final createdAt = _now();
    late final GroupMessage unsigned;
    if (protectedChannel != null) {
      final opaque = state.protectedChannels[resolvedChannelId!.hex];
      final channelKey = opaque == null
          ? null
          : b.localChannelEpochKeys[_channelKeyId(
              opaque.channelId,
              opaque.channelEpoch,
            )];
      if (opaque == null ||
          channelKey == null ||
          !_validLocalChannelEpochKey(
            b.manifest,
            b.control,
            opaque.channelId,
            opaque.channelEpoch,
            channelKey,
          )) {
        return false;
      }
      final clear = GroupMessageCleartext(
        body: body,
        replyTo: replyTo,
        customEmoji: customEmoji,
      ).encode();
      try {
        final encrypted = await encryptSpaceChannelMessagePayload(
          spaceId: groupId,
          channelId: opaque.channelId,
          channelEpoch: opaque.channelEpoch,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: prevHash,
          policyVersion: state.policyVersion,
          createdAtMs: createdAt,
          clearText: clear,
          channelKey: channelKey,
        );
        unsigned = GroupMessage(
          groupId: groupId,
          channelId: opaque.channelId,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: prevHash,
          body: '',
          version: lifecycleGeneration == null ? 3 : 6,
          channelEpoch: opaque.channelEpoch,
          encryptedPayload: encrypted,
          policyVersion: state.policyVersion,
          createdAtMs: createdAt,
          signature: Uint8List(0),
          lifecycleGeneration: lifecycleGeneration,
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } else if (descriptor != null && key != null) {
      final clear = GroupMessageCleartext(
        body: body,
        attachment: attachment,
        replyTo: replyTo,
        customEmoji: customEmoji,
      ).encode();
      try {
        final encrypted = await encryptGroupPayload(
          groupId: groupId,
          membershipEpoch: state.epoch,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: prevHash,
          policyVersion: state.policyVersion,
          createdAtMs: createdAt,
          clearText: clear,
          epochKey: key,
        );
        unsigned = GroupMessage(
          groupId: groupId,
          channelId: resolvedChannelId,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: prevHash,
          body: '',
          version: lifecycleGeneration == null ? 2 : 5,
          membershipEpoch: state.epoch,
          encryptedPayload: encrypted,
          policyVersion: state.policyVersion,
          createdAtMs: createdAt,
          signature: Uint8List(0),
          lifecycleGeneration: lifecycleGeneration,
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } else {
      unsigned = GroupMessage(
        groupId: groupId,
        channelId: resolvedChannelId,
        author: _signer.selfId,
        seq: mySeq,
        prevHash: prevHash,
        body: body,
        policyVersion: state.policyVersion,
        createdAtMs: createdAt,
        signature: Uint8List(0),
        attachment: attachment,
        replyTo: replyTo,
        customEmoji: customEmoji,
        version: lifecycleGeneration == null ? 1 : 4,
        lifecycleGeneration: lifecycleGeneration,
      );
    }
    final signed = _signer.signMessage(unsigned);
    await _save(b.copyWith(messages: [...b.messages, signed]));
    // Ship only the NEW message (delta), not the whole log — a post to a group
    // that already holds an image must not re-chunk that image over the wire.
    if (broadcast) unawaited(broadcastDelta(groupId, messages: [signed]));
    return true;
  }

  String _spacePostDraftKey(NodeId spaceId) =>
      'space.post-draft.v1:${spaceId.hex}';

  Future<bool> _canKeepSpacePostDraft(NodeId spaceId) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    return !state.isDeleted && state.isMember(_signer.selfId);
  }

  /// Load this identity's local draft for [spaceId]. The encrypted blob is
  /// deliberately outside the signed/P2P bundle and is invisible after access
  /// is revoked, even if stale local bytes remain until storage maintenance.
  Future<SpacePostDraft?> spacePostDraft(NodeId spaceId) =>
      _serializeSpacePostDrafts(() async {
        try {
          if (!await _canKeepSpacePostDraft(spaceId)) return null;
          final bytes = await _storage.loadFile(_spacePostDraftKey(spaceId));
          if (bytes == null || bytes.isEmpty) {
            devLog(() => 'xVeil[spaces]: local post draft is not stored');
            return null;
          }
          final draft = SpacePostDraft.fromJson(
            jsonDecode(utf8.decode(bytes, allowMalformed: false)),
            spaceId,
          );
          if (draft == null) {
            devLog(() => 'xVeil[spaces]: ignored malformed local post draft');
          }
          return draft;
        } catch (_) {
          // Storage/corruption must not block opening the publication list.
          devLog(() => 'xVeil[spaces]: failed to load local post draft');
          return null;
        }
      });

  /// Save an identity-local draft. Empty content means an explicit clear.
  /// Writes are serialized with clears so a delayed autosave cannot resurrect
  /// a draft after its signed publication succeeds.
  Future<bool> saveSpacePostDraft(
    NodeId spaceId, {
    required String title,
    required String body,
    required SpacePostType type,
  }) => _serializeSpacePostDrafts(() async {
    try {
      final draft = SpacePostDraft(
        spaceId: spaceId,
        title: title,
        body: body,
        type: type,
        updatedAtMs: _now(),
      );
      if (!draft.isStructurallyValid ||
          !await _canKeepSpacePostDraft(spaceId)) {
        return false;
      }
      final key = _spacePostDraftKey(spaceId);
      if (!draft.hasContent) {
        await _storage.deleteStoredFile(key);
        return true;
      }
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(draft.toJson())));
      await _storage.storeFile(key, bytes, name: 'space-post-draft');
      return true;
    } catch (_) {
      devLog(() => 'xVeil[spaces]: failed to save local post draft');
      return false;
    }
  });

  Future<bool> clearSpacePostDraft(NodeId spaceId) =>
      _serializeSpacePostDrafts(() async {
        try {
          await _storage.deleteStoredFile(_spacePostDraftKey(spaceId));
          return true;
        } catch (_) {
          devLog(() => 'xVeil[spaces]: failed to clear local post draft');
          return false;
        }
      });

  /// Publish one immutable Space feed row. Public Spaces produce signed
  /// cleartext rows suitable for a future non-member public-feed transport;
  /// private/secret Spaces encrypt the complete content with the current
  /// membership epoch. A draft is local UI state and never enters this log.
  Future<SpacePost?> publishSpacePost(
    NodeId spaceId, {
    required String body,
    String title = '',
    SpacePostType type = SpacePostType.post,
    List<MediaObjectRef> media = const [],
    bool broadcast = true,
  }) => _serialized(
    spaceId,
    () => _publishSpacePost(
      spaceId,
      body: body,
      title: title,
      type: type,
      media: media,
      broadcast: broadcast,
    ),
  );

  Future<SpacePost?> _publishSpacePost(
    NodeId spaceId, {
    required String body,
    required String title,
    required SpacePostType type,
    required List<MediaObjectRef> media,
    required bool broadcast,
  }) async {
    final cleartext = SpacePostCleartext(
      title: title.trim(),
      body: body.trim(),
      media: List<MediaObjectRef>.unmodifiable(media),
    );
    if (!cleartext.isStructurallyValid) return null;
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final currentFold = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    );
    final state = currentFold.state;
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.publishPosts)) {
      return null;
    }
    final lifecycleGeneration = state.lifecycleTransitionHash;
    final generationHash =
        lifecycleGeneration ?? _legacyPostGeneration(spaceId);
    final authored = _acceptedPostChain(
      spaceId,
      bundle.posts,
      _signer.selfId,
      generationHash: generationHash,
    );
    if (!_postMutationChainValid(authored)) return null;
    final acceptedHeadSeq = authored.isEmpty ? -1 : authored.last.seq;
    if (bundle.posts.any(
      (post) =>
          post.author == _signer.selfId &&
          _postGeneration(post) == generationHash &&
          _validPostFor(spaceId, post) &&
          post.seq > acceptedHeadSeq,
    )) {
      return null;
    }
    final checkpointResult = _ensurePostCheckpoint(
      bundle,
      currentFold,
      preferredCheckpointHash: authored.isEmpty
          ? null
          : authored.last.controlCheckpointHash,
    );
    if (checkpointResult == null) return null;
    final workingBundle = checkpointResult.bundle;
    final checkpointHash = controlEntryHash(checkpointResult.entry);
    final seq = _nextSeq(
      bundle.posts
          .where(
            (post) =>
                post.author == _signer.selfId && _validPostFor(spaceId, post),
          )
          .map((post) => post.seq),
    );
    final prevHash = authored.isEmpty ? '' : _spacePostHash(authored.last);
    final now = _now();
    final isPublic = bundle.manifest.visibility == SpaceVisibility.public;
    late final SpacePost unsigned;
    if (isPublic) {
      unsigned = SpacePost(
        spaceId: spaceId,
        author: _signer.selfId,
        seq: seq,
        prevHash: prevHash,
        type: type,
        visibility: SpacePostVisibility.public,
        title: cleartext.title,
        body: cleartext.body,
        media: cleartext.media,
        policyVersion: state.policyVersion,
        createdAtMs: now,
        publishedAtMs: now,
        version: lifecycleGeneration == null ? 5 : 9,
        controlCheckpointHash: checkpointHash,
        lifecycleGeneration: lifecycleGeneration,
        signature: Uint8List(0),
      );
    } else {
      final descriptor = state.epochDescriptor;
      final key = descriptor == null
          ? null
          : bundle.localEpochKeys[state.epoch];
      if (descriptor == null ||
          key == null ||
          !_validLocalEpochKey(
            bundle.manifest,
            bundle.control,
            state.epoch,
            key,
          )) {
        return null;
      }
      final encoded = cleartext.encode();
      try {
        final encrypted = await encryptSpacePostPayload(
          spaceId: spaceId,
          membershipEpoch: state.epoch,
          author: _signer.selfId,
          seq: seq,
          prevHash: prevHash,
          postType: type.name,
          visibility: SpacePostVisibility.members.name,
          policyVersion: state.policyVersion,
          createdAtMs: now,
          publishedAtMs: now,
          controlCheckpointHash: checkpointHash,
          lifecycleGeneration: lifecycleGeneration ?? '',
          clearText: encoded,
          epochKey: key,
        );
        unsigned = SpacePost(
          spaceId: spaceId,
          author: _signer.selfId,
          seq: seq,
          prevHash: prevHash,
          type: type,
          visibility: SpacePostVisibility.members,
          title: '',
          body: '',
          policyVersion: state.policyVersion,
          createdAtMs: now,
          publishedAtMs: now,
          version: lifecycleGeneration == null ? 6 : 10,
          membershipEpoch: state.epoch,
          encryptedPayload: encrypted,
          controlCheckpointHash: checkpointHash,
          lifecycleGeneration: lifecycleGeneration,
          signature: Uint8List(0),
        );
      } finally {
        encoded.fillRange(0, encoded.length, 0);
      }
    }
    final signed = _signer.signPost(unsigned);
    if (!_validPostFor(spaceId, signed)) return null;
    await _save(
      workingBundle.copyWith(posts: [...workingBundle.posts, signed]),
    );
    if (broadcast) {
      unawaited(
        broadcastDelta(
          spaceId,
          control: checkpointResult.created == null
              ? const []
              : [checkpointResult.created!],
          posts: [signed],
        ),
      );
    }
    return signed.withDecryptedContent(cleartext);
  }

  /// Append an author-signed revision while preserving the original post id
  /// and chronological cursor. Only the author can address a root in their
  /// own linear chain; moderator removals use a future distinct operation.
  Future<SpacePostView?> editSpacePost(
    NodeId spaceId,
    String postId, {
    required String title,
    required String body,
    SpacePostType? type,
    bool broadcast = true,
  }) => _serialized(spaceId, () async {
    final row = await _mutateSpacePost(
      spaceId,
      postId,
      operation: SpacePostOperation.edit,
      title: title,
      body: body,
      type: type,
      broadcast: broadcast,
    );
    if (row == null) return null;
    for (final post in await postsOf(spaceId)) {
      if (post.postId == postId && post.revisionId == row.postId) return post;
    }
    return null;
  });

  /// Append an irreversible author tombstone. The old signed rows remain as
  /// audit/fork evidence but disappear from feed and content grants.
  Future<bool> deleteSpacePost(
    NodeId spaceId,
    String postId, {
    bool broadcast = true,
  }) => _serialized(
    spaceId,
    () async =>
        await _mutateSpacePost(
          spaceId,
          postId,
          operation: SpacePostOperation.delete,
          title: '',
          body: '',
          broadcast: broadcast,
        ) !=
        null,
  );

  /// Pin or unpin one exact visible publication for the whole community.
  /// This is an admin control-log mutation, deliberately separate from the
  /// author's edit chain so moderators can manage another member's post
  /// without impersonating its author or rewriting its signed content.
  Future<bool> setSpacePostPinned(NodeId spaceId, String postId, bool pinned) =>
      _serialized(spaceId, () async {
        if (!_spacePostIdPattern.hasMatch(postId)) return false;
        final bundle = await load(spaceId);
        if (bundle == null || !bundle.manifest.isSpace) return false;
        final fold = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
          initialDescription: bundle.manifest.description ?? '',
        );
        if (!SpaceAcl(
          fold.state,
        ).allows(_signer.selfId, SpacePermission.managePosts)) {
          return false;
        }
        SpacePostView? target;
        for (final post in await _postsOfBundle(bundle)) {
          if (post.postId == postId) {
            target = post;
            break;
          }
        }
        if (target == null) return false;
        if (target.pinned == pinned) return true;
        final changedAt = _now();
        final payload = SpacePostPin(
          spaceId: spaceId,
          postAuthor: target.author,
          postSeq: target.seq,
          rootHash: _spacePostHash(target.root),
          pinned: pinned,
          changedAtMs: changedAt,
        );
        return _addControlOp(
          spaceId,
          ControlOp.setPostPin,
          postPin: payload,
          createdAtMs: changedAt,
        );
      });

  Future<SpacePost?> _mutateSpacePost(
    NodeId spaceId,
    String postId, {
    required SpacePostOperation operation,
    required String title,
    required String body,
    SpacePostType? type,
    required bool broadcast,
  }) async {
    if (operation == SpacePostOperation.publish) return null;
    final separator = postId.lastIndexOf(':');
    if (separator <= 0 || separator == postId.length - 1) return null;
    final targetAuthor = postId.substring(0, separator);
    final targetSeq = int.tryParse(postId.substring(separator + 1));
    if (targetAuthor != _signer.selfId.hex ||
        targetSeq == null ||
        targetSeq < 0) {
      return null;
    }
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    SpacePostView? target;
    for (final post in await _postsOfBundle(bundle)) {
      if (post.postId == postId) {
        target = post;
        break;
      }
    }
    if (target == null || target.author != _signer.selfId) return null;
    final cleartext = SpacePostCleartext(
      title: operation == SpacePostOperation.delete ? '' : title.trim(),
      body: operation == SpacePostOperation.delete ? '' : body.trim(),
      media: operation == SpacePostOperation.delete ? const [] : target.media,
      isTombstone: operation == SpacePostOperation.delete,
    );
    if (!cleartext.isStructurallyValid) return null;
    final currentFold = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    );
    final state = currentFold.state;
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.publishPosts)) {
      return null;
    }
    final lifecycleGeneration = state.lifecycleTransitionHash;
    if (target.effective.lifecycleGeneration != lifecycleGeneration) {
      return null;
    }
    final generationHash =
        lifecycleGeneration ?? _legacyPostGeneration(spaceId);
    final authored = _acceptedPostChain(
      spaceId,
      bundle.posts,
      _signer.selfId,
      generationHash: generationHash,
    );
    if (!_postMutationChainValid(authored)) return null;
    final acceptedHeadSeq = authored.isEmpty ? -1 : authored.last.seq;
    if (bundle.posts.any(
      (post) =>
          post.author == _signer.selfId &&
          _postGeneration(post) == generationHash &&
          _validPostFor(spaceId, post) &&
          post.seq > acceptedHeadSeq,
    )) {
      return null;
    }
    final checkpointResult = _ensurePostCheckpoint(
      bundle,
      currentFold,
      preferredCheckpointHash: authored.isEmpty
          ? null
          : authored.last.controlCheckpointHash,
    );
    if (checkpointResult == null) return null;
    final checkpointHash = controlEntryHash(checkpointResult.entry);
    final seq = _nextSeq(
      bundle.posts
          .where(
            (post) =>
                post.author == _signer.selfId && _validPostFor(spaceId, post),
          )
          .map((post) => post.seq),
    );
    if (targetSeq >= seq) return null;
    final prevHash = authored.isEmpty ? '' : _spacePostHash(authored.last);
    final now = _now();
    final postType = type ?? target.type;
    late final SpacePost unsigned;
    if (bundle.manifest.visibility == SpaceVisibility.public) {
      unsigned = SpacePost(
        spaceId: spaceId,
        author: _signer.selfId,
        seq: seq,
        prevHash: prevHash,
        type: postType,
        visibility: SpacePostVisibility.public,
        title: cleartext.title,
        body: cleartext.body,
        media: cleartext.media,
        policyVersion: state.policyVersion,
        createdAtMs: now,
        publishedAtMs: now,
        version: lifecycleGeneration == null ? 7 : 9,
        controlCheckpointHash: checkpointHash,
        operation: operation,
        targetSeq: targetSeq,
        lifecycleGeneration: lifecycleGeneration,
        signature: Uint8List(0),
      );
    } else {
      final descriptor = state.epochDescriptor;
      final key = descriptor == null
          ? null
          : bundle.localEpochKeys[state.epoch];
      if (descriptor == null ||
          key == null ||
          !_validLocalEpochKey(
            bundle.manifest,
            bundle.control,
            state.epoch,
            key,
          )) {
        return null;
      }
      final encoded = cleartext.encode();
      try {
        final encrypted = await encryptSpacePostPayload(
          spaceId: spaceId,
          membershipEpoch: state.epoch,
          author: _signer.selfId,
          seq: seq,
          prevHash: prevHash,
          postType: postType.name,
          visibility: SpacePostVisibility.members.name,
          policyVersion: state.policyVersion,
          createdAtMs: now,
          publishedAtMs: now,
          controlCheckpointHash: checkpointHash,
          postOperation: operation.name,
          targetSeq: targetSeq,
          lifecycleGeneration: lifecycleGeneration ?? '',
          clearText: encoded,
          epochKey: key,
        );
        unsigned = SpacePost(
          spaceId: spaceId,
          author: _signer.selfId,
          seq: seq,
          prevHash: prevHash,
          type: postType,
          visibility: SpacePostVisibility.members,
          title: '',
          body: '',
          policyVersion: state.policyVersion,
          createdAtMs: now,
          publishedAtMs: now,
          version: lifecycleGeneration == null ? 8 : 10,
          membershipEpoch: state.epoch,
          encryptedPayload: encrypted,
          controlCheckpointHash: checkpointHash,
          operation: operation,
          targetSeq: targetSeq,
          lifecycleGeneration: lifecycleGeneration,
          signature: Uint8List(0),
        );
      } finally {
        encoded.fillRange(0, encoded.length, 0);
      }
    }
    final signed = _signer.signPost(unsigned);
    if (!_validPostFor(spaceId, signed)) return null;
    await _save(
      checkpointResult.bundle.copyWith(
        posts: [...checkpointResult.bundle.posts, signed],
      ),
    );
    if (broadcast) {
      unawaited(
        broadcastDelta(
          spaceId,
          control: checkpointResult.created == null
              ? const []
              : [checkpointResult.created!],
          posts: [signed],
        ),
      );
    }
    return signed.withDecryptedContent(cleartext);
  }

  ({GroupBundle bundle, ControlEntry entry, ControlEntry? created})?
  _ensurePostCheckpoint(
    GroupBundle bundle,
    GroupFoldResult currentFold, {
    String? preferredCheckpointHash,
  }) {
    final currentGeneration = _postGrantAt(
      bundle.manifest,
      currentFold.accepted,
      _signer.selfId,
    );
    if (currentGeneration == null) return null;
    const reuseScanMax = 8;
    final candidates = <ControlEntry>[];
    if (preferredCheckpointHash != null) {
      for (final entry in currentFold.accepted) {
        if (entry.op == ControlOp.checkpoint &&
            controlEntryHash(entry) == preferredCheckpointHash) {
          candidates.add(entry);
          break;
        }
      }
    }
    for (final entry in currentFold.accepted.reversed) {
      if (candidates.length >= reuseScanMax) break;
      if (entry.op != ControlOp.checkpoint ||
          entry.policyVersion != currentFold.state.policyVersion ||
          candidates.any(
            (candidate) =>
                controlEntryHash(candidate) == controlEntryHash(entry),
          )) {
        continue;
      }
      candidates.add(entry);
    }
    for (final entry in candidates) {
      final historical = _foldAtControlCheckpoint(
        bundle.manifest,
        bundle.control,
        entry,
      );
      if (historical != null &&
          historical.state.policyVersion == currentFold.state.policyVersion &&
          SpaceAcl(
            historical.state,
          ).allows(_signer.selfId, SpacePermission.publishPosts) &&
          _postGrantAt(bundle.manifest, historical.accepted, _signer.selfId) ==
              currentGeneration) {
        return (bundle: bundle, entry: entry, created: null);
      }
    }

    final payload = _controlCheckpoint(currentFold.accepted);
    if (payload == null) return null;
    final link = _nextControlLink(
      bundle.manifest,
      bundle.control,
      _signer.selfId,
    );
    if (link.blocked) return null;
    final unsigned = ControlEntry(
      version: 4,
      groupId: bundle.manifest.groupId,
      author: _signer.selfId,
      seq: link.seq,
      prevHash: link.prevHash,
      op: ControlOp.checkpoint,
      target: null,
      role: null,
      controlCheckpoint: payload,
      policyVersion: currentFold.state.policyVersion,
      createdAtMs: _now(),
      signature: Uint8List(0),
    );
    final signed = _signer.signControl(unsigned);
    if (!_validControlFor(bundle.manifest, signed)) return null;
    final control = [...bundle.control, signed];
    final folded = foldControlLog(
      owner: bundle.manifest.owner,
      entries: control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    );
    final hash = controlEntryHash(signed);
    if (!folded.accepted.any((entry) => controlEntryHash(entry) == hash) ||
        _foldAtControlCheckpoint(bundle.manifest, control, signed) == null) {
      return null;
    }
    return (
      bundle: bundle.copyWith(control: control),
      entry: signed,
      created: signed,
    );
  }

  String _spacePostHash(SpacePost post) => crypto.sha256.convert([
    ...post.canonicalBytes(),
    ...post.signature,
  ]).toString();

  String _legacyPostGeneration(NodeId spaceId) => crypto.sha256
      .convert(
        utf8.encode('xveil.space-post-lifecycle.genesis.v1|${spaceId.hex}'),
      )
      .toString();

  String _postGeneration(SpacePost post) =>
      post.lifecycleGeneration ?? _legacyPostGeneration(post.spaceId);

  String _reactionHash(GroupReaction reaction) => crypto.sha256.convert([
    ...reaction.canonicalBytes(),
    ...reaction.signature,
  ]).toString();

  String _legacyReactionGeneration(NodeId spaceId) => crypto.sha256
      .convert(
        utf8.encode('xveil.space-reaction-lifecycle.genesis.v1|${spaceId.hex}'),
      )
      .toString();

  String _reactionGeneration(GroupReaction reaction) =>
      reaction.lifecycleGeneration ??
      _legacyReactionGeneration(reaction.groupId);

  /// A message chain never crosses a visibility boundary. The channel (for a
  /// Space) and encryption epoch are both part of the scope: a new member who
  /// receives only the post-join epoch must not need an undisclosed historical
  /// predecessor, and a revoked restricted-channel member must not learn the
  /// next epoch's head through a shared sync vector.
  String _messageChainScope(GroupManifest manifest, GroupMessage message) {
    final channel = manifest.isSpace
        ? (message.channelId ?? defaultSpaceChannelId(manifest.groupId)).hex
        : 'group';
    final encryption = message.isChannelEncrypted
        ? 'channelEpoch:${message.channelEpoch}'
        : message.isEncrypted
        ? 'membershipEpoch:${message.membershipEpoch}'
        : 'clear';
    final lifecycle = message.lifecycleGeneration;
    return '$channel|$encryption${lifecycle == null ? '' : '|lifecycle:$lifecycle'}';
  }

  /// Preserve every distinct valid signed row. Same-scope `(author, seq)`
  /// conflicts are evidence and must survive compaction/snapshot propagation;
  /// forgetting one branch would make the winner depend on arrival order.
  List<GroupMessage> _retainedMessageRows(
    GroupManifest manifest,
    Iterable<GroupMessage> input,
  ) {
    final rows = <String, GroupMessage>{};
    for (final message in input) {
      if (!_validMessageFor(manifest.groupId, message)) continue;
      rows[groupMessageHash(message)] = message;
    }
    return rows.values.toList();
  }

  Map<String, ({int seq, Set<String> hashes})> _messageForks(
    GroupManifest manifest,
    Iterable<GroupMessage> input,
  ) {
    final candidates = <String, Set<String>>{};
    final samples = <String, GroupMessage>{};
    for (final message in input) {
      if (!_validMessageFor(manifest.groupId, message)) continue;
      final scope = _messageChainScope(manifest, message);
      final identity = '$scope|${message.author.hex}:${message.seq}';
      candidates
          .putIfAbsent(identity, () => <String>{})
          .add(groupMessageHash(message));
      samples[identity] = message;
    }
    final forks = <String, ({int seq, Set<String> hashes})>{};
    for (final entry in candidates.entries) {
      if (entry.value.length <= 1) continue;
      final sample = samples[entry.key]!;
      final key =
          '${_messageChainScope(manifest, sample)}|${sample.author.hex}';
      final current = forks[key];
      if (current == null || sample.seq < current.seq) {
        forks[key] = (seq: sample.seq, hashes: Set.unmodifiable(entry.value));
      }
    }
    return forks;
  }

  /// Return valid rows outside an equivocated suffix in the same visibility
  /// scope. A fork in a restricted channel cannot suppress unrelated public
  /// channel history for members who are not allowed to learn that the hidden
  /// channel exists.
  List<GroupMessage> _canonicalMessageRows(
    GroupManifest manifest,
    Iterable<GroupMessage> input,
  ) {
    final candidates = <String, Map<String, GroupMessage>>{};
    for (final message in input) {
      if (!_validMessageFor(manifest.groupId, message)) continue;
      final scope = _messageChainScope(manifest, message);
      final identity = '$scope|${message.author.hex}:${message.seq}';
      candidates.putIfAbsent(
        identity,
        () => <String, GroupMessage>{},
      )[groupMessageHash(message)] = message;
    }
    final forkedAt = <String, int>{};
    for (final distinct in candidates.values) {
      if (distinct.length <= 1) continue;
      final sample = distinct.values.first;
      final key =
          '${_messageChainScope(manifest, sample)}|${sample.author.hex}';
      final current = forkedAt[key];
      if (current == null || sample.seq < current) forkedAt[key] = sample.seq;
    }
    return [
      for (final distinct in candidates.values)
        if (distinct.length == 1)
          if (distinct.values.single.seq <
              (forkedAt['${_messageChainScope(manifest, distinct.values.single)}|'
                      '${distinct.values.single.author.hex}'] ??
                  (1 << 62)))
            distinct.values.single,
    ];
  }

  /// Fold one author's chain inside one visibility scope. Legacy rows used an
  /// empty `prevHash`; the first modern row commits to the exact terminal
  /// legacy row and starts strict mode. From that point a missing predecessor,
  /// downgrade to an empty link, or wrong hash hides the whole scoped suffix
  /// until anti-entropy supplies the exact missing row.
  List<GroupMessage> _acceptedMessageChain(
    GroupManifest manifest,
    Iterable<GroupMessage> input,
    NodeId author,
    String scope,
  ) {
    final authored =
        _canonicalMessageRows(manifest, input)
            .where(
              (message) =>
                  message.author == author &&
                  _messageChainScope(manifest, message) == scope,
            )
            .toList()
          ..sort((left, right) => left.seq.compareTo(right.seq));
    final accepted = <GroupMessage>[];
    GroupMessage? predecessor;
    var strict = false;
    for (final message in authored) {
      if (predecessor != null && message.seq <= predecessor.seq) break;
      if (message.prevHash.isEmpty) {
        if (strict) break;
      } else {
        if (predecessor == null ||
            message.prevHash != groupMessageHash(predecessor)) {
          break;
        }
        strict = true;
      }
      accepted.add(message);
      predecessor = message;
    }
    return accepted;
  }

  List<GroupMessage> _acceptedMessageRows(
    GroupManifest manifest,
    Iterable<GroupMessage> input,
  ) {
    final canonical = _canonicalMessageRows(manifest, input);
    final chains = <String, ({NodeId author, String scope})>{};
    for (final message in canonical) {
      final scope = _messageChainScope(manifest, message);
      chains['$scope|${message.author.hex}'] = (
        author: message.author,
        scope: scope,
      );
    }
    final accepted = <GroupMessage>[
      for (final chain in chains.values)
        ..._acceptedMessageChain(
          manifest,
          canonical,
          chain.author,
          chain.scope,
        ),
    ];
    accepted.sort((left, right) {
      final time = left.createdAtMs.compareTo(right.createdAtMs);
      if (time != 0) return time;
      final author = left.author.hex.compareTo(right.author.hex);
      if (author != 0) return author;
      final seq = left.seq.compareTo(right.seq);
      if (seq != 0) return seq;
      return _messageChainScope(
        manifest,
        left,
      ).compareTo(_messageChainScope(manifest, right));
    });
    return accepted;
  }

  String _messageLifecycleScopeHash(
    GroupManifest manifest,
    GroupMessage message,
  ) => crypto.sha256
      .convert(
        utf8.encode(
          'xveil.space-message-lifecycle-scope.v1|'
          '${_messageChainScope(manifest, message)}',
        ),
      )
      .toString();

  List<SpaceMessageLifecycleHead> _messageLifecycleHeads(GroupBundle bundle) {
    final heads = <String, GroupMessage>{};
    for (final message in _acceptedMessageRows(
      bundle.manifest,
      bundle.messages,
    )) {
      final scopeHash = _messageLifecycleScopeHash(bundle.manifest, message);
      final identity = '$scopeHash|${message.author.hex}';
      final current = heads[identity];
      if (current == null || message.seq > current.seq) {
        heads[identity] = message;
      }
    }
    final ordered = heads.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return [
      for (final entry in ordered)
        SpaceMessageLifecycleHead(
          scopeHash: entry.key.substring(0, 64),
          author: entry.value.author,
          seq: entry.value.seq,
          hash: groupMessageHash(entry.value),
        ),
    ];
  }

  List<SpacePostLifecycleHead> _postLifecycleHeads(GroupBundle bundle) {
    final chains = <String, ({String generation, NodeId author})>{
      for (final post in _canonicalPostRows(
        bundle.manifest.groupId,
        bundle.posts,
      ))
        '${_postGeneration(post)}|${post.author.hex}': (
          generation: _postGeneration(post),
          author: post.author,
        ),
    };
    final heads = <SpacePostLifecycleHead>[];
    for (final entry in chains.values) {
      final chain = _acceptedPostChain(
        bundle.manifest.groupId,
        bundle.posts,
        entry.author,
        generationHash: entry.generation,
      );
      if (chain.isEmpty) continue;
      final terminal = chain.last;
      heads.add(
        SpacePostLifecycleHead(
          generationHash: entry.generation,
          author: entry.author,
          seq: terminal.seq,
          hash: _spacePostHash(terminal),
        ),
      );
    }
    heads.sort((left, right) => left.identity.compareTo(right.identity));
    return heads;
  }

  List<SpaceReactionLifecycleHead> _reactionLifecycleHeads(GroupBundle bundle) {
    final terminals = <String, GroupReaction>{};
    for (final reaction in bundle.reactions) {
      if (!_validReactionFor(bundle.manifest.groupId, reaction)) continue;
      final generation = _reactionGeneration(reaction);
      final identity = '$generation|${reaction.author.hex}';
      final current = terminals[identity];
      if (current == null || reaction.seq > current.seq) {
        terminals[identity] = reaction;
      }
    }
    final entries = terminals.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return [
      for (final entry in entries)
        SpaceReactionLifecycleHead(
          generationHash: _reactionGeneration(entry.value),
          author: entry.value.author,
          seq: entry.value.seq,
          hash: _reactionHash(entry.value),
        ),
    ];
  }

  bool _messageWithinLifecycleBoundary(
    GroupManifest manifest,
    GroupState state,
    GroupMessage message,
  ) {
    final transition = state.lifecycleTransition;
    if (transition == null) return true;
    final scopeHash = _messageLifecycleScopeHash(manifest, message);
    SpaceMessageLifecycleHead? boundary;
    for (final head in transition.messageHeads) {
      if (head.scopeHash == scopeHash && head.author == message.author) {
        boundary = head;
        break;
      }
    }
    if (boundary != null && message.seq <= boundary.seq) {
      return message.seq < boundary.seq ||
          groupMessageHash(message) == boundary.hash;
    }
    if (!state.isActive) return false;
    return message.lifecycleGeneration == state.lifecycleTransitionHash &&
        message.policyVersion >= transition.contentPolicyVersion;
  }

  List<GroupMessage> _acceptedMessagesWithinLifecycle(
    GroupBundle bundle,
    GroupState state,
  ) {
    final accepted = _acceptedMessageRows(bundle.manifest, bundle.messages);
    final transition = state.lifecycleTransition;
    if (transition == null) return accepted;
    final completePrefixes = <String>{};
    for (final head in transition.messageHeads) {
      if (accepted.any(
        (message) =>
            message.author == head.author &&
            _messageLifecycleScopeHash(bundle.manifest, message) ==
                head.scopeHash &&
            message.seq == head.seq &&
            groupMessageHash(message) == head.hash,
      )) {
        completePrefixes.add(head.identity);
      }
    }
    return [
      for (final message in accepted)
        if (() {
          final scopeHash = _messageLifecycleScopeHash(
            bundle.manifest,
            message,
          );
          SpaceMessageLifecycleHead? boundary;
          for (final head in transition.messageHeads) {
            if (head.scopeHash == scopeHash && head.author == message.author) {
              boundary = head;
              break;
            }
          }
          if (boundary != null && message.seq <= boundary.seq) {
            return completePrefixes.contains(boundary.identity);
          }
          return _messageWithinLifecycleBoundary(
            bundle.manifest,
            state,
            message,
          );
        }())
          message,
    ];
  }

  bool _postWithinLifecycleBoundary(GroupState state, SpacePost post) {
    final transition = state.lifecycleTransition;
    if (transition == null) return true;
    final generation = _postGeneration(post);
    SpacePostLifecycleHead? boundary;
    for (final head in transition.postHeads) {
      if (head.generationHash == generation && head.author == post.author) {
        boundary = head;
        break;
      }
    }
    if (boundary != null && post.seq <= boundary.seq) {
      return post.seq < boundary.seq || _spacePostHash(post) == boundary.hash;
    }
    if (!state.isActive) return false;
    return post.lifecycleGeneration == state.lifecycleTransitionHash &&
        post.policyVersion >= transition.contentPolicyVersion;
  }

  bool _reactionWithinLifecycleBoundary(
    GroupState state,
    GroupReaction reaction,
  ) {
    final transition = state.lifecycleTransition;
    if (transition == null) return true;
    final generation = _reactionGeneration(reaction);
    SpaceReactionLifecycleHead? boundary;
    for (final head in transition.reactionHeads) {
      if (head.generationHash == generation && head.author == reaction.author) {
        boundary = head;
        break;
      }
    }
    if (boundary != null && reaction.seq <= boundary.seq) {
      return reaction.seq < boundary.seq ||
          _reactionHash(reaction) == boundary.hash;
    }
    if (!state.isActive) return false;
    return reaction.lifecycleGeneration == state.lifecycleTransitionHash;
  }

  List<GroupReaction> _acceptedReactionsWithinLifecycle(
    GroupBundle bundle,
    GroupState state,
  ) {
    final valid = [
      for (final reaction in bundle.reactions)
        if (_validReactionFor(bundle.manifest.groupId, reaction)) reaction,
    ];
    final transition = state.lifecycleTransition;
    if (transition == null) return valid;
    final completePrefixes = <String>{};
    for (final head in transition.reactionHeads) {
      if (valid.any(
        (reaction) =>
            _reactionGeneration(reaction) == head.generationHash &&
            reaction.author == head.author &&
            reaction.seq == head.seq &&
            _reactionHash(reaction) == head.hash,
      )) {
        completePrefixes.add(head.identity);
      }
    }
    return [
      for (final reaction in valid)
        if (() {
          final generation = _reactionGeneration(reaction);
          SpaceReactionLifecycleHead? boundary;
          for (final head in transition.reactionHeads) {
            if (head.generationHash == generation &&
                head.author == reaction.author) {
              boundary = head;
              break;
            }
          }
          if (boundary != null && reaction.seq <= boundary.seq) {
            return completePrefixes.contains(boundary.identity);
          }
          return _reactionWithinLifecycleBoundary(state, reaction);
        }())
          reaction,
    ];
  }

  /// Return valid rows outside an equivocated suffix. Two distinct valid rows
  /// at the same `(author, seq)` quarantine that fork point and every later
  /// row by the author. Publication authority must never be chosen by a hash
  /// lottery because revocation boundaries bind an exact terminal chain.
  List<SpacePost> _canonicalPostRows(
    NodeId spaceId,
    Iterable<SpacePost> input,
  ) {
    final candidates = <String, Map<String, SpacePost>>{};
    for (final post in input) {
      if (!_validPostFor(spaceId, post)) continue;
      final identity =
          '${_postGeneration(post)}|${post.author.hex}:${post.seq}';
      candidates.putIfAbsent(
        identity,
        () => <String, SpacePost>{},
      )[_spacePostHash(post)] = post;
    }
    final forkedAt = <String, int>{};
    for (final distinct in candidates.values) {
      if (distinct.length <= 1) continue;
      final sample = distinct.values.first;
      final chain = '${_postGeneration(sample)}|${sample.author.hex}';
      final current = forkedAt[chain];
      if (current == null || sample.seq < current) {
        forkedAt[chain] = sample.seq;
      }
    }
    return [
      for (final distinct in candidates.values)
        if (distinct.length == 1 &&
            distinct.values.single.seq <
                (forkedAt['${_postGeneration(distinct.values.single)}|'
                        '${distinct.values.single.author.hex}'] ??
                    (1 << 62)))
          distinct.values.single,
    ];
  }

  /// Compaction may remove invalid/identical deliveries, but never distinct
  /// fork evidence: forgetting one branch would resurrect quarantined posts.
  List<SpacePost> _retainedPostRows(NodeId spaceId, Iterable<SpacePost> input) {
    final rows = <String, SpacePost>{};
    for (final post in input) {
      if (_validPostFor(spaceId, post)) rows[_spacePostHash(post)] = post;
    }
    return rows.values.toList();
  }

  List<SpacePost> _acceptedPostChain(
    NodeId spaceId,
    Iterable<SpacePost> input,
    NodeId author, {
    String? generationHash,
  }) {
    final canonical = _canonicalPostRows(
      spaceId,
      input,
    ).where((post) => post.author == author);
    final generations = <String, List<SpacePost>>{};
    for (final post in canonical) {
      final generation = _postGeneration(post);
      if (generationHash == null || generation == generationHash) {
        generations.putIfAbsent(generation, () => []).add(post);
      }
    }
    final accepted = <SpacePost>[];
    for (final entry in generations.entries) {
      final authored = entry.value
        ..sort((left, right) => left.seq.compareTo(right.seq));
      var expectedSeq = 0;
      var expectedPrev = '';
      final lifecycleScoped = authored.first.isLifecycleScoped;
      SpacePost? predecessor;
      for (final post in authored) {
        final sequenceValid = lifecycleScoped
            ? predecessor == null || post.seq > predecessor.seq
            : post.seq == expectedSeq;
        if (!sequenceValid || post.prevHash != expectedPrev) break;
        accepted.add(post);
        predecessor = post;
        expectedSeq++;
        expectedPrev = _spacePostHash(post);
      }
    }
    accepted.sort((left, right) => left.seq.compareTo(right.seq));
    return accepted;
  }

  /// Validate only the immutable mutation topology. Content/ACL/AEAD checks
  /// happen elsewhere; this gate prevents a writer from extending a signed but
  /// nonsensical suffix (edit-of-edit, missing root, or resurrection).
  bool _postMutationChainValid(Iterable<SpacePost> chain) {
    final roots = <int>{};
    final deleted = <int>{};
    for (final post in chain) {
      switch (post.operation) {
        case SpacePostOperation.publish:
          roots.add(post.seq);
        case SpacePostOperation.edit:
          final target = post.targetSeq;
          if (target == null ||
              !roots.contains(target) ||
              deleted.contains(target)) {
            return false;
          }
        case SpacePostOperation.delete:
          final target = post.targetSeq;
          if (target == null ||
              !roots.contains(target) ||
              !deleted.add(target)) {
            return false;
          }
      }
    }
    return true;
  }

  SpacePostBoundary _postBoundaryFor(GroupBundle bundle, NodeId author) {
    final chain = _acceptedPostChain(
      bundle.manifest.groupId,
      bundle.posts,
      author,
    );
    if (chain.isEmpty) return const SpacePostBoundary(seq: -1, hash: '');
    final terminal = chain.last;
    return SpacePostBoundary(seq: terminal.seq, hash: _spacePostHash(terminal));
  }

  String? _postGrantAt(
    GroupManifest manifest,
    Iterable<ControlEntry> accepted,
    NodeId author,
  ) {
    String? grant = author == manifest.owner ? 'genesis' : null;
    for (final entry in accepted) {
      final affected = entry.op == ControlOp.leave
          ? entry.author
          : entry.target;
      if (affected != author) continue;
      switch (entry.op) {
        case ControlOp.addMember:
        case ControlOp.unmute:
          grant = controlEntryHash(entry);
        case ControlOp.mute:
        case ControlOp.removeMember:
        case ControlOp.ban:
        case ControlOp.leave:
          grant = null;
        case ControlOp.setRole:
        case ControlOp.transferOwnership:
        case ControlOp.rotateEpoch:
        case ControlOp.setPolicy:
        case ControlOp.setRetention:
        case ControlOp.setName:
        case ControlOp.setDescription:
        case ControlOp.publishRules:
        case ControlOp.acceptRules:
        case ControlOp.moderate:
        case ControlOp.revokeModeration:
        case ControlOp.createChannel:
        case ControlOp.updateChannel:
        case ControlOp.archiveSpace:
        case ControlOp.deleteSpace:
        case ControlOp.restoreSpace:
        case ControlOp.setPostPin:
        case ControlOp.setRecommendationCampaign:
        case ControlOp.checkpoint:
          break;
      }
    }
    return grant;
  }

  ({bool revoked, SpacePostBoundary? boundary}) _postRevocationForGrant(
    GroupManifest manifest,
    Iterable<ControlEntry> accepted,
    NodeId author,
    String generation,
    int atMs,
  ) {
    final revokedModeration = <String>{
      for (final entry in accepted)
        if (entry.op == ControlOp.revokeModeration &&
            entry.moderationRevocation != null &&
            entry.moderationRevocation!.revokedAtMs <= atMs)
          entry.moderationRevocation!.actionId,
    };
    String? grant = author == manifest.owner ? 'genesis' : null;
    for (final entry in accepted) {
      final affected = entry.op == ControlOp.leave
          ? entry.author
          : entry.target;
      if (affected != author) continue;
      switch (entry.op) {
        case ControlOp.addMember:
        case ControlOp.unmute:
          grant = controlEntryHash(entry);
        case ControlOp.mute:
        case ControlOp.removeMember:
        case ControlOp.ban:
        case ControlOp.leave:
          if (grant == generation) {
            return (revoked: true, boundary: entry.postBoundary);
          }
          grant = null;
        case ControlOp.moderate:
          final action = entry.moderationAction;
          if (action != null &&
              action.kind.blocksPosts &&
              action.createdAtMs <= atMs &&
              (action.expiresAtMs == null || atMs < action.expiresAtMs!) &&
              !revokedModeration.contains('${entry.author.hex}:${entry.seq}')) {
            if (grant == generation) {
              return (revoked: true, boundary: entry.postBoundary);
            }
          }
        case ControlOp.revokeModeration:
          break;
        case ControlOp.setRole:
        case ControlOp.transferOwnership:
        case ControlOp.rotateEpoch:
        case ControlOp.setPolicy:
        case ControlOp.setRetention:
        case ControlOp.setName:
        case ControlOp.setDescription:
        case ControlOp.publishRules:
        case ControlOp.acceptRules:
        case ControlOp.createChannel:
        case ControlOp.updateChannel:
        case ControlOp.archiveSpace:
        case ControlOp.deleteSpace:
        case ControlOp.restoreSpace:
        case ControlOp.setPostPin:
        case ControlOp.setRecommendationCampaign:
        case ControlOp.checkpoint:
          break;
      }
    }
    return (revoked: false, boundary: null);
  }

  GroupFoldResult? _historicalFoldForPost(
    GroupManifest manifest,
    List<ControlEntry> control,
    SpacePost post,
    Iterable<ControlEntry> acceptedControl,
  ) {
    if (!post.isCausal) return null;
    if (post.isCheckpointed) {
      final checkpointHash = post.controlCheckpointHash;
      if (checkpointHash == null) return null;
      ControlEntry? checkpointEntry;
      for (final entry in acceptedControl) {
        if (entry.op == ControlOp.checkpoint &&
            controlEntryHash(entry) == checkpointHash) {
          checkpointEntry = entry;
          break;
        }
      }
      return checkpointEntry == null
          ? null
          : _foldAtControlCheckpoint(manifest, control, checkpointEntry);
    }
    final frontier = post.controlFrontier;
    return frontier == null
        ? null
        : _foldAtPostFrontier(manifest, control, frontier);
  }

  bool _causalPostAuthorized(
    GroupBundle bundle,
    SpacePost post,
    List<SpacePost> acceptedAuthorChain,
    List<ControlEntry> currentAcceptedControl,
    Map<String, GroupFoldResult> historicalCache,
    Set<String> invalidHistoricalFrontiers,
  ) {
    if (!post.isCausal) return false;
    final historicalKey = post.isCheckpointed
        ? 'checkpoint:${post.controlCheckpointHash}'
        : 'frontier:${jsonEncode(post.controlFrontier?.toJson())}';
    if (invalidHistoricalFrontiers.contains(historicalKey)) return false;
    var historical = historicalCache[historicalKey];
    if (historical == null) {
      historical = _historicalFoldForPost(
        bundle.manifest,
        bundle.control,
        post,
        currentAcceptedControl,
      );
      if (historical == null) {
        invalidHistoricalFrontiers.add(historicalKey);
        return false;
      }
      historicalCache[historicalKey] = historical;
    }
    if (historical.state.policyVersion != post.policyVersion ||
        !SpaceAcl(historical.state).allows(
          post.author,
          SpacePermission.publishPosts,
          atMs: post.createdAtMs,
        )) {
      return false;
    }
    final generation = _postGrantAt(
      bundle.manifest,
      historical.accepted,
      post.author,
    );
    if (generation == null) return false;
    final revocation = _postRevocationForGrant(
      bundle.manifest,
      currentAcceptedControl,
      post.author,
      generation,
      post.createdAtMs,
    );
    if (!revocation.revoked) return true;
    final boundary = revocation.boundary;
    if (boundary == null || boundary.seq < 0 || post.seq > boundary.seq) {
      return false;
    }
    return acceptedAuthorChain.any(
      (candidate) =>
          candidate.seq == boundary.seq &&
          _spacePostHash(candidate) == boundary.hash,
    );
  }

  bool _causalPostHistoricallyAuthorized(
    GroupManifest manifest,
    List<ControlEntry> control,
    SpacePost post,
  ) {
    if (!post.isCausal) return false;
    final accepted = _acceptedControl(manifest, control);
    final historical = _historicalFoldForPost(
      manifest,
      control,
      post,
      accepted,
    );
    return historical != null &&
        historical.state.policyVersion == post.policyVersion &&
        SpaceAcl(historical.state).allows(
          post.author,
          SpacePermission.publishPosts,
          atMs: post.createdAtMs,
        ) &&
        _postGrantAt(manifest, historical.accepted, post.author) != null;
  }

  /// Validated, decrypted publication log for one Space. Legacy per-author
  /// chains are contiguous from seq 0; post-restore chains are independently
  /// scoped by their signed lifecycle generation.
  Future<List<SpacePostView>> postsOf(NodeId spaceId) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const [];
    return _postsOfBundle(bundle, applyLocalRetention: true);
  }

  /// Variant for callers that already loaded the bundle. Keeping validation in
  /// one place avoids a second hidden-volume read for every Space in the merged
  /// feed while preserving the exact same fail-closed path as [postsOf].
  Future<List<SpacePostView>> _postsOfBundle(
    GroupBundle bundle, {
    bool applyLocalRetention = false,
  }) async {
    final spaceId = bundle.manifest.groupId;
    final readAt = DateTime.now().millisecondsSinceEpoch;
    final currentFold = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    );
    final state = currentFold.state;
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.view)) {
      return const [];
    }
    final localCutoff = applyLocalRetention
        ? await _localSpaceRetentionCutoff(spaceId, readAt)
        : -1;
    final byChain = <String, ({NodeId author, String generation})>{};
    for (final post in _canonicalPostRows(spaceId, bundle.posts)) {
      final generation = _postGeneration(post);
      byChain['$generation|${post.author.hex}'] = (
        author: post.author,
        generation: generation,
      );
    }
    final visiblePosts = <SpacePostView>[];
    final historicalCache = <String, GroupFoldResult>{};
    final invalidHistoricalFrontiers = <String>{};
    for (final chainKey in byChain.values) {
      final acceptedAuthorChain = _acceptedPostChain(
        spaceId,
        bundle.posts,
        chainKey.author,
        generationHash: chainKey.generation,
      );
      SpacePostLifecycleHead? lifecycleBoundary;
      for (final head in state.lifecycleTransition?.postHeads ?? const []) {
        if (head.generationHash == chainKey.generation &&
            head.author == chainKey.author) {
          lifecycleBoundary = head;
          break;
        }
      }
      if (lifecycleBoundary != null &&
          !acceptedAuthorChain.any(
            (post) =>
                post.seq == lifecycleBoundary!.seq &&
                _spacePostHash(post) == lifecycleBoundary.hash,
          )) {
        // Do not reveal a partial historical prefix until the exact signed
        // archive terminal is present; gap-fill can complete it later.
        continue;
      }
      final roots = <int, SpacePostView>{};
      final deletedRoots = <int>{};
      for (final post in acceptedAuthorChain) {
        if (!_postWithinLifecycleBoundary(state, post)) break;
        final authorized = post.isCausal
            ? _causalPostAuthorized(
                bundle,
                post,
                acceptedAuthorChain,
                currentFold.accepted,
                historicalCache,
                invalidHistoricalFrontiers,
              )
            : SpaceAcl(state).allows(
                post.author,
                SpacePermission.publishPosts,
                atMs: post.createdAtMs,
              );
        if (!authorized) {
          break;
        }
        if (post.visibility == SpacePostVisibility.public &&
            bundle.manifest.visibility != SpaceVisibility.public) {
          break;
        }
        final visible = post.isEncrypted
            ? await _materializeEncryptedPost(bundle, post)
            : post;
        if (visible == null) break;
        var semanticValid = true;
        switch (visible.operation) {
          case SpacePostOperation.publish:
            roots[visible.seq] = SpacePostView(
              root: visible,
              effective: visible,
            );
          case SpacePostOperation.edit:
            final target = roots[visible.targetSeq];
            if (target == null || deletedRoots.contains(visible.targetSeq)) {
              semanticValid = false;
              break;
            }
            roots[visible.targetSeq!] = SpacePostView(
              root: target.root,
              effective: visible,
            );
          case SpacePostOperation.delete:
            if (!roots.containsKey(visible.targetSeq) ||
                !deletedRoots.add(visible.targetSeq!)) {
              semanticValid = false;
            }
        }
        if (!semanticValid) break;
      }
      for (final entry in roots.entries) {
        final view = entry.value;
        final pin = state.postPinFor(view.postId);
        final pinned =
            pin?.pinned == true && pin!.rootHash == _spacePostHash(view.root);
        if (deletedRoots.contains(entry.key) ||
            state.isModeratedContentRemoved(
              kind: SpaceModerationReferenceKind.spacePost,
              author: view.root.author,
              seq: view.root.seq,
              atMs: readAt,
            ) ||
            (!pinned &&
                state.isRetentionExpired(
                  createdAtMs: view.root.createdAtMs,
                  atMs: readAt,
                )) ||
            (!pinned && view.root.createdAtMs <= localCutoff)) {
          continue;
        }
        visiblePosts.add(
          view.withPin(pinned: pinned, pinnedAtMs: pin?.changedAtMs),
        );
      }
    }
    visiblePosts.sort((left, right) {
      final time = left.publishedAtMs.compareTo(right.publishedAtMs);
      if (time != 0) return time;
      final author = left.author.hex.compareTo(right.author.hex);
      if (author != 0) return author;
      return left.seq.compareTo(right.seq);
    });
    return visiblePosts;
  }

  String _spaceFeedEnabledKey(NodeId spaceId) =>
      'space.feed.enabled:${spaceId.hex}';
  String _spaceSubscriptionKey(NodeId spaceId) =>
      'space.subscription.v1:${spaceId.hex}';
  String _spaceFeedSeenKey(NodeId spaceId) => 'space.feed.seen:${spaceId.hex}';
  static const String _spaceFeedTypesKey = 'space.feed.types.v1';
  static const String _spaceFeedHiddenStoreKey = 'space.feed.hidden.v1';
  static const int _maxHiddenSpaceFeedPosts = 4096;
  Future<void> _spaceFeedPreferenceMutationTail = Future<void>.value();

  String _hiddenSpaceFeedPostKey(NodeId spaceId, String postId) =>
      '${spaceId.hex}:$postId';

  Future<T> _serializeSpaceFeedPreferences<T>(
    Future<T> Function() action,
  ) async {
    final previous = _spaceFeedPreferenceMutationTail;
    final gate = Completer<void>();
    _spaceFeedPreferenceMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {
        // A prior preference write reports its own failure; keep the queue live.
      }
      return await action();
    } finally {
      gate.complete();
    }
  }

  /// Device-local feed dismissals. They live in the active identity's
  /// encrypted store and never mutate, tombstone, or relay the signed post.
  Future<Map<String, int>> _hiddenSpaceFeedPosts() async {
    final blob = await _storage.loadFile(_spaceFeedHiddenStoreKey);
    if (blob == null || blob.isEmpty) return <String, int>{};
    try {
      final raw = utf8.decode(blob);
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1 || value['items'] is! List) {
        return <String, int>{};
      }
      final result = <String, int>{};
      for (final item in value['items'] as List) {
        if (item is! Map ||
            item['sid'] is! String ||
            item['post'] is! String ||
            item['at'] is! int ||
            item['at'] as int < 0 ||
            !_spacePostIdPattern.hasMatch(item['post'] as String)) {
          continue;
        }
        final NodeId spaceId;
        try {
          spaceId = NodeId.fromHex(item['sid'] as String);
        } catch (_) {
          continue;
        }
        result[_hiddenSpaceFeedPostKey(spaceId, item['post'] as String)] =
            item['at'] as int;
      }
      return result;
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> _saveHiddenSpaceFeedPosts(Map<String, int> hidden) async {
    final entries = hidden.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    final bounded = entries.take(_maxHiddenSpaceFeedPosts);
    final json = jsonEncode({
      'v': 1,
      'items': [
        for (final entry in bounded)
          {
            'sid': entry.key.substring(0, 64),
            'post': entry.key.substring(65),
            'at': entry.value,
          },
      ],
    });
    // The bounded list may still be hundreds of KiB. Use the encrypted
    // chunked store rather than the ~4 KiB single-setting path.
    await _storage.storeFile(
      _spaceFeedHiddenStoreKey,
      Uint8List.fromList(utf8.encode(json)),
      name: 'feed-hidden',
    );
  }

  /// Device-local content types shown in the merged Feed. Selecting every
  /// type (or passing an empty set to the setter) is stored as the compact
  /// default, so newly introduced post types remain visible after upgrades.
  Future<Set<SpacePostType>> spaceFeedTypeFilter() async {
    final all = Set<SpacePostType>.unmodifiable(SpacePostType.values);
    final stored = await _storage.getSetting(_spaceFeedTypesKey);
    if (stored == null || stored.isEmpty) return all;
    try {
      final value = jsonDecode(stored);
      if (value is! Map || value['v'] != 1 || value['types'] is! List) {
        return all;
      }
      final selected = <SpacePostType>{};
      for (final name in value['types'] as List) {
        if (name is! String) return all;
        final type = SpacePostType.fromName(name);
        if (type == null) return all;
        selected.add(type);
      }
      return selected.isEmpty ? all : Set<SpacePostType>.unmodifiable(selected);
    } catch (_) {
      // Corrupt local UI state must never make the user's Feed disappear.
      return all;
    }
  }

  Future<void> setSpaceFeedTypeFilter(Set<SpacePostType> types) =>
      _serializeSpaceFeedPreferences(() async {
        final all = SpacePostType.values.toSet();
        final normalized = types.isEmpty || types.length == all.length
            ? all
            : types.toSet();
        final current = await spaceFeedTypeFilter();
        if (current.length == normalized.length &&
            current.every(normalized.contains)) {
          return;
        }
        final encoded = normalized.length == all.length
            ? ''
            : jsonEncode({
                'v': 1,
                'types': [
                  for (final type in SpacePostType.values)
                    if (normalized.contains(type)) type.name,
                ],
              });
        await _storage.putSetting(_spaceFeedTypesKey, encoded);
        changes.value++;
      });

  Future<bool> isSpaceFeedPostHidden(NodeId spaceId, String postId) async {
    if (!_spacePostIdPattern.hasMatch(postId)) return false;
    return (await _hiddenSpaceFeedPosts()).containsKey(
      _hiddenSpaceFeedPostKey(spaceId, postId),
    );
  }

  /// Hide or restore one publication only in this identity's merged Feed.
  /// The community's own publication history remains intact and visible.
  Future<void> setSpaceFeedPostHidden(
    NodeId spaceId,
    String postId,
    bool hidden,
  ) => _serializeSpaceFeedPreferences(() async {
    if (!_spacePostIdPattern.hasMatch(postId)) {
      throw ArgumentError.value(postId, 'postId', 'invalid Space post id');
    }
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) {
      throw ArgumentError.value(spaceId.hex, 'spaceId', 'unknown Space');
    }
    if (hidden) {
      final visible = await _postsOfBundle(bundle, applyLocalRetention: true);
      if (!visible.any((post) => post.postId == postId)) {
        throw ArgumentError.value(postId, 'postId', 'unknown visible post');
      }
    }
    final values = await _hiddenSpaceFeedPosts();
    final key = _hiddenSpaceFeedPostKey(spaceId, postId);
    final bool changed;
    if (hidden) {
      changed = !values.containsKey(key);
      if (changed) values[key] = _now();
    } else {
      changed = values.remove(key) != null;
    }
    if (!changed) return;
    await _saveHiddenSpaceFeedPosts(values);
    changes.value++;
  });

  /// Membership and feed subscription are intentionally separate. An active
  /// member follows publications by default but can disable them locally
  /// without leaving the Space or mutating its signed control log.
  Future<SpaceSubscription> spaceSubscription(NodeId spaceId) async {
    final stored = await _storage.getSetting(_spaceSubscriptionKey(spaceId));
    if (stored != null && stored.isNotEmpty) {
      try {
        final parsed = SpaceSubscription.fromJson(jsonDecode(stored), spaceId);
        if (parsed != null) return parsed;
      } catch (_) {
        // Corrupt local preferences fail to the privacy-neutral member default.
      }
    }
    // One-version migration from the boolean key introduced by the first feed
    // slice. It is local-only and can be rewritten atomically on next change.
    final legacy = await _storage.getSetting(_spaceFeedEnabledKey(spaceId));
    return SpaceSubscription.memberDefault(
      spaceId,
    ).copyWith(feedEnabled: legacy != '0');
  }

  Future<bool> isSpaceFeedEnabled(NodeId spaceId) async =>
      (await spaceSubscription(spaceId)).feedEnabled;

  Future<void> _saveSpaceSubscription(SpaceSubscription subscription) =>
      _storage.putSetting(
        _spaceSubscriptionKey(subscription.spaceId),
        jsonEncode(subscription.toJson()),
      );

  /// Atomically updates the device-local subscription preferences for one
  /// Space. The three switches share one encrypted record, so every
  /// read-modify-write must use the same queue or concurrent UI/API writes can
  /// silently restore an older sibling field.
  Future<SpaceSubscription> updateSpaceSubscription(
    NodeId spaceId, {
    bool? feedEnabled,
    bool? notificationsEnabled,
    bool? hiddenFromRecommendations,
  }) => _serializeSpaceFeedPreferences(() async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) {
      throw ArgumentError.value(spaceId.hex, 'spaceId', 'unknown Space');
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!state.isMember(_signer.selfId)) {
      throw StateError('Space subscription requires active membership');
    }
    final current = await spaceSubscription(spaceId);
    final next = current.copyWith(
      feedEnabled: feedEnabled,
      notificationsEnabled: notificationsEnabled,
      hiddenFromRecommendations: hiddenFromRecommendations,
      updatedAtMs: _now(),
    );
    final changed =
        current.feedEnabled != next.feedEnabled ||
        current.notificationsEnabled != next.notificationsEnabled ||
        current.hiddenFromRecommendations != next.hiddenFromRecommendations;
    // Retire the one-field legacy preference even when this write is a no-op,
    // otherwise a later recovery from a damaged v1 record could resurrect it.
    await _storage.putSetting(_spaceFeedEnabledKey(spaceId), '');
    if (!changed) return current;
    await _saveSpaceSubscription(next);
    changes.value++;
    return next;
  });

  Future<void> setSpaceFeedEnabled(NodeId spaceId, bool enabled) async {
    await updateSpaceSubscription(spaceId, feedEnabled: enabled);
  }

  Future<void> setSpaceNotificationsEnabled(
    NodeId spaceId,
    bool enabled,
  ) async {
    await updateSpaceSubscription(spaceId, notificationsEnabled: enabled);
  }

  Future<void> setSpaceHiddenFromRecommendations(
    NodeId spaceId,
    bool hidden,
  ) async {
    await updateSpaceSubscription(spaceId, hiddenFromRecommendations: hidden);
  }

  /// Merge subscribed Space logs in descending chronological order. The
  /// signed `(publishedAt, spaceId, author, seq)` tuple is a stable cursor and
  /// the identity set prevents duplicates regardless of roles or sync paths.
  Future<List<SpaceFeedItem>> spaceFeed({
    SpaceFeedCursor? before,
    int limit = 50,
    Set<SpacePostType>? types,
    bool? pinned,
  }) async {
    final boundedLimit = limit.clamp(1, 200);
    final selectedTypes = types ?? await spaceFeedTypeFilter();
    final items = <SpaceFeedItem>[];
    final seen = <String>{};
    final hidden = await _hiddenSpaceFeedPosts();
    for (final id in await _index()) {
      final NodeId spaceId;
      try {
        spaceId = NodeId.fromHex(id);
      } catch (_) {
        continue;
      }
      final bundle = await load(spaceId);
      if (bundle == null ||
          !bundle.manifest.isSpace ||
          !await isSpaceFeedEnabled(spaceId)) {
        continue;
      }
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
      ).state;
      if (!state.isMember(_signer.selfId)) continue;
      final visiblePosts = await _postsOfBundle(
        bundle,
        applyLocalRetention: true,
      );
      final feedPosts = visiblePosts
          .where(
            (post) => !hidden.containsKey(
              _hiddenSpaceFeedPostKey(spaceId, post.postId),
            ),
          )
          .toList();
      final reactions = await _spacePostReactionsOfBundle(
        bundle,
        visiblePostIds: {for (final post in feedPosts) post.postId},
      );
      for (final post in feedPosts) {
        if (!selectedTypes.contains(post.type)) continue;
        if (pinned != null && post.pinned != pinned) continue;
        final cursor = SpaceFeedCursor.fromView(post);
        if (before != null && cursor.compareTo(before) >= 0) continue;
        if (!seen.add('${spaceId.hex}:${post.postId}')) continue;
        items.add(
          SpaceFeedItem(
            spaceId: spaceId,
            spaceName: state.name,
            post: post,
            reactions: reactions[post.postId] ?? const {},
          ),
        );
      }
    }
    items.sort((left, right) {
      final order = SpaceFeedCursor.fromView(
        right.post,
      ).compareTo(SpaceFeedCursor.fromView(left.post));
      return order;
    });
    return items.length <= boundedLimit
        ? items
        : items.sublist(0, boundedLimit);
  }

  Future<int> unreadSpacePosts(NodeId spaceId) async {
    final hidden = await _hiddenSpaceFeedPosts();
    final seen = SpaceFeedCursor.decode(
      await _storage.getSetting(_spaceFeedSeenKey(spaceId)),
    );
    final posts = await postsOf(spaceId);
    return posts
        .where(
          (post) =>
              !hidden.containsKey(
                _hiddenSpaceFeedPostKey(spaceId, post.postId),
              ) &&
              post.author != _signer.selfId &&
              (seen == null ||
                  SpaceFeedCursor.fromView(post).compareTo(seen) > 0),
        )
        .length;
  }

  Future<void> markSpaceFeedSeen(NodeId spaceId) async {
    final posts = await postsOf(spaceId);
    if (posts.isEmpty) return;
    final latest = posts
        .map(SpaceFeedCursor.fromView)
        .reduce((left, right) => left.compareTo(right) >= 0 ? left : right);
    final prior = SpaceFeedCursor.decode(
      await _storage.getSetting(_spaceFeedSeenKey(spaceId)),
    );
    if (prior != null && prior.compareTo(latest) >= 0) return;
    await _storage.putSetting(_spaceFeedSeenKey(spaceId), latest.encode());
    changes.value++;
  }

  // ── Group log gap-fill (reliability brick G1) ─────────────────────────────
  // A delta that dies while EVERY entry node is down is lost for good — the
  // full snapshot only ships on join. Each device therefore sends a compact
  // per-author high-water VECTOR to its deterministic XOR neighbours on boot;
  // a
  // member that holds more replies with ONLY the missing entries. Bandwidth
  // is one small JSON each way when in sync; convergence is eventual (a
  // sampled member that is itself behind just yields nothing this round).

  /// Number of outbound XOR neighbours in the sparse chat-sync overlay.
  static const int kGroupSyncNeighbors = 5;
  static const int kMinGroupSyncNeighbors = 1;
  static const int kMaxGroupSyncNeighbors = 20;

  /// Compatibility name for debug/test callers from before the XOR overlay.
  @Deprecated('Use kGroupSyncNeighbors')
  static const int kGroupSyncFanout = kGroupSyncNeighbors;

  String _groupSyncNeighborsKey(NodeId groupId) =>
      'group.sync.neighbors:${groupId.hex}';

  /// Local outbound overlay degree for one chat. It is deliberately a local
  /// transport preference: each member may choose a different resource /
  /// redundancy trade-off without mutating the signed group policy.
  Future<int> groupSyncNeighborCount(NodeId groupId) async {
    final raw = await _storage.getSetting(_groupSyncNeighborsKey(groupId));
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null ||
        parsed < kMinGroupSyncNeighbors ||
        parsed > kMaxGroupSyncNeighbors) {
      return kGroupSyncNeighbors;
    }
    return parsed;
  }

  Future<void> setGroupSyncNeighborCount(NodeId groupId, int count) async {
    if (count < kMinGroupSyncNeighbors || count > kMaxGroupSyncNeighbors) {
      throw RangeError.range(
        count,
        kMinGroupSyncNeighbors,
        kMaxGroupSyncNeighbors,
        'count',
      );
    }
    await _storage.putSetting(
      _groupSyncNeighborsKey(groupId),
      count == kGroupSyncNeighbors ? '' : '$count',
    );
    changes.value++;
  }

  /// The compact "what I hold" vector for [groupId], or null when unknown.
  Future<Map<String, dynamic>?> buildGroupSyncRequest(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return null;
    final syncState = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (entry) => _validControlFor(b.manifest, entry),
      initialName: b.manifest.name,
      initialDescription: b.manifest.description ?? '',
    ).state;
    final retainedMessages = _retainedMessageRows(b.manifest, b.messages)
        .where(
          (message) =>
              _messageWithinLifecycleBoundary(b.manifest, syncState, message),
        )
        .toList();
    final acceptedMessages = _acceptedMessagesWithinLifecycle(b, syncState);
    final acceptedReactions = _acceptedReactionsWithinLifecycle(b, syncState);
    Map<String, int> vector(Iterable<(NodeId, int)> entries) {
      final v = <String, int>{};
      for (final (a, s) in entries) {
        // Seqs start at 0 (_nextSeq), so the floor is -1 — with a 0 floor an
        // author whose ONLY entry is seq 0 was absent from the vector and the
        // responder (old default 0) never shipped seq-0 entries at all: the
        // FIRST lost entry of any author was unrecoverable (latent G1 bug,
        // caught by the reaction remainder).
        if (s > (v[a.hex] ?? -1)) v[a.hex] = s;
      }
      return v;
    }

    Map<String, Object> messageVector(Iterable<GroupMessage> messages) {
      final rows = messages.toList(growable: false);
      final result = <String, Object>{};
      final forks = _messageForks(b.manifest, rows);
      final authors = <String, NodeId>{
        for (final message in rows) message.author.hex: message.author,
      };
      for (final author in authors.values) {
        final authored = rows.where((message) => message.author == author);
        if (authored.isEmpty) continue;
        final scope = _messageChainScope(b.manifest, authored.first);
        final chain = _acceptedMessageChain(b.manifest, rows, author, scope);
        final fork = forks['$scope|${author.hex}'];
        final value = <String, Object>{
          's': chain.isEmpty ? -1 : chain.last.seq,
          if (chain.isNotEmpty) 'h': groupMessageHash(chain.last),
          if (fork != null)
            'f': {'s': fork.seq, 'h': fork.hashes.toList()..sort()},
        };
        result[author.hex] = value;
      }
      return result;
    }

    Map<String, Object> postVector() {
      final byAuthor = <String, List<SpacePost>>{};
      for (final post in _canonicalPostRows(groupId, b.posts).where(
        (post) =>
            !post.isLifecycleScoped &&
            _postWithinLifecycleBoundary(syncState, post),
      )) {
        byAuthor.putIfAbsent(post.author.hex, () => []).add(post);
      }
      final result = <String, Object>{};
      for (final entry in byAuthor.entries) {
        final authored = entry.value
          ..sort((left, right) => left.seq.compareTo(right.seq));
        var expectedSeq = 0;
        var expectedPrev = '';
        for (final post in authored) {
          if (post.seq != expectedSeq || post.prevHash != expectedPrev) break;
          result[entry.key] = {'s': post.seq, 'h': _spacePostHash(post)};
          expectedSeq++;
          expectedPrev = _spacePostHash(post);
        }
      }
      return result;
    }

    Map<String, Object> postGenerationVector() {
      final result = <String, Object>{};
      final generations = <String, Map<String, NodeId>>{};
      for (final post in _canonicalPostRows(groupId, b.posts)) {
        if (!post.isLifecycleScoped ||
            !_postWithinLifecycleBoundary(syncState, post)) {
          continue;
        }
        generations.putIfAbsent(
          _postGeneration(post),
          () => <String, NodeId>{},
        )[post.author.hex] = post.author;
      }
      for (final generation in generations.entries) {
        final vector = <String, Object>{};
        for (final author in generation.value.values) {
          final chain = _acceptedPostChain(
            groupId,
            b.posts,
            author,
            generationHash: generation.key,
          );
          if (chain.isNotEmpty) {
            vector[author.hex] = {
              's': chain.last.seq,
              'h': _spacePostHash(chain.last),
            };
          }
        }
        result[generation.key] = vector;
      }
      return result;
    }

    Map<String, Object> controlVector() {
      final result = <String, Object>{};
      for (final entry in _acceptedControl(b.manifest, b.control)) {
        final current = result[entry.author.hex];
        final currentSeq = current is Map && current['s'] is int
            ? current['s'] as int
            : -1;
        if (entry.seq > currentSeq) {
          result[entry.author.hex] = {
            's': entry.seq,
            'h': controlEntryHash(entry),
          };
        }
      }
      return result;
    }

    Map<String, Object> channelMessageVector() {
      final result = <String, Object>{};
      final byChannel = <String, List<GroupMessage>>{};
      for (final message in retainedMessages) {
        if (message.isChannelEncrypted) {
          byChannel
              .putIfAbsent(
                _messageChainScope(b.manifest, message),
                () => <GroupMessage>[],
              )
              .add(message);
        }
      }
      for (final entry in byChannel.entries) {
        result[entry.key] = messageVector(entry.value);
      }
      return result;
    }

    Map<String, Object> openChannelMessageVector() {
      final result = <String, Object>{};
      final byChannel = <String, List<GroupMessage>>{};
      for (final message in retainedMessages) {
        if (message.isChannelEncrypted) continue;
        final scope = _messageChainScope(b.manifest, message);
        byChannel.putIfAbsent(scope, () => <GroupMessage>[]).add(message);
      }
      for (final entry in byChannel.entries) {
        result[entry.key] = messageVector(entry.value);
      }
      return result;
    }

    Map<String, Object> groupMessageScopeVector() {
      final result = <String, Object>{};
      final byScope = <String, List<GroupMessage>>{};
      for (final message in retainedMessages) {
        final scope = _messageChainScope(b.manifest, message);
        byScope.putIfAbsent(scope, () => <GroupMessage>[]).add(message);
      }
      for (final entry in byScope.entries) {
        result[entry.key] = messageVector(entry.value);
      }
      return result;
    }

    return {
      'sreq': 1,
      'gid': groupId.hex,
      // Legacy Space peers still consume the flat high-water vector. New
      // peers use `mg`, scoped by visible channel, so alternating between
      // channels cannot skip a lower-seq missing row.
      'g': vector(
        acceptedMessages
            .where((message) => !message.isChannelEncrypted)
            .map((message) => (message.author, message.seq)),
      ),
      if (!b.manifest.isSpace && !b.manifest.isSovereignDevice)
        'ms': groupMessageScopeVector(),
      if (b.manifest.isSpace) 'mg': openChannelMessageVector(),
      if (b.manifest.isSpace) 'cg': channelMessageVector(),
      // V2 adds the accepted head hash. A legacy peer treats the object value
      // as unseen and safely over-ships; a new peer detects same-seq forks
      // instead of declaring two different heads "in sync".
      'c': controlVector(),
      // Reactions ride the same per-author high-water scheme (each author's
      // reaction seq is monotonic). An older responder just ignores the key.
      'r': vector(acceptedReactions.map((r) => (r.author, r.seq))),
      if (b.manifest.isSpace) 'p': postVector(),
      if (b.manifest.isSpace) 'pg': postGenerationVector(),
      if (b.localEpochKeys.isNotEmpty)
        'ke': (b.localEpochKeys.keys.toList()..sort()),
      if (b.localChannelEpochKeys.isNotEmpty)
        'cke': (b.localChannelEpochKeys.keys.toList()..sort()),
    };
  }

  /// Answer a member's sync vector: ship ONLY the entries [peer] lacks (their
  /// vector's high-water per author, unseen author = everything). Non-members
  /// are dropped silently — no membership oracle. Returns whether a reply
  /// delta was sent.
  Future<bool> handleGroupSyncRequest(NodeId peer, Map req) async {
    final send = _send;
    if (send == null) return false;
    final gidHex = req['gid'];
    if (gidHex is! String || !(await _index()).contains(gidHex)) return false;
    final NodeId gid;
    try {
      gid = NodeId.fromHex(gidHex);
    } catch (_) {
      return false;
    }
    final b = await load(gid);
    if (b == null) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final retainedMessages = _retainedMessageRows(b.manifest, b.messages)
        .where(
          (message) =>
              _messageWithinLifecycleBoundary(b.manifest, state, message),
        )
        .toList();
    final localMessageForks = _messageForks(b.manifest, retainedMessages);
    if (!SpaceAcl(state).allows(peer, SpacePermission.distributeContent)) {
      devLog(() => 'xVeil[groups]: sync request from non-member — drop');
      return false;
    }
    // -1, not 0: seqs start at 0, so "never seen this author" must sit BELOW
    // the first seq or seq-0 entries can never gap-fill (see [vector]).
    int seen(Object? vec, NodeId author) {
      if (vec is! Map) return -1;
      final value = vec[author.hex];
      if (value is int) return value;
      if (value is Map && value['s'] is int) return value['s'] as int;
      return -1;
    }

    String? seenRowHash(Object? vec, NodeId author) {
      if (vec is! Map) return null;
      final value = vec[author.hex];
      return value is Map && value['h'] is String ? value['h'] as String : null;
    }

    bool hasRowHash(Object? vec, NodeId author) =>
        vec is Map &&
        vec[author.hex] is Map &&
        (vec[author.hex] as Map)['h'] is String;
    Set<String> knownForkHashes(Object? vec, NodeId author, int seq) {
      if (vec is! Map || vec[author.hex] is! Map) return const {};
      final fork = (vec[author.hex] as Map)['f'];
      if (fork is! Map || fork['s'] != seq || fork['h'] is! List) {
        return const {};
      }
      return (fork['h'] as List).whereType<String>().toSet();
    }

    String? seenControlHash(Object? vec, NodeId author) =>
        seenRowHash(vec, author);
    bool hasControlHash(Object? vec, NodeId author) => hasRowHash(vec, author);
    String? seenPostHash(Object? vec, NodeId author) =>
        seenRowHash(vec, author);
    bool hasPostHash(Object? vec, NodeId author) => hasRowHash(vec, author);
    Object? postVectorFor(SpacePost post) {
      if (!post.isLifecycleScoped) return req['p'];
      final generations = req['pg'];
      return generations is Map ? generations[_postGeneration(post)] : null;
    }

    final heldEpochs = req['ke'] is List
        ? (req['ke'] as List).whereType<int>().toSet()
        : const <int>{};
    final heldChannelEpochs = req['cke'] is List
        ? (req['cke'] as List).whereType<String>().toSet()
        : const <String>{};
    final missingEpochEnvelopes = [
      for (final envelope in _epochEnvelopesFor(b, peer))
        if (!heldEpochs.contains(envelope.epoch)) envelope,
    ];
    final missingChannelEpochEnvelopes = [
      for (final envelope in _channelEpochEnvelopesFor(b, peer))
        if (!heldChannelEpochs.contains(
          _channelKeyId(envelope.groupId, envelope.epoch),
        ))
          envelope,
    ];
    Object? messageVectorFor(GroupMessage message) {
      if (message.isChannelEncrypted) {
        final channels = req['cg'];
        if (channels is! Map) return null;
        return channels[_messageChainScope(b.manifest, message)] ??
            channels[message.channelId!.hex];
      }
      if (b.manifest.isSpace) {
        return req['mg'] is Map
            ? (req['mg'] as Map)[_messageChainScope(b.manifest, message)]
            : null;
      }
      if (!b.manifest.isSovereignDevice) {
        return req['ms'] is Map
            ? (req['ms'] as Map)[_messageChainScope(b.manifest, message)]
            : null;
      }
      return req['g'];
    }

    bool peerNeedsMessage(GroupMessage message) {
      if (!_validMessageFor(gid, message)) return false;
      final messageVector = messageVectorFor(message);
      final peerSeq = seen(messageVector, message.author);
      final scope = _messageChainScope(b.manifest, message);
      final fork = localMessageForks['$scope|${message.author.hex}'];
      final knownFork = fork == null
          ? const <String>{}
          : knownForkHashes(messageVector, message.author, fork.seq);
      bool missing;
      if (fork != null && message.seq >= fork.seq) {
        if (knownFork.containsAll(fork.hashes)) return false;
        // The conflicting rows themselves are sufficient evidence to
        // quarantine the suffix. Do not waste bandwidth shipping a suffix
        // that neither side may materialize until the fork is resolved by a
        // future explicit protocol.
        if (message.seq > fork.seq) return false;
        missing = !knownFork.contains(groupMessageHash(message));
      } else {
        missing =
            message.seq > peerSeq ||
            (message.seq == peerSeq &&
                hasRowHash(messageVector, message.author) &&
                seenRowHash(messageVector, message.author) !=
                    groupMessageHash(message));
      }
      if (!missing) return false;
      if (message.isChannelEncrypted) {
        return _peerCanDecryptChannelEpoch(
          b,
          peer,
          message.channelId!,
          message.channelEpoch!,
        );
      }
      return !_encryptionEstablished(b.manifest, b.control) ||
          (message.isEncrypted &&
              _peerCanDecryptEpoch(b, peer, message.membershipEpoch!));
    }

    final missingMsgs = [
      for (final message in retainedMessages)
        if (peerNeedsMessage(message)) message,
    ];
    final missingCtl = [
      for (final e in b.control)
        if (_validControlFor(b.manifest, e) &&
            (e.seq > seen(req['c'], e.author) ||
                (e.seq == seen(req['c'], e.author) &&
                    hasControlHash(req['c'], e.author) &&
                    seenControlHash(req['c'], e.author) !=
                        controlEntryHash(e))))
          e,
    ];
    // A requester from before the 'r' vector sends none — `seen` reads 0 and
    // every held reaction ships; the ingest dedup by (author, seq) makes the
    // over-send harmless.
    final missingRx = [
      for (final r in _acceptedReactionsWithinLifecycle(b, state))
        if (_validReactionFor(gid, r) &&
            r.seq > seen(req['r'], r.author) &&
            (!_encryptionEstablished(b.manifest, b.control) ||
                (r.isEncrypted &&
                    _peerCanDecryptEpoch(b, peer, r.membershipEpoch!))))
          r,
    ];
    final missingPosts = [
      for (final post in _retainedPostRows(gid, b.posts))
        if (_validPostFor(gid, post) &&
            _postWithinLifecycleBoundary(state, post) &&
            (post.seq > seen(postVectorFor(post), post.author) ||
                (post.seq == seen(postVectorFor(post), post.author) &&
                    hasPostHash(postVectorFor(post), post.author) &&
                    seenPostHash(postVectorFor(post), post.author) !=
                        _spacePostHash(post))) &&
            (!post.isEncrypted ||
                _peerCanDecryptEpoch(b, peer, post.membershipEpoch!)))
          post,
    ];
    if (missingMsgs.isEmpty &&
        missingCtl.isEmpty &&
        missingRx.isEmpty &&
        missingPosts.isEmpty &&
        missingEpochEnvelopes.isEmpty &&
        missingChannelEpochEnvelopes.isEmpty) {
      return false;
    }
    final overlayId =
        b.manifest.name != kDeviceGroupName &&
            missingCtl.isEmpty &&
            (missingMsgs.isNotEmpty ||
                missingRx.isNotEmpty ||
                missingPosts.isNotEmpty)
        ? _overlayDeltaId(gid, missingMsgs, missingRx, missingPosts)
        : null;
    if (overlayId != null) _rememberOverlayDelta(overlayId);
    await send(
      peer,
      gid,
      jsonEncode({
        'm': b.manifest.toJson(),
        'c': [for (final e in missingCtl) e.toJson()],
        'g': [for (final m in missingMsgs) m.toJson()],
        'r': [for (final r in missingRx) r.toJson()],
        if (missingPosts.isNotEmpty)
          'p': [for (final post in missingPosts) post.toJson()],
        if (missingEpochEnvelopes.isNotEmpty)
          'ke': [
            for (final envelope in missingEpochEnvelopes) envelope.toJson(),
          ],
        if (missingChannelEpochEnvelopes.isNotEmpty)
          'cke': [
            for (final envelope in missingChannelEpochEnvelopes)
              envelope.toJson(),
          ],
        'ov': ?overlayId,
      }),
    );
    return true;
  }

  /// Route one inbound group-entry payload from [peer]: a sync VECTOR is
  /// answered (membership-gated), anything else is the normal idempotent
  /// snapshot/delta ingest. The wire wiring points here instead of calling
  /// [ingestSnapshot] directly.
  Future<bool> ingestGroupEntry(NodeId peer, String json) async {
    Map? decoded;
    try {
      final d = jsonDecode(json);
      if (d is Map && d['sreq'] == 1) return handleGroupSyncRequest(peer, d);
      if (d is Map) decoded = d;
    } catch (_) {
      return false; // malformed — drop
    }
    final pending = await _tryPendingDeviceSnapshot(peer, json);
    if (pending != null) return pending;
    PendingSpaceInvite? acceptedInvite;
    SpaceJoinOutboxEntry? acceptedJoinRequest;
    final manifest = GroupManifest.fromJson(decoded?['m']);
    if (manifest != null &&
        manifest.isSpace &&
        await load(manifest.groupId) == null) {
      acceptedInvite = await _acceptedSpaceInviteFor(peer, manifest, decoded!);
      acceptedJoinRequest = await _acceptedSpaceJoinRequestFor(
        peer,
        manifest,
        decoded,
      );
      if (acceptedInvite == null && acceptedJoinRequest == null) {
        devLog(
          () =>
              'xVeil[spaces]: unsolicited materialization DENIED — consent '
              'required',
        );
        return false;
      }
    }
    final accepted = await ingestSnapshot(json);
    if (accepted && acceptedInvite != null) {
      await _consumeAcceptedSpaceInvite(acceptedInvite.invite.inviteId);
    }
    if (accepted && decoded != null) {
      await _relayOverlayDelta(peer, decoded);
    }
    return accepted;
  }

  Future<SpaceJoinOutboxEntry?> _acceptedSpaceJoinRequestFor(
    NodeId peer,
    SpaceManifest manifest,
    Map wire,
  ) async {
    if (manifest.visibility != SpaceVisibility.public) return null;
    SpaceJoinOutboxEntry? pending;
    for (final candidate in (await _loadSpaceJoins()).outgoing) {
      if (!candidate.declined &&
          candidate.request.spaceId == manifest.spaceId &&
          candidate.request.approver == peer &&
          candidate.request.requester == selfId) {
        pending = candidate;
        break;
      }
    }
    if (pending == null) return null;
    final control = (wire['c'] as List? ?? const [])
        .map(ControlEntry.fromJson)
        .whereType<ControlEntry>()
        .where((entry) => _validControlFor(manifest, entry))
        .toList();
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
      initialDescription: manifest.description ?? '',
    );
    final grantAccepted = folded.accepted.any(
      (entry) =>
          entry.op == ControlOp.addMember &&
          entry.author == peer &&
          entry.target == selfId &&
          (entry.role ?? GroupRole.member) == GroupRole.member &&
          entry.createdAtMs >= pending!.request.createdAtMs &&
          entry.createdAtMs <= pending.ticket.expiresAtMs,
    );
    if (!grantAccepted ||
        !folded.state.isMember(selfId) ||
        !folded.state.isMember(peer)) {
      return null;
    }
    return pending;
  }

  Future<PendingSpaceInvite?> _acceptedSpaceInviteFor(
    NodeId peer,
    SpaceManifest manifest,
    Map wire,
  ) async {
    PendingSpaceInvite? pending;
    for (final candidate in await pendingSpaceInvites()) {
      if (candidate.accepted &&
          candidate.invite.spaceId == manifest.spaceId &&
          candidate.invite.inviter == peer &&
          candidate.invite.invitee == selfId) {
        pending = candidate;
      }
    }
    if (pending == null) return null;
    final control = (wire['c'] as List? ?? const [])
        .map(ControlEntry.fromJson)
        .whereType<ControlEntry>()
        .where((entry) => _validControlFor(manifest, entry))
        .toList();
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
    );
    final grantAccepted = folded.accepted.any(
      (entry) =>
          entry.op == ControlOp.addMember &&
          entry.author == peer &&
          entry.target == selfId &&
          (entry.role ?? GroupRole.member) == pending!.invite.role,
    );
    if (!grantAccepted ||
        !folded.state.isMember(selfId) ||
        !folded.state.isMember(peer)) {
      return null;
    }
    return pending;
  }

  Future<void> _consumeAcceptedSpaceInvite(String inviteId) =>
      _serializeSpaceInvites(() async {
        final store = await _loadSpaceInvites();
        await _saveSpaceInvites(
          incoming: [
            for (final entry in store.incoming)
              if (entry.invite.inviteId != inviteId) entry,
          ],
          outgoing: store.outgoing,
        );
        changes.value++;
      });

  /// The NON-contact variant of [ingestGroupEntry]: a member's sync vector is
  /// answered (the handler's own membership gate is the same admission), a
  /// bundle goes through the stranger-guarded ingest.
  Future<bool> ingestGroupEntryFromStranger(NodeId peer, String json) async {
    Map? decoded;
    try {
      final d = jsonDecode(json);
      if (d is Map && d['sreq'] == 1) return handleGroupSyncRequest(peer, d);
      if (d is Map) decoded = d;
    } catch (_) {
      return false; // malformed — drop
    }
    SpaceJoinOutboxEntry? acceptedJoinRequest;
    final manifest = GroupManifest.fromJson(decoded?['m']);
    if (manifest != null &&
        manifest.isSpace &&
        await load(manifest.groupId) == null) {
      acceptedJoinRequest = await _acceptedSpaceJoinRequestFor(
        peer,
        manifest,
        decoded!,
      );
    }
    final accepted = acceptedJoinRequest == null
        ? await ingestSnapshotFromStranger(peer, json)
        : await ingestSnapshot(json);
    if (accepted && decoded != null) {
      await _relayOverlayDelta(peer, decoded);
    }
    return accepted;
  }

  Future<void> _relayOverlayDelta(NodeId source, Map wire) async {
    final overlayId = wire['ov'];
    if (overlayId is! String || overlayId.length != 64) return;
    final manifest = GroupManifest.fromJson(wire['m']);
    if (manifest == null ||
        wire['c'] is! List ||
        (wire['c'] as List).isNotEmpty) {
      return;
    }
    final messages = (wire['g'] as List? ?? const [])
        .map(GroupMessage.fromJson)
        .whereType<GroupMessage>()
        .toList();
    final reactions = (wire['r'] as List? ?? const [])
        .map(GroupReaction.fromJson)
        .whereType<GroupReaction>()
        .toList();
    final posts = (wire['p'] as List? ?? const [])
        .map(SpacePost.fromJson)
        .whereType<SpacePost>()
        .toList();
    if (messages.isEmpty && reactions.isEmpty && posts.isEmpty) return;
    if (_overlayDeltaId(manifest.groupId, messages, reactions, posts) !=
        overlayId) {
      return;
    }
    // Relay the validated rows we actually persisted, never attacker-supplied
    // lookalikes that merely reuse a legitimate (author, seq) identity.
    final stored = await load(manifest.groupId);
    if (stored == null) return;
    GroupMessage? storedMessage(GroupMessage incoming) {
      for (final candidate in stored.messages) {
        if (candidate.author == incoming.author &&
            candidate.seq == incoming.seq &&
            jsonEncode(candidate.toJson()) == jsonEncode(incoming.toJson())) {
          return candidate;
        }
      }
      return null;
    }

    GroupReaction? storedReaction(GroupReaction incoming) {
      for (final candidate in stored.reactions) {
        if (candidate.author == incoming.author &&
            candidate.seq == incoming.seq &&
            jsonEncode(candidate.toJson()) == jsonEncode(incoming.toJson())) {
          return candidate;
        }
      }
      return null;
    }

    SpacePost? storedPost(SpacePost incoming) {
      for (final candidate in stored.posts) {
        if (candidate.author == incoming.author &&
            candidate.seq == incoming.seq &&
            jsonEncode(candidate.toJson()) == jsonEncode(incoming.toJson())) {
          return candidate;
        }
      }
      return null;
    }

    final validMessages = messages
        .map(storedMessage)
        .whereType<GroupMessage>()
        .toList();
    final validReactions = reactions
        .map(storedReaction)
        .whereType<GroupReaction>()
        .toList();
    final validPosts = posts.map(storedPost).whereType<SpacePost>().toList();
    if (validMessages.length != messages.length ||
        validReactions.length != reactions.length ||
        validPosts.length != posts.length ||
        !_rememberOverlayDelta(overlayId)) {
      return;
    }
    await broadcastDelta(
      manifest.groupId,
      messages: validMessages,
      reactions: validReactions,
      posts: validPosts,
      exclude: {source},
      overlayId: overlayId,
    );
  }

  /// Boot catch-up for EVERY group. Chat groups use the same deterministic
  /// XOR neighbours as live deltas; device groups retain all-device delivery.
  /// Cheap when in sync (one small JSON), and the reply path ships only what
  /// this device actually lacks.
  Future<void> nudgeGroupSyncAll() async {
    for (final gidHex in await _index()) {
      final NodeId gid;
      try {
        gid = NodeId.fromHex(gidHex);
      } catch (_) {
        continue;
      }
      final beforeUpgrade = await load(gid);
      final beforeState = beforeUpgrade == null
          ? null
          : foldControlLog(
              owner: beforeUpgrade.manifest.owner,
              entries: beforeUpgrade.control,
              verify: (entry) =>
                  _validControlFor(beforeUpgrade.manifest, entry),
              initialName: beforeUpgrade.manifest.name,
            ).state;
      if (_epochService != null &&
          beforeUpgrade != null &&
          beforeUpgrade.manifest.name != kDeviceGroupName &&
          beforeUpgrade.manifest.owner == _signer.selfId &&
          beforeState != null &&
          !_encryptionEstablished(
            beforeUpgrade.manifest,
            beforeUpgrade.control,
          )) {
        // One-time migration for legacy groups: the genesis owner establishes
        // the first signed epoch and fans its recipient envelopes on boot.
        await addControlOp(gid, ControlOp.rotateEpoch);
      }
      await compactStateLogs(gid);
      await nudgeGroupSync(gid);
    }
  }

  /// Starts one compact anti-entropy exchange with this chat's current XOR
  /// neighbours. Used at boot and immediately after changing the local `k`.
  Future<int> nudgeGroupSync(NodeId groupId) async {
    final send = _send;
    if (send == null) return 0;
    final bundle = await load(groupId);
    final req = await buildGroupSyncRequest(groupId);
    final state = await stateOf(groupId);
    if (bundle == null || req == null || state == null) return 0;
    final others = <NodeId>[
      for (final member in state.members.values)
        if (member.nodeId != _signer.selfId &&
            (!bundle.manifest.isSovereignDevice ||
                member.nodeId != bundle.manifest.owner))
          member.nodeId,
    ];
    final basePeers = bundle.manifest.name == kDeviceGroupName
        ? others
        : nearestGroupNodesByXor(
            _signer.selfId,
            others,
            k: await groupSyncNeighborCount(groupId),
          );
    final peersById = <String, NodeId>{
      for (final peer in basePeers) peer.hex: peer,
    };
    if (bundle.manifest.isSpace) {
      final protected = await _protectedChannelsOf(bundle, state);
      final k = await groupSyncNeighborCount(groupId);
      for (final clear in protected.values) {
        for (final peer in nearestGroupNodesByXor(
          _signer.selfId,
          clear.recipients,
          k: k,
        )) {
          peersById[peer.hex] = peer;
        }
      }
    }
    final peers = peersById.values.toList()
      ..sort((left, right) => left.hex.compareTo(right.hex));
    for (final peer in peers) {
      await send(peer, groupId, jsonEncode(req));
    }
    return peers.length;
  }

  /// The VALIDATED, time-ordered messages of [groupId]: signature ok AND the
  /// author is a non-muted member of the current state. (A finer per-message
  /// membership-at-its-policy-version check is a later refinement.)
  Future<List<GroupMessage>> messagesOf(
    NodeId groupId, {
    NodeId? channelId,
    bool applyLocalRetention = true,
  }) async {
    final b = await load(groupId);
    if (b == null) return const [];
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final readAt = DateTime.now().millisecondsSinceEpoch;
    final reader = state.memberOf(_signer.selfId);
    if (b.manifest.isSpace && (reader == null || state.isDeleted)) {
      return const [];
    }
    final localCutoff = b.manifest.isSpace && applyLocalRetention
        ? await _localSpaceRetentionCutoff(groupId, readAt)
        : -1;
    final protected = b.manifest.isSpace
        ? await _protectedChannelsOf(b, state)
        : const <String, SpaceChannelControlCleartext>{};
    final out = <GroupMessage>[];
    for (final m in _acceptedMessagesWithinLifecycle(b, state)) {
      final effectiveChannelId = b.manifest.isSpace
          ? m.channelId ?? defaultSpaceChannelId(groupId)
          : null;
      if (b.manifest.isSpace) {
        final effectiveChannel = effectiveChannelId!;
        final protectedChannel = protected[effectiveChannel.hex];
        final channel =
            state.channels[effectiveChannel.hex] ?? protectedChannel?.channel;
        if (channel == null ||
            (channelId != null && effectiveChannel != channelId)) {
          continue;
        }
        if ((protectedChannel != null && !m.isChannelEncrypted) ||
            (protectedChannel == null && m.isChannelEncrypted)) {
          continue;
        }
        final historyAllows = switch (channel.history) {
          // Equal wall-clock milliseconds are causally ambiguous across
          // authors. Exclude them: history access is fail-closed.
          SpaceChannelHistory.fromJoin => m.createdAtMs > reader!.joinedAtMs,
          SpaceChannelHistory.since => m.createdAtMs >= channel.historySinceMs!,
          SpaceChannelHistory.full => true,
        };
        if (!historyAllows) continue;
        if (state.isRetentionExpired(
              createdAtMs: m.createdAtMs,
              atMs: readAt,
              channelId: effectiveChannel,
            ) ||
            m.createdAtMs <= localCutoff) {
          continue;
        }
      } else if (channelId != null) {
        continue;
      }
      if (!SpaceAcl(state).allows(
            m.author,
            SpacePermission.publishMessages,
            atMs: m.createdAtMs,
            channelId: effectiveChannelId,
          ) ||
          (b.manifest.isSpace &&
              state.isModeratedContentRemoved(
                kind: SpaceModerationReferenceKind.message,
                author: m.author,
                seq: m.seq,
                atMs: readAt,
                channelId: effectiveChannelId,
              ))) {
        continue;
      }
      if (!m.isEncrypted) {
        out.add(m);
        continue;
      }
      final materialized = await _materializeEncryptedMessage(b, m);
      if (materialized != null) out.add(materialized);
    }
    out.sort((a, b) {
      final t = a.createdAtMs.compareTo(b.createdAtMs);
      if (t != 0) return t;
      final h = a.author.hex.compareTo(b.author.hex);
      if (h != 0) return h;
      return a.seq.compareTo(b.seq);
    });
    return out;
  }

  /// Toggle our reaction [emoji] on [msgRef] (`<authorHex>:<seq>`):
  /// reacting with the emoji we already have removes it. Rejected (false) if we
  /// are not a non-muted member. The signed reaction is delta-broadcast.
  /// [broadcast]=false stores the signed reaction WITHOUT the delta fanout —
  /// the deterministic "lost reaction" for gap-fill tests (like
  /// [postMessage]'s flag).
  Future<bool> react(
    NodeId groupId,
    String msgRef,
    String emoji, {
    bool broadcast = true,
  }) => _serialized(
    groupId,
    () => _react(
      groupId,
      msgRef,
      emoji,
      targetKind: ReactionTargetKind.message,
      broadcast: broadcast,
    ),
  );

  /// Toggle a reaction on an effective Space publication root. Revisions keep
  /// the same [postId], while a tombstone makes the target unavailable.
  Future<bool> reactToSpacePost(
    NodeId spaceId,
    String postId,
    String emoji, {
    bool broadcast = true,
  }) => _serialized(
    spaceId,
    () => _react(
      spaceId,
      postId,
      emoji,
      targetKind: ReactionTargetKind.spacePost,
      broadcast: broadcast,
    ),
  );

  Future<bool> _react(
    NodeId groupId,
    String target,
    String emoji, {
    required ReactionTargetKind targetKind,
    bool broadcast = true,
  }) async {
    final b = await load(groupId);
    if (b == null) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    if (b.manifest.isSpace && state.isDeleted) return false;
    if (!SpaceAcl(
      state,
    ).allows(_signer.selfId, SpacePermission.publishMessages)) {
      return false;
    }
    if (utf8.encode(emoji).length > 64) return false;
    if (targetKind == ReactionTargetKind.message &&
        !(await messagesOf(groupId)).any(
          (message) => message.ref == target && !message.isChannelEncrypted,
        )) {
      // Reactions still use the Space epoch and would reveal the hidden
      // message reference to every Space member. Unknown and protected-channel
      // targets are therefore rejected.
      return false;
    }
    if (targetKind == ReactionTargetKind.spacePost &&
        (!b.manifest.isSpace ||
            !(await postsOf(groupId)).any((post) => post.postId == target))) {
      return false;
    }
    // My current reaction on this message (if any) → tapping it again clears it.
    final visibleReactions = <GroupReaction>[];
    for (final reaction in _acceptedReactionsWithinLifecycle(b, state)) {
      if (!SpaceAcl(state).allows(
        reaction.author,
        SpacePermission.publishMessages,
        atMs: reaction.createdAtMs,
      )) {
        continue;
      }
      final materialized = await _materializeEncryptedReaction(b, reaction);
      if (materialized != null) visibleReactions.add(materialized);
    }
    final onTarget =
        foldReactionsByKind(
          visibleReactions,
          _signer.verifyReaction,
          targetKind,
        )[target] ??
        const <String, List<NodeId>>{};
    String? mine;
    for (final e in onTarget.entries) {
      if (e.value.any((n) => n == _signer.selfId)) {
        mine = e.key;
        break;
      }
    }
    final next = (mine == emoji) ? '' : emoji;
    final mySeq = _nextSeq(
      b.reactions
          .where(
            (r) =>
                r.author == _signer.selfId &&
                _validReactionFor(b.manifest.groupId, r),
          )
          .map((r) => r.seq),
    );
    final descriptor = state.epochDescriptor;
    final encryptionEstablished = _encryptionEstablished(b.manifest, b.control);
    final key = descriptor == null ? null : b.localEpochKeys[state.epoch];
    if (encryptionEstablished &&
        (descriptor == null ||
            key == null ||
            !_validLocalEpochKey(b.manifest, b.control, state.epoch, key))) {
      return false;
    }
    final createdAt = _now();
    final lifecycleGeneration = b.manifest.isSpace
        ? state.lifecycleTransitionHash
        : null;
    late final GroupReaction unsigned;
    if (descriptor != null && key != null) {
      final clear = GroupReactionCleartext(
        target: target,
        emoji: next,
        targetKind: targetKind,
        schemaVersion: 2,
      ).encode();
      try {
        final encrypted = await encryptGroupReactionPayload(
          groupId: groupId,
          membershipEpoch: state.epoch,
          author: _signer.selfId,
          seq: mySeq,
          createdAtMs: createdAt,
          clearText: clear,
          epochKey: key,
          reactionVersion: lifecycleGeneration == null ? 4 : 6,
          lifecycleGeneration: lifecycleGeneration ?? '',
        );
        unsigned = GroupReaction(
          groupId: groupId,
          author: _signer.selfId,
          seq: mySeq,
          target: '',
          emoji: '',
          version: lifecycleGeneration == null ? 4 : 6,
          membershipEpoch: state.epoch,
          encryptedPayload: encrypted,
          lifecycleGeneration: lifecycleGeneration,
          createdAtMs: createdAt,
          signature: Uint8List(0),
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } else {
      unsigned = GroupReaction(
        groupId: groupId,
        author: _signer.selfId,
        seq: mySeq,
        target: target,
        emoji: next,
        version: lifecycleGeneration == null ? 3 : 5,
        targetKind: targetKind,
        lifecycleGeneration: lifecycleGeneration,
        createdAtMs: createdAt,
        signature: Uint8List(0),
      );
    }
    final signed = _signer.signReaction(unsigned);
    await _save(b.copyWith(reactions: [...b.reactions, signed]));
    if (broadcast) unawaited(broadcastDelta(groupId, reactions: [signed]));
    return true;
  }

  /// The folded reactions of [groupId]: `messageRef -> emoji -> reactors`.
  Future<Map<String, MessageReactions>> reactionsOf(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return const {};
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    if (b.manifest.isSpace && state.isDeleted) return const {};
    final materialized = <GroupReaction>[];
    for (final reaction in b.reactions) {
      if (!_validReactionFor(groupId, reaction) ||
          !SpaceAcl(state).allows(
            reaction.author,
            SpacePermission.publishMessages,
            atMs: reaction.createdAtMs,
          )) {
        continue;
      }
      final visible = await _materializeEncryptedReaction(b, reaction);
      if (visible != null) materialized.add(visible);
    }
    return foldGroupReactions(materialized, _signer.verifyReaction);
  }

  /// The folded reactions of visible, non-deleted Space publication roots.
  Future<Map<String, MessageReactions>> spacePostReactionsOf(
    NodeId spaceId,
  ) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const {};
    return _spacePostReactionsOfBundle(bundle);
  }

  Future<Map<String, MessageReactions>> _spacePostReactionsOfBundle(
    GroupBundle bundle, {
    Set<String>? visiblePostIds,
  }) async {
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
    ).state;
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.view)) {
      return const {};
    }
    final allowedPostIds =
        visiblePostIds ??
        {for (final post in await _postsOfBundle(bundle)) post.postId};
    final materialized = <GroupReaction>[];
    for (final reaction in _acceptedReactionsWithinLifecycle(bundle, state)) {
      if (!SpaceAcl(state).allows(
        reaction.author,
        SpacePermission.publishMessages,
        atMs: reaction.createdAtMs,
      )) {
        continue;
      }
      final visible = await _materializeEncryptedReaction(bundle, reaction);
      if (visible != null &&
          visible.targetKind == ReactionTargetKind.spacePost &&
          allowedPostIds.contains(visible.target)) {
        materialized.add(visible);
      }
    }
    return foldReactionsByKind(
      materialized,
      _signer.verifyReaction,
      ReactionTargetKind.spacePost,
    );
  }

  // ── Content path (doc/GROUPS-CONTENT-PATH.md) ─────────────────────────────

  /// Replay cache for inbound fetch requests (holder side), bounded FIFO.
  final Set<String> _seenContentNonces = <String>{};
  static const int _kMaxSeenNonces = 512;

  /// The contentIds referenced by validated channel messages or Space posts —
  /// the only content a membership grant may unlock (membership must not
  /// become a license to fetch arbitrary content this device holds).
  Future<Set<String>> referencedContentIds(NodeId groupId) async {
    final msgs = await messagesOf(groupId, applyLocalRetention: false);
    final bundle = await load(groupId);
    final posts = bundle == null || !bundle.manifest.isSpace
        ? const <SpacePostView>[]
        : await _postsOfBundle(bundle);
    return {
      for (final m in msgs)
        if (m.attachment?.cid != null) m.attachment!.cid!,
      for (final post in posts)
        for (final media in post.media) media.contentId,
    };
  }

  /// Mint, sign and ship a fetch request for [cid] of [groupId] to [holder]
  /// (normally the message author). False when the wire sender isn't attached.
  Future<bool> requestGroupContent(
    NodeId groupId,
    String cid,
    NodeId holder,
  ) async {
    final send = sendContentRequest;
    if (send == null) return false;
    final rnd = Random.secure();
    final nonce = List<int>.generate(
      12,
      (_) => rnd.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final signed = _signer.signContentRequest(
      GroupContentRequest(
        groupId: groupId,
        contentId: cid,
        requester: _signer.selfId,
        nonce: nonce,
        tsMs: _now(),
        signature: Uint8List(0),
      ),
    );
    await send(holder, jsonEncode(signed.toJson()));
    return true;
  }

  /// Holder side: authorize an inbound signed request against OUR folded view
  /// and grant the serve when it passes. Unauthorized requests return false
  /// with only a local log line — the requester gets NOTHING back (no
  /// membership oracle, per canon).
  Future<bool> handleContentRequest(String requestJson) async {
    GroupContentRequest? r;
    try {
      r = GroupContentRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      /* malformed → drop */
    }
    if (r == null) return false;
    final req = r;
    final st = await stateOf(req.groupId);
    if (st == null) {
      devLog(() => 'xVeil[groups]: content request for unknown group — drop');
      return false;
    }
    final denial = authorizeGroupContentRequest(
      req,
      state: st,
      referenced: await referencedContentIds(req.groupId),
      nowMs: _now(),
      seenNonces: _seenContentNonces,
      verify: _signer.verifyContentRequest,
    );
    if (denial != null) {
      devLog(
        () => 'xVeil[groups]: content request DENIED (${denial.name}) — drop',
      );
      return false;
    }
    if (_seenContentNonces.length >= _kMaxSeenNonces) {
      _seenContentNonces.remove(_seenContentNonces.first);
    }
    _seenContentNonces.add(req.nonce);
    grantContentServe?.call(req.requester, req.contentId);
    return true;
  }

  /// Whether NON-contact [peer] may sync group [gidHex]: we already hold that
  /// group AND the peer is a current member per OUR fold. The admission the
  /// wire layer asks before spending reassembly RAM on a stranger's chunks.
  Future<bool> allowStrangerGroupSync(NodeId peer, String gidHex) async {
    if (!(await _index()).contains(gidHex)) return false;
    final NodeId gid;
    try {
      gid = NodeId.fromHex(gidHex);
    } catch (_) {
      return false;
    }
    final st = await stateOf(gid);
    return st != null && st.isMember(peer);
  }

  /// Ingest a snapshot from a NON-contact sender: merge ONLY into a group we
  /// already hold where [peer] is a current member — the scale-free log sync
  /// (members need no pairwise contact handshake). Never materializes a NEW
  /// group: a stranger's group-invite is spam until a consent surface exists,
  /// so that path stays contact-gated. Unauthorized bundles are dropped with
  /// nothing sent back (no membership oracle).
  Future<bool> ingestSnapshotFromStranger(
    NodeId peer,
    String bundleJson,
  ) async {
    String? gidHex;
    try {
      final d = jsonDecode(bundleJson);
      final m = d is Map ? d['m'] : null;
      final gid = m is Map ? m['gid'] : null;
      if (gid is String && gid.isNotEmpty) gidHex = gid;
    } catch (_) {
      /* malformed → drop below */
    }
    if (gidHex == null) return false;
    final pending = await _tryPendingDeviceSnapshot(peer, bundleJson);
    if (pending != null) return pending;
    if (!await allowStrangerGroupSync(peer, gidHex)) {
      devLog(() => 'xVeil[groups]: stranger snapshot DENIED — drop');
      return false;
    }
    return ingestSnapshot(bundleJson);
  }

  /// Returns null when [bundleJson] is unrelated to the pending ceremony,
  /// otherwise consumes it (true) or rejects it (false). Shared by contact and
  /// non-contact ingress: prior contact status must not change adoption rules.
  Future<bool?> _tryPendingDeviceSnapshot(
    NodeId peer,
    String bundleJson,
  ) async {
    final pending = await pendingDeviceAdoption();
    if (pending == null || peer != pending.source) return null;
    GroupManifest? manifest;
    try {
      final d = jsonDecode(bundleJson);
      manifest = GroupManifest.fromJson(d is Map ? d['m'] : null);
    } catch (_) {
      return false;
    }
    if (manifest == null || manifest.groupId != pending.groupId) return null;
    if (!_listEquals(_manifestHash(manifest), pending.manifestHash)) {
      return false;
    }
    if (!await ingestSnapshot(bundleJson)) return false;
    if (!await adoptDeviceGroup(pending.groupId)) return false;
    await cancelPendingDeviceAdoption();
    return true;
  }

  /// Fetch [cid] of [groupId], preferring [holder] (normally the message
  /// author) but authorizing EVERY other current member as a candidate seeder.
  /// Thus a member that downloaded and verified the blob can keep serving it
  /// after the author goes offline. We intentionally do not publish persistent
  /// holder/read advertisements: one explicit user fetch sends the same signed
  /// membership request to all candidates, non-holders deny silently, and the
  /// content-addressed pull stops at the first verified source.
  Future<bool> fetchGroupContent(
    NodeId groupId,
    String cid,
    NodeId holder,
  ) async {
    final pullAny = startContentPullFromAny;
    final pullOne = startContentPull;
    if (pullAny == null && pullOne == null) return false;
    final state = await stateOf(groupId);
    if (state == null ||
        !SpaceAcl(
          state,
        ).allows(_signer.selfId, SpacePermission.distributeContent)) {
      return false;
    }
    if (!(await referencedContentIds(groupId)).contains(cid)) return false;

    final members = [
      for (final member in state.members.values)
        if (member.nodeId != _signer.selfId) member.nodeId,
    ]..sort((a, b) => a.hex.compareTo(b.hex));
    if (members.isEmpty) return false;
    final candidates = <NodeId>[
      if (members.contains(holder)) holder,
      for (final member in members)
        if (member != holder) member,
    ];

    // Best-effort fanout: one temporarily unreachable member must not prevent
    // a reachable downloaded holder from receiving its authorization.
    final requestTargets = [
      for (final candidate in candidates.skip(1)) candidate,
      candidates.first,
    ];
    await Future.wait<bool>([
      // Launch fallback members before the preferred author: the pull still
      // prefers the author, but its dead route cannot queue every grant behind
      // it inside a serialized transport.
      for (final candidate in requestTargets)
        requestGroupContent(groupId, cid, candidate).catchError((Object e) {
          devLog(
            () =>
                'xVeil[groups]: content request to '
                '${candidate.short} failed locally: $e',
          );
          return false;
        }),
    ]).timeout(
      contentRequestFanoutTimeout,
      onTimeout: () {
        devLog(
          () =>
              'xVeil[groups]: content request fanout deadline reached; '
              'starting scoped pull',
        );
        return const <bool>[];
      },
    );
    // Durable requests need a wire round-trip before grants exist. Pull retries
    // preserve correctness; this delay avoids burning the first open on DENIED.
    if (contentGrantDelay > Duration.zero) {
      await Future<void>.delayed(contentGrantDelay);
    }
    if (pullAny != null) {
      await pullAny(candidates, cid);
    } else {
      await pullOne!(candidates.first, cid);
    }
    return true;
  }

  /// Ingest an externally-received control entry (from a peer-sync brick, or a
  /// hook). Appends if it isn't already present; the fold decides validity on
  /// read, so a bogus entry simply never applies.
  Future<void> ingestControl(NodeId groupId, ControlEntry e) =>
      _serialized(groupId, () => _ingestControl(groupId, e));

  Future<void> _ingestControl(NodeId groupId, ControlEntry e) async {
    final b = await load(groupId);
    if (b == null) return;
    if (!_validControlFor(b.manifest, e)) return;
    final incomingHash = controlEntryHash(e);
    if (b.control.any(
      (x) =>
          _validControlFor(b.manifest, x) &&
          controlEntryHash(x) == incomingHash,
    )) {
      return;
    }
    // Keep a distinct same-seq row as equivocation evidence. The pure fold
    // rejects both branches and their suffix; discarding the second arrival
    // would make authority depend on which peer happened to answer first.
    await _save(b.copyWith(control: [...b.control, e]));
  }

  List<GroupEpochRecipientEnvelope> _epochEnvelopesFor(
    GroupBundle bundle,
    NodeId recipient, {
    Iterable<ControlEntry>? controls,
  }) {
    final descriptors =
        (controls ?? _acceptedControl(bundle.manifest, bundle.control))
            .map((entry) => entry.epochDescriptor)
            .whereType<GroupEpochDescriptor>()
            .toList();
    return [
      for (final envelope in bundle.epochEnvelopes)
        if (envelope.recipient == recipient &&
            descriptors.any(
              (descriptor) => verifyGroupEpochEnvelope(
                descriptor: descriptor,
                envelope: envelope,
              ),
            ))
          envelope,
    ];
  }

  List<GroupEpochRecipientEnvelope> _channelEpochEnvelopesFor(
    GroupBundle bundle,
    NodeId recipient, {
    Iterable<ControlEntry>? controls,
  }) {
    final accepted = _acceptedControl(bundle.manifest, bundle.control);
    final current = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state.protectedChannels;
    final selectedDescriptors = (controls ?? accepted)
        .map((entry) => entry.channelControl?.keyDescriptor)
        .whereType<GroupEpochDescriptor>()
        .where(
          (descriptor) => bundle.channelEpochEnvelopes.any(
            (envelope) =>
                envelope.recipient == recipient &&
                verifyGroupEpochEnvelope(
                  descriptor: descriptor,
                  envelope: envelope,
                ),
          ),
        )
        .toList();
    final allowedChannelIds = <String>{};
    for (final scope in current.values) {
      final canOpenCurrent = bundle.channelEpochEnvelopes.any(
        (envelope) =>
            envelope.recipient == recipient &&
            envelope.groupId == scope.channelId &&
            envelope.epoch == scope.channelEpoch &&
            verifyGroupEpochEnvelope(
              descriptor: scope.keyDescriptor,
              envelope: envelope,
            ),
      );
      if (canOpenCurrent) allowedChannelIds.add(scope.channelId.hex);
    }
    return [
      for (final envelope in bundle.channelEpochEnvelopes)
        if (allowedChannelIds.contains(envelope.groupId.hex) &&
            selectedDescriptors.any(
              (descriptor) => verifyGroupEpochEnvelope(
                descriptor: descriptor,
                envelope: envelope,
              ),
            ))
          envelope,
    ];
  }

  bool _peerCanDecryptChannelEpoch(
    GroupBundle bundle,
    NodeId peer,
    NodeId channelId,
    int epoch,
  ) {
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    final current = state.protectedChannels[channelId.hex];
    if (current == null) return false;
    final envelopes = _channelEpochEnvelopesFor(bundle, peer);
    return envelopes.any(
          (envelope) =>
              envelope.groupId == channelId &&
              envelope.epoch == current.channelEpoch,
        ) &&
        envelopes.any(
          (envelope) =>
              envelope.groupId == channelId && envelope.epoch == epoch,
        );
  }

  bool _peerCanDecryptEpoch(GroupBundle bundle, NodeId peer, int epoch) {
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (state.epochDescriptor?.epoch == epoch && state.isMember(peer)) {
      return true;
    }
    return _epochEnvelopesFor(
      bundle,
      peer,
    ).any((envelope) => envelope.epoch == epoch);
  }

  /// Serialize a full snapshot tailored to one recipient. Epoch envelopes are
  /// never broadcast as a member list: the peer receives only its own sealed
  /// record and only ciphertext epochs it can open. [recipient] may be omitted
  /// by legacy unit/debug callers; such snapshots contain no epoch material.
  String snapshotJson(GroupBundle b, {NodeId? recipient}) {
    final encryptionEstablished = _encryptionEstablished(b.manifest, b.control);
    final lifecycleState = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (entry) => _validControlFor(b.manifest, entry),
      initialName: b.manifest.name,
      initialDescription: b.manifest.description ?? '',
    ).state;
    final distributesContent = !lifecycleState.isDeleted;
    final epochEnvelopes = recipient == null || !distributesContent
        ? const <GroupEpochRecipientEnvelope>[]
        : _epochEnvelopesFor(b, recipient);
    final channelEpochEnvelopes = recipient == null || !distributesContent
        ? const <GroupEpochRecipientEnvelope>[]
        : _channelEpochEnvelopesFor(b, recipient);
    return jsonEncode({
      'm': b.manifest.toJson(),
      'c': b.control
          .where(
            (e) => e.isStructurallyValid && _validControlFor(b.manifest, e),
          )
          .map((e) => e.toJson())
          .toList(),
      'g': _retainedMessageRows(b.manifest, b.messages)
          .where(
            (message) =>
                distributesContent &&
                _validMessageFor(b.manifest.groupId, message) &&
                _messageWithinLifecycleBoundary(
                  b.manifest,
                  lifecycleState,
                  message,
                ) &&
                (message.isChannelEncrypted
                    ? recipient != null &&
                          _peerCanDecryptChannelEpoch(
                            b,
                            recipient,
                            message.channelId!,
                            message.channelEpoch!,
                          )
                    : !encryptionEstablished
                    ? true
                    : message.isEncrypted &&
                          recipient != null &&
                          _peerCanDecryptEpoch(
                            b,
                            recipient,
                            message.membershipEpoch!,
                          )),
          )
          .map((message) => message.toJson())
          .toList(),
      if (b.posts.isNotEmpty)
        'p': b.posts
            .where(
              (post) =>
                  distributesContent &&
                  _validPostFor(b.manifest.groupId, post) &&
                  _postWithinLifecycleBoundary(lifecycleState, post) &&
                  (!post.isEncrypted ||
                      (recipient != null &&
                          _peerCanDecryptEpoch(
                            b,
                            recipient,
                            post.membershipEpoch!,
                          ))),
            )
            .map((post) => post.toJson())
            .toList(),
      'r': _acceptedReactionsWithinLifecycle(b, lifecycleState)
          .where(
            (reaction) =>
                distributesContent &&
                (!encryptionEstablished
                    ? true
                    : reaction.isEncrypted &&
                          recipient != null &&
                          _peerCanDecryptEpoch(
                            b,
                            recipient,
                            reaction.membershipEpoch!,
                          )),
          )
          .map((r) => r.toJson())
          .toList(),
      if (epochEnvelopes.isNotEmpty)
        'ke': epochEnvelopes.map((entry) => entry.toJson()).toList(),
      if (channelEpochEnvelopes.isNotEmpty)
        'cke': channelEpochEnvelopes.map((entry) => entry.toJson()).toList(),
      if (b.sovereignBundle != null) 's': base64Encode(b.sovereignBundle!),
    });
  }

  /// Ingest a received snapshot: materialize the group if new (manifest +
  /// index), then merge control + message entries. Exact signed rows dedup by
  /// hash; distinct same-scope `(author, seq)` rows remain as fork evidence.
  /// Idempotent — re-delivery of the same snapshot is a no-op.
  Future<bool> ingestSnapshot(String bundleJson) async {
    try {
      final value = jsonDecode(bundleJson);
      final manifest = value is Map ? value['m'] : null;
      final gid = manifest is Map ? manifest['gid'] : null;
      if (gid is! String) return false;
      return _serialized(
        NodeId.fromHex(gid),
        () => _ingestSnapshot(bundleJson),
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ingestSnapshot(String bundleJson) async {
    Map<String, dynamic> d;
    try {
      d = jsonDecode(bundleJson) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }
    final manifest = GroupManifest.fromJson(d['m']);
    if (manifest == null || !_validManifest(manifest)) return false;
    final Uint8List? incomingSovereignBundle;
    try {
      incomingSovereignBundle = d['s'] is String
          ? Uint8List.fromList(base64Decode(d['s'] as String))
          : null;
    } catch (_) {
      return false;
    }
    final inControl = (d['c'] as List? ?? const [])
        .map(ControlEntry.fromJson)
        .whereType<ControlEntry>()
        .toList();
    final inMsgs = (d['g'] as List? ?? const [])
        .map(GroupMessage.fromJson)
        .whereType<GroupMessage>()
        .toList();
    final inPosts = (d['p'] as List? ?? const [])
        .map(SpacePost.fromJson)
        .whereType<SpacePost>()
        .toList();
    final inReactions = (d['r'] as List? ?? const [])
        .map(GroupReaction.fromJson)
        .whereType<GroupReaction>()
        .toList();
    final inEpochEnvelopes = (d['ke'] as List? ?? const [])
        .map(GroupEpochRecipientEnvelope.fromJson)
        .whereType<GroupEpochRecipientEnvelope>()
        .toList();
    final inChannelEpochEnvelopes = (d['cke'] as List? ?? const [])
        .map(GroupEpochRecipientEnvelope.fromJson)
        .whereType<GroupEpochRecipientEnvelope>()
        .toList();

    final deletionTombstone = await deletedSpaceTombstone(manifest.groupId);
    if (deletionTombstone != null) {
      final incomingFold = foldControlLog(
        owner: manifest.owner,
        entries: inControl,
        verify: (entry) => _validControlFor(manifest, entry),
        initialName: manifest.name,
        initialDescription: manifest.description ?? '',
      );
      final containsPurgedDelete = incomingFold.accepted.any(
        (entry) =>
            entry.op == ControlOp.deleteSpace &&
            controlEntryHash(entry) == deletionTombstone.deleteTransitionHash,
      );
      if (!containsPurgedDelete) return false;
      // Re-delivery of the expired deletion is an idempotent no-op. Only a
      // complete log with a valid owner restore authored inside the signed
      // recovery window may materialize the Space again.
      if (incomingFold.state.isDeleted) return true;
      if (incomingFold.state.lifecycleTransition == null) return false;
    }

    final existing = await load(manifest.groupId);
    if ((existing == null &&
            !_validSovereignBundle(manifest, incomingSovereignBundle)) ||
        (existing != null &&
            incomingSovereignBundle != null &&
            !_validSovereignBundle(manifest, incomingSovereignBundle))) {
      return false;
    }
    final man = existing == null
        ? manifest
        : _mergeManifest(existing.manifest, manifest);
    if (man == null) return false;
    final acceptedPostIdsBefore = !man.isSpace || existing == null
        ? <String>{}
        : {for (final post in await _postsOfBundle(existing)) post.postId};
    final control = [...(existing?.control ?? const <ControlEntry>[])];
    final messages = [...(existing?.messages ?? const <GroupMessage>[])];
    final acceptedMessageHashesBefore = existing == null
        ? <String>{}
        : {
            for (final message in _acceptedMessagesWithinLifecycle(
              existing,
              foldControlLog(
                owner: existing.manifest.owner,
                entries: existing.control,
                verify: (entry) => _validControlFor(existing.manifest, entry),
                initialName: existing.manifest.name,
              ).state,
            ))
              groupMessageHash(message),
          };
    final posts = [...(existing?.posts ?? const <SpacePost>[])];
    final reactions = [...(existing?.reactions ?? const <GroupReaction>[])];
    for (final e in inControl) {
      if (!_validControlFor(man, e)) continue;
      final incomingHash = controlEntryHash(e);
      if (!control.any(
        (x) =>
            _validControlFor(man, x) && x.author == e.author && x.seq == e.seq,
      )) {
        control.add(e);
      } else if (!control.any(
        (x) => _validControlFor(man, x) && controlEntryHash(x) == incomingHash,
      )) {
        // Preserve distinct same-seq evidence; foldControlLog quarantines the
        // author deterministically from the fork point onward.
        control.add(e);
      }
    }
    final mergedState = foldControlLog(
      owner: man.owner,
      entries: control,
      verify: (e) => _validControlFor(man, e),
      initialName: man.name,
    ).state;
    final material = await _mergeEpochMaterial(
      manifest: man,
      control: control,
      existingEnvelopes:
          existing?.epochEnvelopes ?? const <GroupEpochRecipientEnvelope>[],
      existingKeys: existing?.localEpochKeys ?? const <int, Uint8List>{},
      incomingEnvelopes: inEpochEnvelopes,
    );
    final channelMaterial = await _mergeChannelEpochMaterial(
      manifest: man,
      control: control,
      existingEnvelopes:
          existing?.channelEpochEnvelopes ??
          const <GroupEpochRecipientEnvelope>[],
      existingKeys:
          existing?.localChannelEpochKeys ?? const <String, Uint8List>{},
      incomingEnvelopes: inChannelEpochEnvelopes,
    );
    final materialBundle = GroupBundle(
      manifest: man,
      control: control,
      messages: messages,
      posts: posts,
      reactions: reactions,
      epochEnvelopes: material.envelopes,
      localEpochKeys: material.keys,
      channelEpochEnvelopes: channelMaterial.envelopes,
      localChannelEpochKeys: channelMaterial.keys,
      sovereignBundle: existing?.sovereignBundle ?? incomingSovereignBundle,
    );
    final protectedChannels = man.isSpace
        ? await _protectedChannelsOf(materialBundle, mergedState)
        : const <String, SpaceChannelControlCleartext>{};
    final encryptionEstablished = _encryptionEstablished(man, control);
    final fresh = <GroupMessage>[];
    for (final m in inMsgs) {
      if (!_validMessageFor(manifest.groupId, m)) {
        continue;
      }
      if (!_messageWithinLifecycleBoundary(man, mergedState, m)) continue;
      if (man.isSpace) {
        final effectiveChannel =
            m.channelId ?? defaultSpaceChannelId(man.groupId);
        final protected = protectedChannels[effectiveChannel.hex];
        if (!mergedState.channels.containsKey(effectiveChannel.hex) &&
            protected == null) {
          continue;
        }
        if (protected != null) {
          final opaque = mergedState.protectedChannels[effectiveChannel.hex];
          if (!m.isChannelEncrypted ||
              opaque == null ||
              m.channelEpoch != opaque.channelEpoch ||
              !protected.recipients.contains(m.author)) {
            continue;
          }
        } else if (m.isChannelEncrypted) {
          continue;
        }
      }
      if (m.isEncrypted) {
        if (m.isChannelEncrypted) {
          final channelId = m.channelId!;
          final epoch = m.channelEpoch!;
          final key = channelMaterial.keys[_channelKeyId(channelId, epoch)];
          if (key == null ||
              !_validLocalChannelEpochKey(
                man,
                control,
                channelId,
                epoch,
                key,
              ) ||
              !mergedState.isMember(m.author)) {
            continue;
          }
          final visible = await _materializeEncryptedMessage(materialBundle, m);
          if (visible == null || visible.attachment != null) {
            // Protected-channel media still uses the Space-wide content grant
            // protocol. Reject it at ingest until requests carry channel ACL.
            continue;
          }
        } else {
          final epoch = m.membershipEpoch!;
          final key = material.keys[epoch];
          if (key == null ||
              !_validLocalEpochKey(man, control, epoch, key) ||
              !mergedState.isMember(m.author)) {
            continue;
          }
        }
      } else if (encryptionEstablished || !mergedState.isMember(m.author)) {
        // Once a signed epoch descriptor exists, a clear v1 row is a
        // downgrade attempt. Historical local v1 rows remain readable but are
        // never newly imported into an encrypted group.
        continue;
      }
      final incomingHash = groupMessageHash(m);
      if (!messages.any(
        (stored) =>
            _validMessageFor(manifest.groupId, stored) &&
            groupMessageHash(stored) == incomingHash,
      )) {
        messages.add(m);
      }
    }
    // Notify only rows that became part of an accepted scoped chain. A suffix
    // received before its predecessor stays silent; when gap-fill later closes
    // the chain, the predecessor and newly-unblocked suffix become visible in
    // one deterministic batch. Fork evidence never produces a notification.
    fresh.addAll(
      _acceptedMessagesWithinLifecycle(
        materialBundle.copyWith(messages: messages),
        mergedState,
      ).where(
        (message) =>
            message.author != _signer.selfId &&
            !acceptedMessageHashesBefore.contains(groupMessageHash(message)),
      ),
    );
    for (final post in inPosts) {
      if (!man.isSpace || !_validPostFor(man.groupId, post)) continue;
      if (!_postWithinLifecycleBoundary(mergedState, post)) continue;
      final historicallyAuthorized =
          post.isCausal &&
          _causalPostHistoricallyAuthorized(man, control, post);
      final legacyAuthorized =
          !post.isCausal &&
          SpaceAcl(mergedState).allows(
            post.author,
            SpacePermission.publishPosts,
            atMs: post.createdAtMs,
          );
      if (!historicallyAuthorized && !legacyAuthorized) continue;
      if (post.visibility == SpacePostVisibility.public) {
        if (man.visibility != SpaceVisibility.public) {
          continue;
        }
      } else {
        final epoch = post.membershipEpoch!;
        final key = material.keys[epoch];
        if (!post.isEncrypted ||
            key == null ||
            !_validLocalEpochKey(man, control, epoch, key)) {
          continue;
        }
        if (await _materializeEncryptedPost(
              GroupBundle(
                manifest: man,
                control: control,
                messages: messages,
                posts: posts,
                reactions: reactions,
                epochEnvelopes: material.envelopes,
                localEpochKeys: material.keys,
                channelEpochEnvelopes: channelMaterial.envelopes,
                localChannelEpochKeys: channelMaterial.keys,
              ),
              post,
            ) ==
            null) {
          continue;
        }
      }
      final existingIndex = posts.indexWhere(
        (stored) =>
            _validPostFor(man.groupId, stored) &&
            _spacePostHash(stored) == _spacePostHash(post),
      );
      if (existingIndex < 0) {
        posts.add(post);
      }
    }
    final targetBundle = GroupBundle(
      manifest: man,
      control: control,
      messages: messages,
      posts: posts,
      reactions: reactions,
      epochEnvelopes: material.envelopes,
      localEpochKeys: material.keys,
      channelEpochEnvelopes: channelMaterial.envelopes,
      localChannelEpochKeys: channelMaterial.keys,
    );
    final visiblePostIds = man.isSpace
        ? {for (final post in await _postsOfBundle(targetBundle)) post.postId}
        : const <String>{};
    final acceptedMessageRefs = {
      for (final message in _acceptedMessagesWithinLifecycle(
        targetBundle,
        mergedState,
      ))
        if (!message.isChannelEncrypted) message.ref,
    };
    for (final r in inReactions) {
      if (!_validReactionFor(manifest.groupId, r) ||
          !_reactionWithinLifecycleBoundary(mergedState, r) ||
          !SpaceAcl(mergedState).allows(
            r.author,
            SpacePermission.publishMessages,
            atMs: r.createdAtMs,
          )) {
        continue;
      }
      GroupReaction? visibleReaction;
      if (r.isEncrypted) {
        final epoch = r.membershipEpoch!;
        final key = material.keys[epoch];
        if (key == null || !_validLocalEpochKey(man, control, epoch, key)) {
          continue;
        }
        visibleReaction = await _materializeEncryptedReaction(targetBundle, r);
      } else if (encryptionEstablished) {
        continue;
      } else {
        visibleReaction = r;
      }
      if (visibleReaction == null) continue;
      final targetExists = switch (visibleReaction.targetKind) {
        ReactionTargetKind.message => acceptedMessageRefs.contains(
          visibleReaction.target,
        ),
        ReactionTargetKind.spacePost =>
          man.isSpace && visiblePostIds.contains(visibleReaction.target),
      };
      if (!targetExists) {
        // A Space-epoch reaction must not become an oracle for protected or
        // deleted content. Unknown/out-of-order targets stay retryable through
        // the per-author reaction sync vector.
        continue;
      }
      if (!reactions.any(
        (stored) =>
            _validReactionFor(manifest.groupId, stored) &&
            stored.author == r.author &&
            stored.seq == r.seq,
      )) {
        reactions.add(r);
      }
    }
    final saved = GroupBundle(
      manifest: man,
      control: control,
      messages: messages,
      posts: posts,
      reactions: reactions,
      epochEnvelopes: material.envelopes,
      localEpochKeys: material.keys,
      channelEpochEnvelopes: channelMaterial.envelopes,
      localChannelEpochKeys: channelMaterial.keys,
      sovereignBundle: existing?.sovereignBundle ?? incomingSovereignBundle,
    );
    await _save(saved);
    final freshPosts = !man.isSpace
        ? const <SpacePostView>[]
        : (await _postsOfBundle(saved))
              .where(
                (post) =>
                    post.author != _signer.selfId &&
                    !acceptedPostIdsBefore.contains(post.postId),
              )
              .toList();
    if (deletionTombstone != null) {
      await _clearDeletedSpaceTombstone(man.groupId);
    }
    final adoptedDeviceGroup =
        man.name == kDeviceGroupName &&
        await deviceGroupIdHex() == man.groupId.hex;
    if (adoptedDeviceGroup) {
      _publishDeviceMembersCache(man, mergedState);
    }
    if (existing == null) {
      final idx = await _index();
      if (!idx.contains(man.groupId.hex)) {
        idx.add(man.groupId.hex);
        await _setIndex(idx);
      }
    }
    if (man.name != kDeviceGroupName &&
        _epochService != null &&
        _encryptionEstablished(man, control) &&
        mergedState.epochDescriptor == null &&
        mergedState.memberOf(_signer.selfId)?.role == GroupRole.owner) {
      // A leave or a concurrent stale departure descriptor advances
      // membership without a usable key. Only the effective owner repairs it,
      // avoiding an admin race; writes remain fail-closed until this succeeds.
      unawaited(addControlOp(man.groupId, ControlOp.rotateEpoch));
    }
    if (man.isSpace &&
        mergedState.roleOf(_signer.selfId) == GroupRole.owner &&
        mergedState.protectedChannels.isNotEmpty) {
      // A remote membership/role mutation may invalidate the encrypted ACL.
      // Only the effective owner repairs it to avoid concurrent admins creating
      // competing epoch+1 revisions; until then materialization is fail-closed.
      unawaited(_repairProtectedChannelEpochs(man.groupId));
    }
    // Device-group traffic is sync machinery, not chat: it must never buzz
    // the notification layer or count as chat-unread. It routes to a SEPARATE
    // stream the multi-device bridge consumes (device-sync events).
    if (man.name == kDeviceGroupName) {
      // A marker snapshot is inert until the local handshake explicitly
      // adopts this exact gid. Otherwise any contact could plant a valid-
      // looking infrastructure group and drive sync apply side effects.
      if (adoptedDeviceGroup) {
        for (final m in fresh) {
          final materialized = await _materializeEncryptedMessage(saved, m);
          if (materialized != null) _deviceIncomingCtl.add(materialized);
        }
      }
    } else {
      for (final m in fresh) {
        final materialized = await _materializeEncryptedMessage(saved, m);
        if (materialized != null) {
          _incomingCtl.add((groupId: man.groupId, message: materialized));
        }
      }
      for (final post in freshPosts) {
        _incomingPostCtl.add((spaceId: man.groupId, post: post));
      }
    }
    return true;
  }

  /// Fresh (post-dedup, verified, not-self) messages of MY device group — the
  /// multi-device bridge folds these into DeviceSyncEvents and applies them.
  final StreamController<GroupMessage> _deviceIncomingCtl =
      StreamController.broadcast();
  Stream<GroupMessage> get deviceIncoming => _deviceIncomingCtl.stream;

  /// Genuinely-NEW inbound messages (post-dedup, signature-verified, not
  /// self-authored) — the notification/unread layer's feed, symmetric to
  /// MessagingService.incoming.
  final StreamController<({NodeId groupId, GroupMessage message})>
  _incomingCtl = StreamController.broadcast();
  Stream<({NodeId groupId, GroupMessage message})> get incoming =>
      _incomingCtl.stream;

  /// Newly accepted publication roots after validation, ACL checks,
  /// decryption and chain folding. Edits keep the root id and therefore do not
  /// generate another alert; fork evidence and tombstoned rows never enter the
  /// stream.
  final StreamController<({NodeId spaceId, SpacePostView post})>
  _incomingPostCtl = StreamController.broadcast();
  Stream<({NodeId spaceId, SpacePostView post})> get incomingPosts =>
      _incomingPostCtl.stream;

  /// Attached by the multi-device bridge: a LOCAL group-seen advance (never
  /// fired from [applyMirroredGroupSeen]) — my other devices clear the badge.
  void Function(String gidHex, int tsMs)? onGroupSeen;

  /// Mark [groupId] read "as of now" — the unread watermark the open group
  /// screen advances. A local display preference, not group state.
  Future<void> markGroupSeen(NodeId groupId) async {
    final ts = _now();
    await _storage.putSetting('group.seen:${groupId.hex}', '$ts');
    onGroupSeen?.call(groupId.hex, ts);
  }

  /// Apply a group-seen watermark mirrored from ANOTHER of my devices —
  /// monotonic, straight to storage (no [onGroupSeen] echo). Returns whether
  /// the watermark advanced.
  Future<bool> applyMirroredGroupSeen(String gidHex, int tsMs) async {
    final cur =
        int.tryParse(await _storage.getSetting('group.seen:$gidHex') ?? '') ??
        0;
    if (cur >= tsMs) return false;
    await _storage.putSetting('group.seen:$gidHex', '$tsMs');
    changes.value++; // group list re-renders its badge
    return true;
  }

  /// How many VALIDATED messages of [groupId] are newer than the seen
  /// watermark and not self-authored.
  Future<int> unreadOf(NodeId groupId) async {
    final wm =
        int.tryParse(
          await _storage.getSetting('group.seen:${groupId.hex}') ?? '',
        ) ??
        0;
    final msgs = await messagesOf(groupId);
    return msgs.where((m) => m.createdAtMs > wm && m.author != selfId).length;
  }

  /// Local notification mute for [groupId] — a display preference like the
  /// unread watermark (never sent anywhere; distinct from the CONTROL-LOG
  /// member mute, which is about posting rights).
  Future<void> setGroupMuted(NodeId groupId, bool muted) async {
    await _storage.putSetting('group.muted:${groupId.hex}', muted ? '1' : '');
    changes.value++; // the group list re-renders its mute affordance
  }

  Future<bool> isGroupMuted(NodeId groupId) async =>
      (await _storage.getSetting('group.muted:${groupId.hex}')) == '1';

  // ── Device group (multi-device epic, doc/MULTIDEVICE-DESIGN.md) ──────────

  /// The reserved manifest name marking a DEVICE group (my devices' private
  /// sync group). Groups with this name are hidden from every user-facing
  /// list; the leading space cannot be produced through the create/rename
  /// dialogs (both trim their input).
  static const String kDeviceGroupName = ' xveil.devices';
  static const String kSovereignBundleSetting = 'devices.sovereign.bundle.v1';
  static const String kPendingDeviceAdoptionSetting =
      'devices.pending_adoption.v1';

  String? _deviceGidCache;

  /// My device group's id (hex), or null before the first link/adopt.
  Future<String?> deviceGroupIdHex() async {
    _deviceGidCache ??= await _storage.getSetting('devices.gid');
    return (_deviceGidCache?.isEmpty ?? true) ? null : _deviceGidCache;
  }

  Future<Uint8List?> localSovereignBundle() async {
    final raw = await _storage.getSetting(kSovereignBundleSetting);
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = Uint8List.fromList(base64Decode(raw));
      return value.length <= 16 * 1024 ? value : null;
    } catch (_) {
      return null;
    }
  }

  /// Decrypt the persisted bundle in native RAM for one signing burst. The
  /// first phrase-backed operation creates and stores only an encrypted blob.
  Future<NativeSovereignGroupSigner> openLocalSovereign(
    String phrase, {
    bool createIfMissing = true,
  }) async {
    final stored = await _storage.getSetting(kSovereignBundleSetting);
    Uint8List? bundle;
    if (stored != null && stored.isNotEmpty) {
      try {
        bundle = Uint8List.fromList(base64Decode(stored));
        if (bundle.isEmpty || bundle.length > 16 * 1024) {
          throw const FormatException('sovereign bundle size');
        }
      } catch (_) {
        throw StateError('Local sovereign bundle is corrupt');
      }
    } else if (createIfMissing) {
      bundle = veil.createHybrid512SovereignBundle(phrase);
      await _storage.putSetting(kSovereignBundleSetting, base64Encode(bundle));
    }
    if (bundle == null) throw StateError('No local sovereign bundle');
    final magic = bundle.length >= 4
        ? ascii.decode(bundle.sublist(0, 4), allowInvalid: true)
        : '';
    return magic == 'XVRC'
        ? NativeSovereignGroupSigner.openRecoveryCertificate(bundle, phrase)
        : NativeSovereignGroupSigner.openBundle(bundle, phrase);
  }

  /// How the persisted sovereign material is unlocked. Missing/corrupt stays
  /// null; callers must not guess that a legacy identity has a phrase.
  Future<String?> sovereignCredentialKind() async {
    final bundle = await localSovereignBundle();
    if (bundle == null || bundle.length < 4) return null;
    final magic = ascii.decode(bundle.sublist(0, 4), allowInvalid: true);
    return switch (magic) {
      'XVSB' => 'phrase',
      'XVRC' => 'certificate',
      _ => null,
    };
  }

  /// Export a fresh XVRC + independent 256-bit code from the current XVSB or
  /// XVRC credential. Decrypted key bytes never enter Dart.
  Future<({Uint8List certificate, String code, NodeId nodeId})?>
  exportRecoveryCertificate(String currentSecret) async {
    var credential = await localSovereignBundle();
    if (credential == null) {
      // A phrase-backed identity may pre-issue its certificate BEFORE its first
      // device link. Provision the normal XVSB once, exactly as link would.
      final provisioned = await openLocalSovereign(currentSecret);
      provisioned.close();
      credential = await localSovereignBundle();
    }
    if (credential == null) return null;
    final code = veil.generateSovereignRecoveryCode();
    final certificate = veil.exportSovereignRecoveryCertificate(
      credential,
      currentSecret,
      code,
    );
    final signer = NativeSovereignGroupSigner.openRecoveryCertificate(
      certificate,
      code,
    );
    try {
      return (certificate: certificate, code: code, nodeId: signer.nodeId);
    } finally {
      signer.close();
    }
  }

  /// All-devices-lost recovery: install one XVRC only into a fresh local
  /// device-registry state, then mint a fresh gid owned by the SAME full hybrid
  /// public key/node id. Never overwrites a different credential or group.
  Future<NodeId?> recoverDeviceGroupFromCertificate(
    Uint8List certificate,
    String recoveryCode,
  ) async {
    if (await deviceGroupIdHex() != null) return null;
    final existing = await localSovereignBundle();
    if (existing != null && !_listEquals(existing, certificate)) return null;
    final signer = NativeSovereignGroupSigner.openRecoveryCertificate(
      certificate,
      recoveryCode,
    );
    var installed = false;
    try {
      if (signer.algorithm != 'ed25519+falcon512') return null;
      if (existing == null) {
        await _storage.putSetting(
          kSovereignBundleSetting,
          base64Encode(certificate),
        );
        installed = true;
      }
      final gid = await _mintSovereignDeviceGroup(signer, const []);
      if (gid == null && installed) {
        await _storage.putSetting(kSovereignBundleSetting, '');
      }
      return gid;
    } catch (_) {
      if (installed) {
        await _storage.putSetting(kSovereignBundleSetting, '');
      }
      rethrow;
    } finally {
      signer.close();
    }
  }

  Uint8List _manifestHash(GroupManifest manifest) =>
      _sha256(utf8.encode(jsonEncode(manifest.toJson())));

  Future<DeviceLinkToken?> pendingDeviceAdoption() async {
    final raw = await _storage.getSetting(kPendingDeviceAdoptionSetting);
    if (raw == null || raw.isEmpty) return null;
    try {
      final token = DeviceLinkToken.fromJson(jsonDecode(raw));
      if (token == null || token.isExpired(_now())) return null;
      return token;
    } catch (_) {
      return null;
    }
  }

  /// Explicit target-side consent. Until this token is stored, a stranger can
  /// never materialize a new marker group. The token pins source, gid and the
  /// exact signed manifest; the subsequent snapshot still passes all normal
  /// signature, bundle-hash and self-membership checks.
  Future<bool> prepareDeviceAdoption(DeviceLinkToken token) async {
    if (token.source == _signer.selfId || token.isExpired(_now())) return false;
    await _storage.putSetting(
      kPendingDeviceAdoptionSetting,
      jsonEncode(token.toJson()),
    );
    return true;
  }

  Future<void> cancelPendingDeviceAdoption() =>
      _storage.putSetting(kPendingDeviceAdoptionSetting, '');

  /// Build the short QR token after the source has sovereign-signed the target
  /// into the local registry but before it broadcasts the encrypted snapshot.
  Future<DeviceLinkToken?> createDeviceLinkToken(
    BootstrapInvite sourceInvite,
  ) async {
    if (sourceInvite.nodeId != _signer.selfId) return null;
    final gidHex = await deviceGroupIdHex();
    if (gidHex == null) return null;
    final bundle = await load(NodeId.fromHex(gidHex));
    if (bundle == null || !bundle.manifest.isSovereignDevice) return null;
    return DeviceLinkToken(
      groupId: bundle.manifest.groupId,
      source: _signer.selfId,
      manifestHash: _manifestHash(bundle.manifest),
      sourceInvite: sourceInvite,
      expiresAtMs: _now() + const Duration(minutes: 30).inMilliseconds,
    );
  }

  Future<int> broadcastDeviceGroup() async {
    final gidHex = await deviceGroupIdHex();
    if (gidHex == null) return 0;
    return broadcast(NodeId.fromHex(gidHex));
  }

  bool _sovereignMatches(
    GroupManifest manifest,
    SovereignGroupSigner sovereign,
  ) =>
      manifest.isSovereignDevice &&
      manifest.signatureAlgorithm == sovereign.algorithm &&
      manifest.owner == sovereign.nodeId &&
      _listEquals(manifest.genesisPubKey, sovereign.publicKey);

  bool _canUpgradeSovereign(
    GroupManifest manifest,
    SovereignGroupSigner sovereign,
  ) =>
      manifest.isSovereignDevice &&
      manifest.signatureAlgorithm == 'ed25519' &&
      sovereign.algorithm == 'ed25519+falcon512' &&
      sovereign.publicKey.length == 929 &&
      _listEquals(manifest.genesisPubKey, sovereign.publicKey.sublist(0, 32));

  Future<NodeId?> _mintSovereignDeviceGroup(
    SovereignGroupSigner sovereign,
    Iterable<NodeId> devices, {
    GroupBundle? migrateFrom,
    bool broadcastSnapshot = true,
  }) async {
    final encryptedSovereign = await localSovereignBundle();
    if (sovereign.algorithm != 'ed25519' && encryptedSovereign == null) {
      return null;
    }
    final gid = _randomGroupId();
    final unsignedManifest = GroupManifest(
      groupId: gid,
      owner: sovereign.nodeId,
      genesisPubKey: Uint8List.fromList(sovereign.publicKey),
      name: kDeviceGroupName,
      createdAtMs: _now(),
      version: GroupManifest.sovereignDeviceVersion,
      kind: GroupManifest.sovereignDeviceKind,
      signatureAlgorithm: sovereign.algorithm,
      sovereignBundleHash: encryptedSovereign == null
          ? null
          : _sha256(encryptedSovereign),
    );
    final manifest = unsignedManifest.withSignature(
      sovereign.sign(unsignedManifest.canonicalBytes()),
    );
    if (!_validManifest(manifest)) return null;

    final unique = <String, NodeId>{
      _signer.selfId.hex: _signer.selfId,
      for (final d in devices) d.hex: d,
    }..remove(sovereign.nodeId.hex);
    final ordered = unique.values.toList()
      ..sort((a, b) => a.hex.compareTo(b.hex));
    final control = <ControlEntry>[];
    final baseTs = _now();
    for (var seq = 0; seq < ordered.length; seq++) {
      final unsigned = ControlEntry(
        version: 2,
        groupId: gid,
        author: sovereign.nodeId,
        seq: seq,
        prevHash: control.isEmpty ? '' : controlEntryHash(control.last),
        op: ControlOp.addMember,
        target: ordered[seq],
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: baseTs + seq,
        signature: Uint8List(0),
      );
      control.add(
        unsigned.withSignature(
          sovereign.sign(unsigned.canonicalBytes()),
          Uint8List.fromList(sovereign.publicKey),
        ),
      );
    }
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (e) => _validControlFor(manifest, e),
      initialName: manifest.name,
    );
    if (folded.rejected.isNotEmpty || !folded.state.isMember(_signer.selfId)) {
      return null;
    }

    final migratedMessages = <GroupMessage>[];
    if (migrateFrom != null) {
      final oldState = foldControlLog(
        owner: migrateFrom.manifest.owner,
        entries: migrateFrom.control,
        verify: (e) => _validControlFor(migrateFrom.manifest, e),
        initialName: migrateFrom.manifest.name,
      ).state;
      final compact =
          _compactDeviceMessages(migrateFrom.manifest.groupId, [
            for (final m in migrateFrom.messages)
              if (oldState.isMember(m.author)) m,
          ])..sort((a, b) {
            final ts = a.createdAtMs.compareTo(b.createdAtMs);
            return ts != 0 ? ts : _messageIdentityCompare(a, b);
          });
      for (var seq = 0; seq < compact.length; seq++) {
        final old = compact[seq];
        final unsigned = GroupMessage(
          groupId: gid,
          author: _signer.selfId,
          seq: seq,
          prevHash: '',
          body: old.body,
          policyVersion: 0,
          createdAtMs: old.createdAtMs,
          signature: Uint8List(0),
          attachment: old.attachment,
          customEmoji: old.customEmoji,
        );
        migratedMessages.add(_signer.signMessage(unsigned));
      }
    }

    await _save(
      GroupBundle(
        manifest: manifest,
        control: control,
        messages: migratedMessages,
        sovereignBundle: encryptedSovereign,
      ),
    );
    final idx = await _index();
    if (!idx.contains(gid.hex)) {
      idx.add(gid.hex);
      await _setIndex(idx);
    }
    await _storage.putSetting('devices.gid', gid.hex);
    _deviceGidCache = gid.hex;
    _publishDeviceMembersCache(manifest, folded.state);
    if (broadcastSnapshot) await broadcast(gid);
    return gid;
  }

  Future<NodeId?> ensureDeviceGroup(SovereignGroupSigner sovereign) async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return _mintSovereignDeviceGroup(sovereign, const []);
    final old = await load(NodeId.fromHex(hex));
    if (old == null) return null;
    if (old.manifest.isSovereignDevice) {
      if (_sovereignMatches(old.manifest, sovereign)) {
        return old.manifest.groupId;
      }
      if (!_canUpgradeSovereign(old.manifest, sovereign)) return null;
      final state = foldControlLog(
        owner: old.manifest.owner,
        entries: old.control,
        verify: (e) => _validControlFor(old.manifest, e),
        initialName: old.manifest.name,
      ).state;
      return _mintSovereignDeviceGroup(
        sovereign,
        state.members.values.map((m) => m.nodeId),
        migrateFrom: old,
      );
    }
    final state = foldControlLog(
      owner: old.manifest.owner,
      entries: old.control,
      verify: (e) => _validControlFor(old.manifest, e),
      initialName: old.manifest.name,
    ).state;
    return _mintSovereignDeviceGroup(
      sovereign,
      state.members.values.map((m) => m.nodeId),
      migrateFrom: old,
    );
  }

  /// ADOPT [groupId] as my device group — called by the NEW device during the
  /// link handshake (the QR channel carries the id out-of-band). Deliberately
  /// explicit: a device group is NEVER auto-adopted from an inbound snapshot,
  /// or any contact could plant a marker-named group and start receiving this
  /// device's sync events.
  Future<bool> adoptDeviceGroup(NodeId groupId) async {
    final bundle = await load(groupId);
    if (bundle == null ||
        !bundle.manifest.isSovereignDevice ||
        !_validManifest(bundle.manifest)) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (e) => _validControlFor(bundle.manifest, e),
      initialName: bundle.manifest.name,
    ).state;
    if (!state.isMember(_signer.selfId)) return false;
    await _storage.putSetting('devices.gid', groupId.hex);
    if (bundle.sovereignBundle != null) {
      await _storage.putSetting(
        kSovereignBundleSetting,
        base64Encode(bundle.sovereignBundle!),
      );
    }
    _deviceGidCache = groupId.hex;
    _publishDeviceMembersCache(bundle.manifest, state);
    changes.value++;
    // Ingest deliberately kept the snapshot inert before adoption. Replay its
    // validated state now that gid + sovereign genesis + membership are bound.
    for (final message in await messagesOf(groupId)) {
      if (message.author != _signer.selfId) {
        _deviceIncomingCtl.add(message);
      }
    }
    return true;
  }

  Future<bool> _appendSovereignMembership(
    GroupBundle bundle,
    SovereignGroupSigner sovereign,
    ControlOp op,
    NodeId device, {
    bool broadcastSnapshot = true,
  }) async {
    if (!_sovereignMatches(bundle.manifest, sovereign)) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (e) => _validControlFor(bundle.manifest, e),
      initialName: bundle.manifest.name,
    ).state;
    if (op == ControlOp.addMember && state.isMember(device)) return true;
    if (op == ControlOp.removeMember && !state.isMember(device)) return true;
    if (device == bundle.manifest.owner) return false;
    final link = _nextControlLink(
      bundle.manifest,
      bundle.control,
      sovereign.nodeId,
    );
    if (link.blocked) return false;
    final unsigned = ControlEntry(
      version: 2,
      groupId: bundle.manifest.groupId,
      author: sovereign.nodeId,
      seq: link.seq,
      prevHash: link.prevHash,
      op: op,
      target: device,
      role: op == ControlOp.addMember ? GroupRole.member : null,
      policyVersion: state.policyVersion,
      createdAtMs: _now(),
      signature: Uint8List(0),
    );
    final signed = unsigned.withSignature(
      sovereign.sign(unsigned.canonicalBytes()),
      Uint8List.fromList(sovereign.publicKey),
    );
    final candidate = [...bundle.control, signed];
    final folded = foldControlLog(
      owner: bundle.manifest.owner,
      entries: candidate,
      verify: (e) => _validControlFor(bundle.manifest, e),
      initialName: bundle.manifest.name,
    );
    if (folded.rejected.any(
      (e) => e.author == signed.author && e.seq == signed.seq,
    )) {
      return false;
    }
    await _save(bundle.copyWith(control: candidate));
    _publishDeviceMembersCache(bundle.manifest, folded.state);
    if (op == ControlOp.addMember && broadcastSnapshot) {
      await broadcast(bundle.manifest.groupId);
    } else if (op == ControlOp.removeMember) {
      await broadcastDelta(bundle.manifest.groupId, control: [signed]);
    }
    return true;
  }

  Future<bool> linkDevice(
    NodeId device, {
    required SovereignGroupSigner sovereign,
    bool broadcastSnapshot = true,
  }) async {
    final hex = await deviceGroupIdHex();
    if (hex == null) {
      return await _mintSovereignDeviceGroup(sovereign, [
            device,
          ], broadcastSnapshot: broadcastSnapshot) !=
          null;
    }
    final bundle = await load(NodeId.fromHex(hex));
    if (bundle == null) return false;
    if (!bundle.manifest.isSovereignDevice) {
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (e) => _validControlFor(bundle.manifest, e),
        initialName: bundle.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            [...state.members.values.map((m) => m.nodeId), device],
            migrateFrom: bundle,
            broadcastSnapshot: broadcastSnapshot,
          ) !=
          null;
    }
    if (!_sovereignMatches(bundle.manifest, sovereign) &&
        _canUpgradeSovereign(bundle.manifest, sovereign)) {
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (e) => _validControlFor(bundle.manifest, e),
        initialName: bundle.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            [...state.members.values.map((m) => m.nodeId), device],
            migrateFrom: bundle,
            broadcastSnapshot: broadcastSnapshot,
          ) !=
          null;
    }
    return _appendSovereignMembership(
      bundle,
      sovereign,
      ControlOp.addMember,
      device,
      broadcastSnapshot: broadcastSnapshot,
    );
  }

  /// Revoke [device]: removeMember — the fold rotates the epoch, so the
  /// removed device loses the future (already-synced history honestly stays).
  Future<bool> revokeDevice(
    NodeId device, {
    required SovereignGroupSigner sovereign,
  }) async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return false;
    final old = await load(NodeId.fromHex(hex));
    if (old == null) return false;
    if (!old.manifest.isSovereignDevice) {
      final state = foldControlLog(
        owner: old.manifest.owner,
        entries: old.control,
        verify: (e) => _validControlFor(old.manifest, e),
        initialName: old.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            state.members.values
                .map((m) => m.nodeId)
                .where((id) => id != device),
            migrateFrom: old,
          ) !=
          null;
    }
    if (!_sovereignMatches(old.manifest, sovereign) &&
        _canUpgradeSovereign(old.manifest, sovereign)) {
      final state = foldControlLog(
        owner: old.manifest.owner,
        entries: old.control,
        verify: (e) => _validControlFor(old.manifest, e),
        initialName: old.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            state.members.values
                .map((m) => m.nodeId)
                .where((id) => id != device),
            migrateFrom: old,
          ) !=
          null;
    }
    _invalidateDeviceMembersCache();
    return _appendSovereignMembership(
      old,
      sovereign,
      ControlOp.removeMember,
      device,
    );
  }

  /// Catch-up for the device group (brick 4e): ship my FULL device-group
  /// snapshot to every other device. Deltas posted while every entry node was
  /// down can be lost for good (the join-time full broadcast is the only
  /// recovery today — found live in the 2026-07-11 seed outage), so each
  /// device nudges once per boot; [ingestSnapshot] merges by (author, seq),
  /// so a redundant nudge costs bandwidth, never correctness. Returns how
  /// many devices it was shipped to (0 = no device group / solo install).
  Future<int> nudgeDeviceSync() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return 0;
    return broadcast(NodeId.fromHex(hex));
  }

  /// Whether [peer] is a CURRENT member of my device group — i.e. another of
  /// my own devices. The mirror taps consult this per stored message, so the
  /// folded member set is cached briefly; link/adopt/revoke invalidate it.
  Future<bool> isMyDevice(NodeId peer) async {
    while (true) {
      // A membership mutation may land while load() is awaiting storage. Its
      // generation invalidation must win over that stale read; otherwise the
      // old member set gets re-published for another 30 seconds after revoke.
      final generation = _deviceMembersCacheGeneration;
      final hex = await deviceGroupIdHex();
      if (generation != _deviceMembersCacheGeneration) continue;
      if (hex == null) return false;
      final now = _now();
      final cached = _deviceMembersCache;
      if (cached != null && now - _deviceMembersCacheAtMs <= 30000) {
        return cached.contains(peer.hex);
      }
      final bundle = await load(NodeId.fromHex(hex));
      final state = bundle == null
          ? null
          : foldControlLog(
              owner: bundle.manifest.owner,
              entries: bundle.control,
              verify: (e) => _validControlFor(bundle.manifest, e),
              initialName: bundle.manifest.name,
            ).state;
      final loaded = {
        for (final member in state?.members.values ?? const <GroupMember>[])
          if (member.nodeId != bundle?.manifest.owner) member.nodeId.hex,
      };
      if (generation != _deviceMembersCacheGeneration) continue;
      _deviceMembersCache = loaded;
      _deviceMembersCacheAtMs = now;
      return loaded.contains(peer.hex);
    }
  }

  Set<String>? _deviceMembersCache;
  int _deviceMembersCacheAtMs = 0;
  int _deviceMembersCacheGeneration = 0;

  void _invalidateDeviceMembersCache() {
    _deviceMembersCache = null;
    _deviceMembersCacheGeneration++;
  }

  void _publishDeviceMembersCache(GroupManifest manifest, GroupState state) {
    _deviceMembersCacheGeneration++;
    _deviceMembersCache = {
      for (final member in state.members.values)
        if (member.nodeId != manifest.owner) member.nodeId.hex,
    };
    _deviceMembersCacheAtMs = _now();
  }

  /// Serializes [postDeviceEvent] appends: sync emits are fire-and-forget
  /// (message taps, settings toggles, journal rows), so two can race the
  /// group log's read-modify-write and the later save silently drops the
  /// earlier append. Caught live in the brick-4 device verify (pin landed,
  /// the same-call archive edit vanished from BOTH devices' folds).
  Future<void> _devicePostChain = Future.value();

  /// Append a sync event to my device group's log (no-op false when no
  /// device group exists yet). Concurrent calls are applied in order.
  ///
  /// [attachment] (brick 4b, lazy attachments): a mirrored FILE message posts
  /// its contentId as a real attachment ref, which puts the cid into
  /// [referencedContentIds] — that is what authorizes my other devices'
  /// membership pull of the bytes. The event body stays the JSON codec.
  Future<bool> postDeviceEvent(
    DeviceSyncEvent e, {
    GroupAttachment? attachment,
  }) {
    final done = _devicePostChain.then((_) async {
      final hex = await deviceGroupIdHex();
      if (hex == null) return false;
      return postMessage(
        NodeId.fromHex(hex),
        e.toBody(),
        attachment: attachment,
      );
    });
    _devicePostChain = done.then((_) {}, onError: (_) {});
    return done;
  }

  /// The folded device-sync state: newest event per (kind, key), from the
  /// VALIDATED device-group log. Empty before adoption.
  Future<Map<(DeviceSyncKind, String), DeviceSyncEvent>>
  deviceSyncState() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return const {};
    final msgs = await messagesOf(NodeId.fromHex(hex));
    return foldDeviceSync([
      for (final m in msgs) ?DeviceSyncEvent.fromBody(m.body),
    ]);
  }

  /// Every validated device-sync row with its signed message author retained.
  /// Most LWW kinds need only [deviceSyncState]; cloud replica claims must also
  /// prove `claimed device == author`, so discarding the author would turn the
  /// group into a replica-count spoofing oracle.
  Future<List<DeviceSyncRecord>> deviceSyncRecords() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return const [];
    final messages = await messagesOf(NodeId.fromHex(hex));
    return [
      for (final message in messages)
        if (DeviceSyncEvent.fromBody(message.body) case final event?)
          (event: event, author: message.author),
    ];
  }

  /// Current non-sovereign members of the device group (including self).
  Future<List<NodeId>> deviceMembers() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return const [];
    final bundle = await load(NodeId.fromHex(hex));
    if (bundle == null) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
    ).state;
    return [
      for (final member in state.members.values)
        if (member.nodeId != bundle.manifest.owner) member.nodeId,
    ];
  }

  /// One-line preview of a validated message for list tiles / notifications.
  static String previewOf(GroupMessage m) {
    if (m.body.isNotEmpty) return m.body;
    switch (m.attachment?.kind) {
      case 'image':
        return '🖼';
      case 'sticker':
        return '😊';
      case 'voice':
        return '🎤';
      case 'vnote':
        return '📹';
    }
    return '…';
  }

  /// Fan the current FULL snapshot of [groupId] out to every OTHER member
  /// (direct delivery, v1). Used to sync a member joining (they need the whole
  /// history). No-op without an injected sender. Returns how many peers it was
  /// shipped to.
  Future<int> broadcast(NodeId groupId) async {
    final send = _send;
    final b = await load(groupId);
    if (send == null || b == null) return 0;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    var n = 0;
    for (final m in state.members.values) {
      if (m.nodeId == _signer.selfId ||
          (b.manifest.isSovereignDevice && m.nodeId == b.manifest.owner)) {
        continue;
      }
      await send(m.nodeId, groupId, snapshotJson(b, recipient: m.nodeId));
      n++;
    }
    return n;
  }

  /// Fan a DELTA (only the just-added entries). Chat messages and reactions go
  /// to the [kGroupSyncNeighbors] XOR-closest members and are relayed across
  /// that sparse overlay. Control changes and device-group events still reach
  /// every member: roster/key changes carry per-recipient epoch material and
  /// cannot safely depend on a relay that does not own everybody's envelope.
  /// A new member still gets a full [broadcast] on join.
  Future<int> broadcastDelta(
    NodeId groupId, {
    List<ControlEntry> control = const [],
    List<GroupMessage> messages = const [],
    List<GroupReaction> reactions = const [],
    List<SpacePost> posts = const [],
    Set<NodeId> exclude = const {},
    String? overlayId,
  }) async {
    final send = _send;
    final b = await load(groupId);
    if (send == null || b == null) return 0;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final channelMessages = messages
        .where((message) => message.isChannelEncrypted)
        .toList();
    final candidates = <NodeId>[
      for (final member in state.members.values)
        if (member.nodeId != _signer.selfId &&
            (!b.manifest.isSovereignDevice ||
                member.nodeId != b.manifest.owner) &&
            (channelMessages.isEmpty ||
                channelMessages.any(
                  (message) => _peerCanDecryptChannelEpoch(
                    b,
                    member.nodeId,
                    message.channelId!,
                    message.channelEpoch!,
                  ),
                )))
          member.nodeId,
    ];
    final sparse = control.isEmpty && b.manifest.name != kDeviceGroupName;
    final neighborCount = sparse
        ? await groupSyncNeighborCount(groupId)
        : kGroupSyncNeighbors;
    final peers = sparse
        ? nearestGroupNodesByXor(_signer.selfId, candidates, k: neighborCount)
        : candidates;
    final deltaId = sparse
        ? (overlayId ?? _overlayDeltaId(groupId, messages, reactions, posts))
        : null;
    if (deltaId != null) _rememberOverlayDelta(deltaId);
    var n = 0;
    for (final peer in peers) {
      if (exclude.contains(peer)) continue;
      final epochEnvelopes = _epochEnvelopesFor(b, peer, controls: control);
      final channelEpochEnvelopes = _channelEpochEnvelopesFor(
        b,
        peer,
        controls: control,
      );
      final encryptionEstablished = _encryptionEstablished(
        b.manifest,
        b.control,
      );
      final peerMessages = [
        for (final message in messages)
          if (_messageWithinLifecycleBoundary(b.manifest, state, message) &&
              (message.isChannelEncrypted
                  ? _peerCanDecryptChannelEpoch(
                      b,
                      peer,
                      message.channelId!,
                      message.channelEpoch!,
                    )
                  : !encryptionEstablished ||
                        (message.isEncrypted &&
                            _peerCanDecryptEpoch(
                              b,
                              peer,
                              message.membershipEpoch!,
                            ))))
            message,
      ];
      final peerReactions = [
        for (final reaction in reactions)
          if (_reactionWithinLifecycleBoundary(state, reaction) &&
              (!encryptionEstablished ||
                  (reaction.isEncrypted &&
                      _peerCanDecryptEpoch(
                        b,
                        peer,
                        reaction.membershipEpoch!,
                      ))))
            reaction,
      ];
      final peerPosts = [
        for (final post in posts)
          if (_postWithinLifecycleBoundary(state, post) &&
              (!post.isEncrypted ||
                  _peerCanDecryptEpoch(b, peer, post.membershipEpoch!)))
            post,
      ];
      await send(
        peer,
        groupId,
        jsonEncode({
          'm': b.manifest.toJson(),
          'c': control.map((entry) => entry.toJson()).toList(),
          'g': peerMessages.map((message) => message.toJson()).toList(),
          'r': peerReactions.map((reaction) => reaction.toJson()).toList(),
          if (peerPosts.isNotEmpty)
            'p': peerPosts.map((post) => post.toJson()).toList(),
          if (epochEnvelopes.isNotEmpty)
            'ke': epochEnvelopes.map((entry) => entry.toJson()).toList(),
          if (channelEpochEnvelopes.isNotEmpty)
            'cke': channelEpochEnvelopes
                .map((entry) => entry.toJson())
                .toList(),
          'ov': ?deltaId,
        }),
      );
      n++;
    }
    return n;
  }

  String _overlayDeltaId(
    NodeId groupId,
    Iterable<GroupMessage> messages,
    Iterable<GroupReaction> reactions, [
    Iterable<SpacePost> posts = const [],
  ]) {
    final identities = <String>[
      for (final message in messages) 'm:${message.author.hex}:${message.seq}',
      for (final reaction in reactions)
        'r:${reaction.author.hex}:${reaction.seq}',
      for (final post in posts) 'p:${post.author.hex}:${post.seq}',
    ]..sort();
    return crypto.sha256
        .convert(utf8.encode('${groupId.hex}|${identities.join('|')}'))
        .toString();
  }

  bool _rememberOverlayDelta(String id) {
    if (!_seenOverlayDeltas.add(id)) return false;
    if (_seenOverlayDeltas.length > _kSeenOverlayDeltaLimit) {
      _seenOverlayDeltas.remove(_seenOverlayDeltas.first);
    }
    return true;
  }

  /// Releases the pure-Dart event surfaces owned by this identity instance.
  /// Hosts must call this before replacing/closing the active identity so a
  /// stale group feed cannot survive an identity switch.
  Future<void> dispose() async {
    _spaceDeletionMaintenanceTimer?.cancel();
    _spaceDeletionMaintenanceTimer = null;
    changes.dispose();
    await _groupCallIncomingCtl.close();
    await _deviceIncomingCtl.close();
    await _incomingCtl.close();
    await _incomingPostCtl.close();
  }
}

class SpaceFeedItem {
  const SpaceFeedItem({
    required this.spaceId,
    required this.spaceName,
    required this.post,
    required this.reactions,
  });

  final NodeId spaceId;
  final String spaceName;
  final SpacePostView post;
  final MessageReactions reactions;
}

/// One row of the user-facing group list (the shape [GroupService.listGroups]
/// returns) — named so the chats screen and providers can share it.
typedef GroupListEntry = ({
  NodeId groupId,
  String name,
  String description,
  SpaceVisibility? visibility,
  SpaceLifecycleState lifecycleState,
  bool discoverable,
  int unread,
  int postUnread,
  bool muted,
  String preview,
  int lastTs,
});
