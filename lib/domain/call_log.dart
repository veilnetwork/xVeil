// Call journal (multi-device epic, brick 4): the persistent record of finished
// calls. Pure domain — entries are stored locally (encrypted settings JSON) and
// ride the device group as `callLog` DeviceSyncEvents keyed by [id], so the
// journal converges across my devices via the same LWW fold as everything else.

import 'call_signal.dart';

/// How a call concluded, from THIS device's point of view. Serialized BY NAME
/// (like DeviceSyncKind) so the set can grow without renumbering.
enum CallLogOutcome {
  /// Media connected; [CallLogEntry.durationSec] holds the talk time.
  completed,

  /// It rang (either way) and nobody ever connected.
  missed,

  /// Explicitly declined (by us for incoming, by the peer for outgoing).
  declined,

  /// The caller gave up before an answer (outgoing cancel).
  cancelled,

  /// The other side was already in a call.
  busy,

  /// Ended by an error / unsupported build before connecting.
  failed;

  static CallLogOutcome? fromName(String? n) {
    for (final o in values) {
      if (o.name == n) return o;
    }
    return null;
  }
}

/// Map a terminal call snapshot to its journal outcome. Pure and shared by the
/// recorder and tests: [connected] = media ever flowed (connectedAt != null).
CallLogOutcome callLogOutcomeFor({
  required bool outgoing,
  required bool connected,
  required CallEndReason reason,
}) {
  if (connected) return CallLogOutcome.completed;
  switch (reason) {
    case CallEndReason.declined:
      return CallLogOutcome.declined;
    case CallEndReason.busy:
      return CallLogOutcome.busy;
    case CallEndReason.cancelled:
      // Outgoing cancel = we hung up while ringing; the same signal received
      // on the callee side means the call was never taken — a missed call.
      return outgoing ? CallLogOutcome.cancelled : CallLogOutcome.missed;
    case CallEndReason.timeout:
    case CallEndReason.hangup:
      return outgoing ? CallLogOutcome.cancelled : CallLogOutcome.missed;
    case CallEndReason.error:
    case CallEndReason.unsupported:
    case CallEndReason.unknown:
      return CallLogOutcome.failed;
    case CallEndReason.answeredElsewhere:
      // The identity DID take this call — on a sibling device. Journal rows
      // converge across devices by callId, so agreeing with the answering
      // device's outcome keeps the merged row honest and single-voiced;
      // "missed" here would tell the user they missed a call they took.
      return CallLogOutcome.completed;
  }
}

/// One journal row. [id] is the callId — the convergence identity across
/// devices (both ends of a device pair log the same call once).
class CallLogEntry {
  const CallLogEntry({
    required this.id,
    required this.peerHex,
    required this.outgoing,
    required this.video,
    required this.outcome,
    required this.atMs,
    this.durationSec = 0,
  });

  final String id;
  final String peerHex;
  final bool outgoing;
  final bool video;
  final CallLogOutcome outcome;

  /// When the call STARTED (ring time), ms since epoch — the journal sort key.
  final int atMs;

  /// Talk time in seconds; 0 unless [outcome] is completed.
  final int durationSec;

  Map<String, dynamic> toJson() => {
        'id': id,
        'peer': peerHex,
        'out': outgoing,
        'vid': video,
        'o': outcome.name,
        'at': atMs,
        if (durationSec > 0) 'dur': durationSec,
      };

  /// Null for anything malformed or from a newer vocabulary — callers skip.
  static CallLogEntry? fromJson(Map<String, dynamic> j) {
    final id = j['id'], peer = j['peer'], at = j['at'];
    final outcome = CallLogOutcome.fromName(j['o'] is String ? j['o'] : null);
    if (id is! String || id.isEmpty || peer is! String || peer.isEmpty) {
      return null;
    }
    if (at is! int || outcome == null) return null;
    return CallLogEntry(
      id: id,
      peerHex: peer,
      outgoing: j['out'] == true,
      video: j['vid'] == true,
      outcome: outcome,
      atMs: at,
      durationSec: j['dur'] is int ? j['dur'] as int : 0,
    );
  }
}
