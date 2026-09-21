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

  /// How far one of MY OWN outgoing messages has got — sent, delivered,
  /// failed. Keyed by the message id.
  ///
  /// NOT folded into [msgMirror], although it is about the same message: a
  /// mirror's timestamp is the MESSAGE's own time, which is where the chat
  /// puts it on screen. Re-posting a mirror to carry a newer status would have
  /// to stamp it later to win the fold, and the message would jump in the
  /// conversation every time a tick arrived.
  ///
  /// Only the sending device learns this — the acknowledgement comes back to
  /// it alone — so without an event of its own a sibling shows the message at
  /// the status it was stored with and never moves. Reported by the owner:
  /// a message sent from one device stayed on one tick on the other while the
  /// sender showed two.
  msgStatus,

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

  /// One device's signed identity document, announced to the others.
  ///
  /// The event that makes several devices ONE identity rather than several
  /// nodes wearing the same name. Devices set up from the same master phrase
  /// each start with a document naming only themselves while all of them derive
  /// the same node_id — it is BLAKE3 of that master key. Every one of them
  /// publishes under that id, the last publisher displaces the rest, and the
  /// displaced devices stay online believing they are reachable. Announcing the
  /// document lets whoever receives it merge: append itself if it is not named,
  /// adopt if it is.
  ///
  /// Keyed by the ANNOUNCING device, so each device owns its own row and two
  /// announcements never overwrite one another.
  identityDoc,

  /// One device asking another for the history it was linked too late to see.
  ///
  /// NOT a piece of state, unlike every kind above it — a COMMAND, and the one
  /// event in this vocabulary that asks a device to do something rather than
  /// telling it something. It is keyed by the ASKING device so the log holds
  /// one row per device rather than one per press, and the device it names
  /// answers with ordinary events of the kinds above: the receiving side needs
  /// no new applier, because a replayed mirror is the same mirror a sibling
  /// that had been online would have sent.
  ///
  /// Being a command, it needs its own idempotence. The folded state is
  /// replayed into the appliers on every bridge build, so an answered ask that
  /// left no record would be answered again on every app start; the answering
  /// device therefore keeps a durable watermark per asking device.
  historyAsk,

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
/// * One slot applies serially; slots apply in parallel. Deciding an order and
///   then starting the work concurrently decides nothing — the applies are
///   read-modify-write against storage, so whichever finishes last is what the
///   user gets, which is not the same thing as whichever event is newest.
class DeviceSyncApplyGate {
  /// [nowMs] is the reading device's wall clock — injected so tests can hold
  /// it still rather than race it.
  DeviceSyncApplyGate({int Function()? nowMs})
    : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;

  /// Slot -> the newest event actually applied to it.
  final Map<String, DeviceSyncEvent> _applied = {};

  /// The last event for a slot whose write actually SUCCEEDED.
  ///
  /// [_applied] is the admission watermark: it moves before the work runs,
  /// because admission has to be decided in one go. That makes it the wrong
  /// thing for a failure to fall back to — the entry it displaced may be an
  /// event that is also still in flight, or one that has already failed
  /// (report27 X07).
  final Map<String, DeviceSyncEvent> _committed = {};

  /// How many queued writes threw.
  ///
  /// A failed apply is survivable — it must not poison the slot behind it —
  /// but it is not nothing, and the gate used to swallow it whole: `settle`
  /// returned normally and a caller standing in front of a screen was told
  /// the merge was done (report27 X06).
  int _failedApplies = 0;

  /// Writes that threw since this gate was made. Non-zero means part of what
  /// was offered is NOT on disk.
  int get failedApplies => _failedApplies;

  /// Slot -> the tail of that slot's apply chain, present only while work for
  /// it is outstanding. Deliberately per slot and not one chain for everything:
  /// a single chain would make a slow contact write hold up an unrelated
  /// setting, and a catch-up burst arrives as hundreds of unrelated slots.
  final Map<String, Future<void>> _chains = {};

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
  /// The work runs after everything already queued for the SAME slot and
  /// alongside every other slot, so two events that both beat the guard land in
  /// the order the guard admitted them.
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
    final queued = (_chains[slot] ?? Future<void>.value())
        .then((_) => run())
        // A failed apply must not poison the slot for everything behind it —
        // and must not be REMEMBERED as applied either. The watermark is moved
        // above, before the work runs, because admission has to be decided in
        // one go; if the work then throws, this puts it back.
        //
        // The old comment claimed a later re-fold would retry. It does not:
        // a re-fold offers the SAME event, which loses to the watermark this
        // very failure left behind, so one transient write error froze that
        // slot — a contact status, a setting, a read mark — for the life of
        // the gate, while everything reported success (report24 CH-M3).
        //
        // Restored only if nothing NEWER was admitted meanwhile: rolling that
        // back would let an older event win a race it already lost.
        .then((_) {
          // WHAT ACTUALLY LANDED, kept apart from what was admitted. The
          // rollback below restores this, not the admission it displaced.
          _committed[slot] = event;
        })
        .catchError((Object _) {
          _failedApplies += 1;
          if (!identical(_applied[slot], event)) return;
          // NOT `previous`. Two events for one slot are admitted before
          // either writes, so `previous` can be an event that is ALSO still
          // pending — and when both writes failed, the second one's rollback
          // restored the first as though it had landed. A retry of that first
          // event then lost to a watermark set by its own failure, and the
          // slot kept an applied-mark for a write that never happened
          // (report27 X07). The last COMMIT is the only thing a failure may
          // fall back to.
          final landed = _committed[slot];
          if (landed == null) {
            _applied.remove(slot);
          } else {
            _applied[slot] = landed;
          }
        });
    _chains[slot] = queued;
    unawaited(
      queued.whenComplete(() {
        // Only the slot's CURRENT tail may clear it — anything queued behind
        // this one has already replaced the entry and is still to run.
        if (identical(_chains[slot], queued)) _chains.remove(slot);
      }),
    );
    return true;
  }

  /// Test seam: slots with work still outstanding. A drained gate must report
  /// zero — the chains are per key, so leaving them behind would grow a map
  /// entry per conversation, setting and journal row for the bridge's lifetime.
  int get pendingSlots => _chains.length;

  /// Wait for everything admitted so far to finish.
  ///
  /// [offer] returns as soon as it has DECIDED — the write itself is queued
  /// behind that slot's own chain. For the live stream that is the right
  /// shape: nobody is waiting. An offline import is the other case: a person
  /// is standing in front of a screen that will say "merged", and saying it
  /// while the writes are still queued makes the word mean nothing.
  ///
  /// Loops because a chain may enqueue behind itself while being awaited; the
  /// bound is there so a slot that somehow keeps refilling cannot hold the
  /// caller forever.
  Future<void> settle({int rounds = 64}) async {
    for (var i = 0; i < rounds && _chains.isNotEmpty; i++) {
      await Future.wait(List<Future<void>>.of(_chains.values));
    }
  }
}
