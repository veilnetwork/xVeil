/// The convergence oracle: given what two devices of ONE identity hold, decide
/// whether they agree.
///
/// ## Why this is its own file, with its own unit test
///
/// Every case in the multi-device campaign ends in the same question — "did A
/// and B end up in the same state?" — and every case answers it with this
/// function. A broken oracle therefore does not fail one case; it silently
/// passes all of them. So the oracle is deliberately:
///
///   * PURE — plain data in, verdict out. No FFI, no storage, no clock. It
///     imports nothing from `lib/`, which is what lets
///     `convergence_oracle_test.dart` run under an ordinary `flutter test`
///     with no dylib and no relay, on every commit;
///   * SEPARATELY BROKEN — the unit test next to it feeds it disagreeing
///     snapshots and demands a NO. That is the check that a change which makes
///     the oracle say YES to everything is caught by the suite that runs
///     everywhere, not by the gated suite nobody runs.
///
/// ## What "agree" means here
///
/// The campaign's own criterion, in three parts (see
/// `artifacts/multi-device-campaign-2026-08-16.md`):
///
///   1. the DEVICE-GROUP BUNDLE DIGEST is equal. The digest covers exactly the
///      signed, shared rows — control entries and messages — and deliberately
///      NOT the per-device local fold state (`localEpochKeys`, `*Receipts`,
///      `retentionCuts`), which the design says diverges by construction: an
///      envelope is minted per recipient and a receipt records the LOCAL
///      moment a row arrived. An oracle that hashed those would report every
///      healthy pair as divergent;
///   2. NO DUPLICATES — one `(author, seq)` appears once. The class of defect
///      this catches has been seen live twice (`one-file-two-rows`): the same
///      logical row landing twice under two keys;
///   3. NO GAPS — each writer's `seq` chain is contiguous. This is the
///      per-writer frontier the campaign had to introduce (`9cbe6a4`): a flat
///      frontier collapsed several writers' chains into one and lost rows in
///      the middle, which a digest comparison alone cannot see when BOTH
///      devices lost the same rows.
///
/// Parts 2 and 3 are checked per device, not between devices. That is on
/// purpose: two devices that are identically broken still fail, because the
/// question a campaign case asks is "are they both right", and equality alone
/// answers only half of it.
library;

/// One signed row of a device-group bundle, identified the way the fold
/// identifies it: by its writer and that writer's sequence number.
///
/// `kind` separates the two chains (control / message) because they are
/// numbered independently — a control row 7 and a message row 7 by the same
/// author are not a duplicate pair.
class RowRef implements Comparable<RowRef> {
  const RowRef({required this.kind, required this.authorHex, required this.seq});

  final String kind;
  final String authorHex;
  final int seq;

  @override
  bool operator ==(Object other) =>
      other is RowRef &&
      other.kind == kind &&
      other.authorHex == authorHex &&
      other.seq == seq;

  @override
  int get hashCode => Object.hash(kind, authorHex, seq);

  @override
  int compareTo(RowRef other) {
    final byKind = kind.compareTo(other.kind);
    if (byKind != 0) return byKind;
    final byAuthor = authorHex.compareTo(other.authorHex);
    if (byAuthor != 0) return byAuthor;
    return seq.compareTo(other.seq);
  }

  @override
  String toString() => '$kind/${_short(authorHex)}#$seq';
}

/// Everything the oracle is allowed to look at, read off ONE device.
///
/// A plain value object, and deliberately not a view onto a live
/// [GroupService]: the fixture takes the reading, this file judges it. That
/// split is what makes a failure printable — the harness can dump the two
/// snapshots into the failure message and a human can see WHICH row differs
/// without re-running anything.
class DeviceStateSnapshot {
  const DeviceStateSnapshot({
    required this.label,
    required this.deviceGroupIdHex,
    required this.bundleDigest,
    required this.rows,
    this.conversationMessageIds = const [],
    this.memberCount = 0,
    this.epoch = 0,
    this.notes = const {},
  });

  /// Which device this reading came from ('A', 'B', …) — carried so a verdict
  /// can name the disagreeing side rather than say "they differ".
  final String label;

  /// The device group this identity's devices share, or null when this device
  /// has no device group at all (never linked, or the pointer was cleared).
  final String? deviceGroupIdHex;

  /// Digest over the SHARED rows of the device-group bundle. See the library
  /// doc for what is deliberately excluded.
  final String bundleDigest;

  /// Every signed row, so duplicates and gaps are decidable without the
  /// bundle itself.
  final List<RowRef> rows;

  /// Message ids in a specific 1:1 conversation, in storage order. Used by the
  /// cases that assert "the message appears exactly once", which is a claim
  /// about the CONVERSATION, not about the device group.
  final List<String> conversationMessageIds;

  final int memberCount;
  final int epoch;

  /// Free-form diagnostics the fixture wants carried into a failure message
  /// (queue depths, last-seen ages). Never compared.
  final Map<String, Object?> notes;

  @override
  String toString() =>
      '$label{group=${_short(deviceGroupIdHex ?? "none")} '
      'digest=${_short(bundleDigest)} rows=${rows.length} '
      'members=$memberCount epoch=$epoch '
      'conv=${conversationMessageIds.length}}';
}

/// The oracle's answer. Never a bare bool: a "no" that cannot say what
/// disagreed costs a re-run to find out, and a re-run of a live multi-device
/// case is minutes.
class ConvergenceVerdict {
  const ConvergenceVerdict({required this.agree, required this.reasons});

  final bool agree;
  final List<String> reasons;

  String describe() =>
      agree ? 'converged' : 'DIVERGED:\n  - ${reasons.join('\n  - ')}';

  @override
  String toString() => describe();
}

/// Decide whether [a] and [b] — two devices of ONE identity — agree.
///
/// [requireDeviceGroup] is on by default because in this campaign two devices
/// of one identity always share a device group; a pair that has none is not
/// "trivially converged", it is unlinked. A caller that genuinely wants to
/// compare two unlinked devices (there is no such case today) must say so.
ConvergenceVerdict convergenceOf(
  DeviceStateSnapshot a,
  DeviceStateSnapshot b, {
  bool requireDeviceGroup = true,
  bool requireConversationAgreement = false,
}) {
  final reasons = <String>[];

  // --- per device: no duplicates, no gaps -----------------------------------
  for (final device in [a, b]) {
    reasons.addAll(_duplicateReasons(device));
    reasons.addAll(_gapReasons(device));
  }

  // --- between devices ------------------------------------------------------
  if (requireDeviceGroup &&
      (a.deviceGroupIdHex == null || b.deviceGroupIdHex == null)) {
    reasons.add(
      'device group missing: ${a.label}=${a.deviceGroupIdHex ?? "none"} '
      '${b.label}=${b.deviceGroupIdHex ?? "none"} — the devices are not '
      'linked, so there is nothing for them to agree about',
    );
  } else if (a.deviceGroupIdHex != b.deviceGroupIdHex) {
    reasons.add(
      'different device groups: ${a.label}=${_short(a.deviceGroupIdHex)} '
      '${b.label}=${_short(b.deviceGroupIdHex)}',
    );
  }

  if (a.bundleDigest != b.bundleDigest) {
    final onlyA = _difference(a.rows, b.rows);
    final onlyB = _difference(b.rows, a.rows);
    reasons.add(
      'bundle digest differs: ${a.label}=${_short(a.bundleDigest)} '
      '${b.label}=${_short(b.bundleDigest)}'
      '${onlyA.isEmpty ? "" : "; only on ${a.label}: ${_list(onlyA)}"}'
      '${onlyB.isEmpty ? "" : "; only on ${b.label}: ${_list(onlyB)}"}'
      '${onlyA.isEmpty && onlyB.isEmpty ? "; identical row sets — the rows agree but their CONTENT does not" : ""}',
    );
  }

  if (a.rows.length != b.rows.length) {
    reasons.add(
      'row counts differ: ${a.label}=${a.rows.length} '
      '${b.label}=${b.rows.length}',
    );
  }

  if (a.memberCount != b.memberCount) {
    reasons.add(
      'member counts differ: ${a.label}=${a.memberCount} '
      '${b.label}=${b.memberCount}',
    );
  }

  if (requireConversationAgreement) {
    final setA = a.conversationMessageIds.toSet();
    final setB = b.conversationMessageIds.toSet();
    final onlyA = setA.difference(setB);
    final onlyB = setB.difference(setA);
    if (onlyA.isNotEmpty || onlyB.isNotEmpty) {
      reasons.add(
        'conversation differs'
        '${onlyA.isEmpty ? "" : "; only on ${a.label}: ${_list(onlyA.toList())}"}'
        '${onlyB.isEmpty ? "" : "; only on ${b.label}: ${_list(onlyB.toList())}"}',
      );
    }
  }

  return ConvergenceVerdict(agree: reasons.isEmpty, reasons: reasons);
}

/// "Does this device hold [messageId] exactly once?" — the criterion of
/// checklist case 3/8, which is about duplication in a CONVERSATION and is not
/// answered by the device-group digest.
///
/// Returns null when the count is exactly one, and an explanation otherwise, so
/// a caller can `expect(exactlyOnce(...), isNull, reason: ...)`.
String? exactlyOnce(DeviceStateSnapshot device, String messageId) {
  final count = device.conversationMessageIds
      .where((id) => id == messageId)
      .length;
  if (count == 1) return null;
  return count == 0
      ? '${device.label} does not hold $messageId at all '
            '(${device.conversationMessageIds.length} message(s) in that '
            'conversation)'
      : '${device.label} holds $messageId $count times — duplicate rows';
}

// --- internals ---------------------------------------------------------------

List<String> _duplicateReasons(DeviceStateSnapshot device) {
  final seen = <RowRef, int>{};
  for (final row in device.rows) {
    seen[row] = (seen[row] ?? 0) + 1;
  }
  final dupes = seen.entries.where((e) => e.value > 1).toList()
    ..sort((x, y) => x.key.compareTo(y.key));
  if (dupes.isEmpty) return const [];
  return [
    '${device.label} has duplicate rows: '
        '${dupes.map((e) => "${e.key}×${e.value}").join(", ")}',
  ];
}

List<String> _gapReasons(DeviceStateSnapshot device) {
  final chains = <String, List<int>>{};
  for (final row in device.rows) {
    chains.putIfAbsent('${row.kind}/${row.authorHex}', () => []).add(row.seq);
  }
  final out = <String>[];
  for (final chain in chains.entries.toList()
    ..sort((x, y) => x.key.compareTo(y.key))) {
    final seqs = chain.value.toSet().toList()..sort();
    final missing = <int>[];
    for (var expected = seqs.first; expected < seqs.last; expected++) {
      if (!seqs.contains(expected)) missing.add(expected);
    }
    if (missing.isNotEmpty) {
      out.add(
        '${device.label} has gaps in ${chain.key.split("/")[0]} chain of '
        '${_short(chain.key.split("/")[1])}: missing seq '
        '${missing.join(", ")} (holds ${seqs.first}..${seqs.last})',
      );
    }
  }
  return out;
}

List<RowRef> _difference(List<RowRef> from, List<RowRef> without) {
  final other = without.toSet();
  final out = from.where((r) => !other.contains(r)).toSet().toList()..sort();
  return out;
}

String _list(List<Object> items, {int max = 8}) => items.length <= max
    ? items.join(', ')
    : '${items.take(max).join(', ')} … (+${items.length - max} more)';

String _short(String? hex) {
  if (hex == null) return 'none';
  return hex.length <= 8 ? hex : hex.substring(0, 8);
}
