// What one of my devices asks another of my devices to send it.
//
// Linking a device signs it into the registry and starts FORWARD sync: from
// that moment the two devices converge, and everything from before stays where
// it was. That is a real answer for a second phone and the wrong one for a
// replacement — a person who set a new device up expects to open it and find
// their conversations, and scenario 5 of the multi-device campaign measured
// exactly that gap: a freshly linked device shows an empty history with nothing
// on screen to say why.
//
// The scope is the PERSON'S to choose, up to a full copy. This type is what
// they chose, as it travels: one device raises it, one device answers it, and
// everything it can ask for is already in the device-sync vocabulary, so the
// answer is the same events an online sibling would have sent anyway.

import 'device_sync.dart';

/// The scope of a history request, as it rides the device group.
///
/// Absence means "everything" for the two narrowing fields, so the smallest
/// possible payload is the largest possible request — a full copy is the
/// default shape, and a narrower one has to say so.
class DeviceHistoryAsk {
  const DeviceHistoryAsk({
    required this.fromDeviceHex,
    this.peers,
    this.perConversation,
    this.callLog = true,
    this.readMarks = true,
    this.files = true,
  });

  /// The device being asked. Every other device sees this event too — the
  /// device group is a broadcast log — and every other device must ignore it.
  final String fromDeviceHex;

  /// The conversations wanted, by peer hex; null asks for every one of them.
  final List<String>? peers;

  /// At most this many messages per conversation, newest first; null asks for
  /// all of them.
  final int? perConversation;

  /// The call journal. Small, and a journal with holes in it is worse than
  /// useless for the one thing people read it for.
  final bool callLog;

  /// Where each conversation was read to. Small, and without it a filled
  /// history arrives entirely unread.
  final bool readMarks;

  /// File messages travel with the reference that authorizes the pull of their
  /// bytes. Off, they still travel — as the rows they are, without the bytes —
  /// because a conversation missing every picture is still the conversation.
  final bool files;

  /// Contacts and their statuses are NOT a choice.
  ///
  /// They are what the messaging layer decides consent with, not a
  /// convenience: a device that has the messages of a conversation and not the
  /// contact behind it refuses the next message that arrives in it, and — until
  /// F54 — deleted that message from the mailbox for the rest of the family
  /// while doing so. Correctness, so it is not offered as a checkbox.
  bool get contacts => true;

  Map<String, dynamic> toPayload() => {
    'from': fromDeviceHex,
    if (peers != null) 'peers': peers,
    if (perConversation != null) 'n': perConversation,
    if (!callLog) 'calls': false,
    if (!readMarks) 'reads': false,
    if (!files) 'files': false,
  };

  /// Null for anything a device of this vocabulary cannot act on. A request
  /// that does not name a target is not a narrower request, it is a broadcast
  /// demand that every device would answer at once.
  static DeviceHistoryAsk? fromPayload(Map<String, dynamic> p) {
    final from = p['from'];
    if (from is! String || from.isEmpty) return null;
    final rawPeers = p['peers'];
    final peers = rawPeers is List
        ? [
            for (final e in rawPeers)
              if (e is String && e.isNotEmpty) e,
          ]
        : null;
    // An EMPTY list asked for is a request for nothing, which no screen can
    // produce and no device should guess at. Refused rather than widened: the
    // widening would send a full copy on the strength of a malformed field.
    if (peers != null && peers.isEmpty) return null;
    final n = p['n'];
    return DeviceHistoryAsk(
      fromDeviceHex: from,
      peers: peers,
      perConversation: n is int && n > 0 ? n : null,
      callLog: p['calls'] != false,
      readMarks: p['reads'] != false,
      files: p['files'] != false,
    );
  }

  /// Whether [deviceHex] is the device this asks.
  bool asks(String deviceHex) => deviceHex == fromDeviceHex;

  /// The device-group event that carries this ask.
  ///
  /// Keyed by the device DOING the asking, so the log keeps one row per device
  /// rather than one per press — and so the answering side can tell an ask it
  /// has already served from a fresh one by its timestamp alone.
  DeviceSyncEvent toEvent({required String byDeviceHex, required int tsMs}) =>
      DeviceSyncEvent(
        kind: DeviceSyncKind.historyAsk,
        key: byDeviceHex,
        tsMs: tsMs,
        payload: toPayload(),
      );
}

/// What a replay actually sent, so the screen that asked can say so.
class DeviceHistoryReplay {
  const DeviceHistoryReplay({
    required this.conversations,
    required this.messages,
    required this.contacts,
    required this.calls,
    required this.readMarks,
    this.stoppedEarly = false,
  });

  final int conversations;
  final int messages;
  final int contacts;
  final int calls;
  final int readMarks;

  /// True when the walk was cut short — cancelled, or the identity switched
  /// under it. Reported rather than hidden: a partial copy that claims to be
  /// whole is the failure this whole campaign keeps finding.
  final bool stoppedEarly;

  int get events => messages + (contacts * 2) + calls + readMarks;
}
