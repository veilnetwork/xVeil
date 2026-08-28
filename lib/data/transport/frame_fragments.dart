// Splitting peer-to-peer app frames that are too big for the wire.
//
// WHY THIS EXISTS. A direct app frame above roughly 1.6 KB never arrives.
// Measured between two real devices on 2026-08-07: 1500 B of message text
// arrives, 1600 B does not, with the 1500 B control repeated on BOTH sides of
// every failing probe so the result cannot be blamed on the moment it ran.
// Nothing reports the loss — `veil_send` returns OK because the IPC write to
// the local node succeeded, and the frame dies somewhere past that point. The
// sender's outbox then retries the same oversized frame forever.
//
// What that cost: a content chunk is ~5.6 KB on the wire, so NOT ONE chunk of
// any file could ever arrive. Photos, voice messages and video notes were
// undeliverable by construction while short text messages worked, which is
// exactly what a user sees and cannot explain.
//
// So this layer does what a transport is supposed to do with an MTU it cannot
// change: split what is too big, put it back together on the far side, and
// refuse LOUDLY what cannot be split at all. The limit below is deliberately
// far under the measured cliff — the mechanism behind that cliff was never
// pinned down, and a limit chosen to sit just inside an unexplained boundary is
// a limit that breaks on the first network with a smaller MTU.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/ids.dart';
import '../../core/log.dart';

/// Total bytes this app will hand the transport in one frame.
///
/// Measured good: 1583 B. Measured lost: 1683 B. This sits under the IPv6
/// minimum MTU (1280) rather than just under the measured cliff, because the
/// cliff's cause is not understood and 1583 is only known to work on the one
/// pair of devices and the one network it was measured on.
const int kMaxFrameBytes = 1200;

/// Gap left between the fragments of one payload.
///
/// Frames sent back to back to the same peer do not survive — measured: one
/// 1481 B frame arrives, three consecutive 1200 B frames produce not a single
/// arrival, with small frames flowing normally in the same window. Separate
/// messages sent in a burst DO eventually arrive, but only on their outbox
/// retries, which are spaced seconds apart; fragments have no retry of their
/// own, so a burst loses them for good.
const Duration kFragmentPacing = Duration(milliseconds: 120);

/// `'XVF1'` — marks a frame as carrying a fragment rather than a whole payload.
const List<int> kFragmentMagic = [0x58, 0x56, 0x46, 0x31];

/// magic(4) + frameId(8) + total(2) + index(2).
const int kFragmentHeaderBytes = 16;

/// Payload bytes carried by one fragment.
const int kFragmentDataBytes = kMaxFrameBytes - kFragmentHeaderBytes;

/// Largest payload this layer will carry.
///
/// `total` and `index` are 16-bit, so the HEADER can address 65535 fragments —
/// about 77 MB. That is not a payload this app has any business assembling:
/// veil refuses to carry more than 1 MiB in one envelope (`MAX_ENVELOPE_PAYLOAD`),
/// so anything larger could never have been delivered whole in the first place
/// and can only be a peer spending our memory. Both sides are held to the same
/// figure: the sender refuses to split beyond it, the receiver refuses to
/// assemble beyond it.
const int kMaxFragmentedPayloadBytes = 1024 * 1024;

/// Fragments one payload may be cut into, given the ceiling above.
const int kMaxFragmentsPerPayload =
    (kMaxFragmentedPayloadBytes + kFragmentDataBytes - 1) ~/ kFragmentDataBytes;

/// Bytes every half-arrived payload may hold TOGETHER.
///
/// Counting SETS bounds nothing on its own, and that was the hole: 64 sets of
/// 65535 fragments is roughly five gigabytes, held for the whole TTL, and a
/// fragment costs the peer one small frame to send. Nothing authenticates a
/// fragment header either — four magic bytes are all it takes — so the sender
/// of the first fragment is not necessarily anyone we know. Bytes are the
/// resource, so bytes are what is bounded.
const int kMaxHeldFragmentBytes = 4 * 1024 * 1024;

/// A payload too large to fragment. Thrown rather than dropped: the whole
/// reason this file exists is that an undeliverable frame used to vanish
/// without a word.
class FrameTooLargeError implements Exception {
  const FrameTooLargeError(this.length);

  final int length;

  @override
  String toString() =>
      'FrameTooLargeError: $length B exceeds the largest fragmentable frame '
      '($kMaxFragmentedPayloadBytes B)';
}

/// True when [payload] cannot travel as a single frame.
///
/// A payload that merely LOOKS like a fragment must be wrapped too, however
/// short it is — otherwise the receiver would have to guess whether four
/// leading bytes are a header or the message itself, and this way it never has
/// to guess.
bool needsFragmenting(Uint8List payload) =>
    payload.length > kMaxFrameBytes || _startsWithMagic(payload);

/// Split [payload] into wire frames, each at most [kMaxFrameBytes] long.
///
/// Returns the payload untouched (single element) when it fits and cannot be
/// mistaken for a fragment, so ordinary short messages pay nothing.
///
/// The frame id is derived from the payload's own hash, which makes a RETRY
/// carry the same id as the original. That is the difference between retries
/// that accumulate and retries that start over: when one fragment of six is
/// lost, the receiver keeps the five it holds and the retry only has to land
/// the missing one. Nothing acknowledges individual fragments, so the sender
/// cannot know which one to resend — it resends all of them, and the receiver's
/// bookkeeping is what turns that into progress.
List<Uint8List> fragmentFrame(Uint8List payload) {
  if (!needsFragmenting(payload)) return [payload];
  if (payload.length > kMaxFragmentedPayloadBytes) {
    throw FrameTooLargeError(payload.length);
  }
  final id = frameIdOf(payload);
  final total = payload.isEmpty
      ? 1
      : (payload.length + kFragmentDataBytes - 1) ~/ kFragmentDataBytes;
  final out = <Uint8List>[];
  for (var i = 0; i < total; i++) {
    final start = i * kFragmentDataBytes;
    final end = start + kFragmentDataBytes < payload.length
        ? start + kFragmentDataBytes
        : payload.length;
    final frame = Uint8List(kFragmentHeaderBytes + (end - start));
    frame.setRange(0, 4, kFragmentMagic);
    frame.setRange(4, 12, id);
    frame[12] = (total >> 8) & 0xff;
    frame[13] = total & 0xff;
    frame[14] = (i >> 8) & 0xff;
    frame[15] = i & 0xff;
    frame.setRange(kFragmentHeaderBytes, frame.length, payload, start);
    out.add(frame);
  }
  return out;
}

/// The first 8 bytes of the payload's SHA-256 — stable across retries of the
/// same payload, and distinct across different ones.
Uint8List frameIdOf(Uint8List payload) =>
    Uint8List.fromList(sha256.convert(payload).bytes.sublist(0, 8));

/// One parsed fragment. `null` from [parseFragment] means "not a fragment" —
/// an ordinary whole payload that must be delivered as it is.
class InboundFragment {
  const InboundFragment({
    required this.frameId,
    required this.total,
    required this.index,
    required this.data,
  });

  final Uint8List frameId;
  final int total;
  final int index;
  final Uint8List data;

  String get key => _hex(frameId);
}

/// Read a fragment header, or return null when [frame] is a whole payload.
///
/// Every field is checked against the others before the frame is believed:
/// a header claiming an index outside its own total, or a zero total, is not a
/// header this app wrote.
InboundFragment? parseFragment(Uint8List frame) {
  if (frame.length < kFragmentHeaderBytes) return null;
  if (!_startsWithMagic(frame)) return null;
  final total = (frame[12] << 8) | frame[13];
  final index = (frame[14] << 8) | frame[15];
  if (total == 0 || index >= total) return null;
  return InboundFragment(
    frameId: Uint8List.sublistView(frame, 4, 12),
    total: total,
    index: index,
    data: Uint8List.sublistView(frame, kFragmentHeaderBytes),
  );
}

bool _startsWithMagic(Uint8List b) {
  if (b.length < kFragmentMagic.length) return false;
  for (var i = 0; i < kFragmentMagic.length; i++) {
    if (b[i] != kFragmentMagic[i]) return false;
  }
  return true;
}

String _hex(Uint8List b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

/// Holds fragments until their payload is whole again.
///
/// Bounded on purpose, and bounded in BYTES. A peer that sends first-fragments
/// and never finishes them must not be able to grow this table, so a set is
/// dropped once it is idle past [ttl], the oldest set goes when [maxSets] is
/// reached, and — the part that was missing — no fragment is kept once the
/// bytes held would pass [maxPayloadBytes] for one payload or [maxHeldBytes]
/// across all of them. Counting sets alone left the size of a set unbounded,
/// which is the whole of the resource.
///
/// Silence is what made the original defect invisible, so every refusal and
/// every eviction says out loud what was dropped and why.
class FragmentReassembler {
  FragmentReassembler({
    this.ttl = const Duration(minutes: 2),
    this.maxSets = 64,
    this.maxPayloadBytes = kMaxFragmentedPayloadBytes,
    this.maxHeldBytes = kMaxHeldFragmentBytes,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final int maxSets;

  /// Bytes one half-arrived payload may hold.
  final int maxPayloadBytes;

  /// Bytes all half-arrived payloads may hold together.
  final int maxHeldBytes;

  final DateTime Function() _now;

  final Map<String, _PendingSet> _sets = {};

  /// Running sum of `_sets.values.heldBytes`, kept in step with every insert,
  /// overwrite and removal rather than recomputed: a walk of the table on each
  /// arriving fragment is exactly the cost a flood would be paying us to spend.
  int _heldBytes = 0;

  /// Feed one inbound frame. Returns the complete payload when [frame] was the
  /// last missing piece, the frame itself when it was never a fragment, and
  /// null while a payload is still incomplete — or when the fragment was
  /// refused.
  Uint8List? accept(NodeId src, Uint8List frame) {
    final fragment = parseFragment(frame);
    if (fragment == null) return frame;
    _expire();
    final key = '${src.hex}/${fragment.key}';

    // A total this side would never produce. Refused at the FIRST fragment,
    // before a set exists for it: an index near 65535 arriving first is what
    // makes a set expensive, and there is nothing to learn by holding it.
    if (fragment.total > kMaxFragmentsPerPayload) {
      devLog(
        () =>
            'xVeil[frag]: REFUSED $key — claims ${fragment.total} fragments, '
            'the most a payload may be cut into is $kMaxFragmentsPerPayload',
      );
      return null;
    }

    var target = _sets[key];
    // Evict BEFORE inserting, never from inside the insert: mutating the map
    // while it is being written to is undefined.
    if (target == null && _sets.length >= maxSets) _dropOldest();
    if (target == null || target.total != fragment.total) {
      // Absent, or two different payloads whose ids collided / a corrupted
      // header. The newer claim wins: an id is derived from content, so the
      // one that keeps arriving is the one worth assembling.
      if (target != null) _forget(key, 'replaced by a set of a different size');
      target = _PendingSet(fragment.total, _now());
      _sets[key] = target;
    }

    final part = Uint8List.fromList(fragment.data);
    // A retry resends EVERY fragment, so an index arriving twice is the normal
    // case, not the odd one. What it replaces has to leave the accounting or
    // the budget drains on ordinary traffic.
    final replaced = target.parts[fragment.index]?.length ?? 0;
    final growth = part.length - replaced;

    if (target.heldBytes + growth > maxPayloadBytes) {
      _forget(
        key,
        'one payload would hold ${target.heldBytes + growth} B, '
        'over the $maxPayloadBytes B a payload may hold',
      );
      return null;
    }

    // Room for it globally, taken from the sets least likely to complete.
    while (_heldBytes + growth > maxHeldBytes && _dropOldestExcept(key)) {}
    if (_heldBytes + growth > maxHeldBytes) {
      _forget(
        key,
        'no room: ${_heldBytes + growth} B would be held, '
        'over the $maxHeldBytes B budget',
      );
      return null;
    }

    target.put(fragment.index, part);
    _heldBytes += growth;
    target.touchedAt = _now();
    devLog(
      () =>
          'xVeil[frag]: fragment ${fragment.index + 1}/${fragment.total} '
          '(${fragment.data.length}B) of $key — '
          '${target!.parts.length}/${target.total} held, '
          '$_heldBytes B in the table',
    );
    if (target.parts.length != target.total) return null;
    _heldBytes -= target.heldBytes;
    _sets.remove(key);
    return target.join();
  }

  /// Number of payloads currently half-arrived — for tests and diagnostics.
  int get pendingSets => _sets.length;

  /// Bytes currently held by half-arrived payloads — for tests and diagnostics.
  int get heldBytes => _heldBytes;

  /// Drop the set at [key], saying why, and give its bytes back to the budget.
  void _forget(String key, String why) {
    final gone = _sets.remove(key);
    if (gone == null) return;
    _heldBytes -= gone.heldBytes;
    devLog(
      () =>
          'xVeil[frag]: DROPPED incomplete frame $key — '
          '${gone.parts.length}/${gone.total} fragments, $why',
    );
  }

  void _expire() {
    final cutoff = _now().subtract(ttl);
    for (final key in _sets.entries
        .where((e) => e.value.touchedAt.isBefore(cutoff))
        .map((e) => e.key)
        .toList()) {
      _forget(key, 'incomplete after ${ttl.inSeconds}s');
    }
  }

  void _dropOldest() => _dropOldestExcept(null);

  /// Drop the least recently touched set other than [keep]. False when there
  /// was none to drop, which is what stops the caller's loop.
  bool _dropOldestExcept(String? keep) {
    String? oldestKey;
    DateTime? oldest;
    _sets.forEach((key, set) {
      if (key == keep) return;
      if (oldest == null || set.touchedAt.isBefore(oldest!)) {
        oldest = set.touchedAt;
        oldestKey = key;
      }
    });
    final key = oldestKey;
    if (key == null) return false;
    _forget(key, 'reassembly table full ($maxSets sets, $maxHeldBytes B)');
    return true;
  }
}

class _PendingSet {
  _PendingSet(this.total, this.touchedAt);

  final int total;
  DateTime touchedAt;
  final Map<int, Uint8List> parts = {};

  /// Bytes this set holds. Maintained by [put] so the table never has to be
  /// walked to answer it.
  int heldBytes = 0;

  void put(int index, Uint8List part) {
    heldBytes -= parts[index]?.length ?? 0;
    parts[index] = part;
    heldBytes += part.length;
  }

  Uint8List join() {
    var length = 0;
    for (var i = 0; i < total; i++) {
      length += parts[i]!.length;
    }
    final out = Uint8List(length);
    var at = 0;
    for (var i = 0; i < total; i++) {
      final part = parts[i]!;
      out.setRange(at, at + part.length, part);
      at += part.length;
    }
    return out;
  }
}
