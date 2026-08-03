// Multi-device epic, brick 1 (doc/MULTIDEVICE-DESIGN.md): the sync-event
// vocabulary that rides the device group's message-log. Pure domain — events
// travel as group-message BODIES (signed per device like any group message),
// so the wire/persistence/admission machinery is the groups foundation as-is.

import 'dart:async';
import 'dart:convert';

import '../core/ids.dart';

/// What a sync event describes. Serialized BY NAME (like ControlOp) so the
/// enum can grow without renumbering.
enum DeviceSyncKind {
  /// A 1:1 message mirrored from the device that sent/received it.
  msgMirror,

  /// A conversation read-watermark (peer + ts).
  readMark,

  /// A contact upsert (alias, per-contact settings).
  contactUp,

  /// An app-level setting (platform-local keys excluded by the caller).
  settingSet,

  /// A call-journal entry.
  callLog,

  /// A logical personal-cloud item (upsert or tombstone). The bytes stay in
  /// the content-addressed store; this is the replicated index row.
  cloudEntry,

  /// One device's claim that it holds and has verified one item cid. The v2
  /// convergence key includes cid so concurrent note heads can coexist.
  /// The applier additionally binds the claimed device id to the message
  /// author, so a member cannot manufacture another device's replica.
  cloudReplica,

  /// Encrypted public-capability registry row or revoke tombstone. The event
  /// travels only inside the sovereign device group; it contains the random
  /// per-share seed/link needed for another owner device to host the same
  /// pseudonymous alias, never in the public DHT advertisement.
  cloudCapability,

  /// A personal-cloud folder (upsert or tombstone). Folders are private
  /// organization of the owner's own index — they carry no content refs and
  /// never leave the sovereign device group. Devices from before this
  /// vocabulary entry skip the kind entirely (unknown-kind events parse to
  /// null), so mixed device groups degrade to a flat view, never to loss.
  cloudFolder;

  static DeviceSyncKind? fromName(String? n) {
    for (final k in values) {
      if (k.name == n) return k;
    }
    return null;
  }
}

/// One sync event. [key] is the event's CONVERGENCE identity within its kind
/// (msgId for mirrors, peer hex for read-marks, setting key, …): the fold
/// keeps the newest event per (kind, key) — deterministic last-write-wins.
class DeviceSyncEvent {
  const DeviceSyncEvent({
    required this.kind,
    required this.key,
    required this.tsMs,
    required this.payload,
  });

  final DeviceSyncKind kind;
  final String key;
  final int tsMs;
  final Map<String, dynamic> payload;

  /// The group-message body this event travels as.
  String toBody() =>
      jsonEncode({'v': 1, 'k': kind.name, 'id': key, 'ts': tsMs, 'p': payload});

  /// Parse a body; null for anything malformed or from a newer vocabulary
  /// (unknown kind) — the applier just skips what it cannot understand.
  static DeviceSyncEvent? fromBody(String body) {
    try {
      final d = jsonDecode(body);
      if (d is! Map) return null;
      final k = d['k'];
      final kind = DeviceSyncKind.fromName(k is String ? k : null);
      final key = d['id'], ts = d['ts'], p = d['p'];
      if (kind == null || key is! String || key.isEmpty || ts is! int) {
        return null;
      }
      return DeviceSyncEvent(
        kind: kind,
        key: key,
        tsMs: ts,
        payload: p is Map ? Map<String, dynamic>.from(p) : const {},
      );
    } catch (_) {
      return null;
    }
  }
}

/// A validated device-group message projected into its sync-event payload and
/// signed author. Author is retained for event kinds (replica claims) whose key
/// must be bound to the device that actually signed the group message.
typedef DeviceSyncRecord = ({DeviceSyncEvent event, NodeId author});

/// Deterministic fold: the NEWEST event per (kind, key) wins; ties break on
/// the jsonEncode of the payload (any stable total order works — devices just
/// have to agree). Order-independent by construction.
Map<(DeviceSyncKind, String), DeviceSyncEvent> foldDeviceSync(
  Iterable<DeviceSyncEvent> events,
) {
  final out = <(DeviceSyncKind, String), DeviceSyncEvent>{};
  for (final e in events) {
    final id = (e.kind, e.key);
    final cur = out[id];
    if (cur == null || _newer(e, cur)) out[id] = e;
  }
  return out;
}

bool _newer(DeviceSyncEvent a, DeviceSyncEvent b) {
  if (a.tsMs != b.tsMs) return a.tsMs > b.tsMs;
  return jsonEncode(a.payload).compareTo(jsonEncode(b.payload)) > 0;
}

/// The fold's ordering, exposed for LIVE appliers: would [a] beat [b] in
/// [foldDeviceSync]? A live guard must use exactly this (not a bare timestamp
/// compare) or same-millisecond edits diverge from what a later re-fold says.
bool isNewerDeviceSync(DeviceSyncEvent a, DeviceSyncEvent b) => _newer(a, b);

/// How far ahead of the RECEIVING device's own clock a sync event may claim to
/// be and still take effect right now.
///
/// The fold above ranks by a timestamp the AUTHOR chose, and every author here
/// is a device the owner linked. A compromised one therefore stamps itself
/// years ahead, wins every key it touches for as long as that lasts — and the
/// log compactor then makes it permanent, because a row that lost its key is
/// deleted from disk on the next pass. Nothing in the group can contradict a
/// clock: there is no time authority in this network and there is not going to
/// be one.
///
/// So the bound is a DEFERRAL, never a rejection. A row that is not effective
/// yet stays in the log, loses no key, and starts winning the moment wall clock
/// reaches it. A device that is honestly a few minutes fast loses nothing, and
/// what the attacker loses is the word "forever": a future stamp buys at most
/// [kDeviceSyncClockSkew] of suppression past the moment it is read, not the
/// rest of the identity's life.
///
/// Five minutes is the same tolerance the public-space carriers already apply
/// to a stranger's `issuedAt` (`kSpacePublicClockSkew`) — one skew convention
/// in the project, not a second one.
const Duration kDeviceSyncClockSkew = Duration(minutes: 5);

/// Whether [event] may take effect on a device whose wall clock reads [nowMs].
///
/// Deliberately a predicate over a caller-supplied clock rather than a call to
/// [DateTime.now]: every path that turns log rows into effective state has a
/// clock already (the group service's `_now`, the applier's injected one), and
/// a shared predicate is what keeps them from drifting into three rules.
bool deviceSyncEffectiveAt(DeviceSyncEvent event, int nowMs) =>
    event.tsMs <= nowMs + kDeviceSyncClockSkew.inMilliseconds;

/// The rules a LIVE applier needs, which a re-fold of the whole log gets for
/// free — held in one place because a streaming applier has to reproduce them
/// by hand and got them wrong in three different ways.
///
/// * Newest-wins per (kind, key), ranked by exactly [isNewerDeviceSync]. A bare
///   timestamp compare disagrees with [foldDeviceSync] on same-millisecond
///   ties, so the live view and a later re-fold would drift apart.
/// * Nothing takes effect before its own timestamp ([deviceSyncEffectiveAt]).
/// * A slot moves only for events that were actually APPLIED. This is why
///   [offer] takes a plan rather than a decision: an applier that marks its
///   progress first and validates second lets a refused event leave a
///   watermark behind, and every honest event ranked below that watermark is
///   then dropped without ever being looked at.
class DeviceSyncApplyGate {
  /// [nowMs] is the reading device's wall clock — injected so tests can hold
  /// it still rather than race it.
  DeviceSyncApplyGate({int Function()? nowMs})
    : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;

  /// Slot -> the newest event actually applied to it.
  final Map<String, DeviceSyncEvent> _applied = {};

  /// The convergence identity an event competes for: its (kind, key) pair, the
  /// same one [foldDeviceSync] folds on.
  static String slotOf(DeviceSyncEvent event) =>
      '${event.kind.name}|${event.key}';

  /// Offer [event] to the applier.
  ///
  /// [plan] is called only if the event is effective and beats what this slot
  /// last applied. It validates the event and returns the work to do, or null
  /// to REFUSE it — a refused event changes nothing at all, so the honest event
  /// behind it is still judged against the last thing that really landed.
  ///
  /// Returns whether the work was accepted.
  bool offer(DeviceSyncEvent event, Future<void> Function()? Function() plan) {
    if (!deviceSyncEffectiveAt(event, _now())) return false;
    final slot = slotOf(event);
    final applied = _applied[slot];
    if (applied != null && !isNewerDeviceSync(event, applied)) return false;
    final run = plan();
    if (run == null) return false;
    _applied[slot] = event;
    unawaited(run());
    return true;
  }
}
