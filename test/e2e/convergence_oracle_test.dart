import 'package:flutter_test/flutter_test.dart';

import 'convergence_oracle.dart';

/// The oracle's own test — and the ONE file of the e2e subtree that is not
/// env-gated, on purpose.
///
/// Every live case decides pass/fail by calling [convergenceOf]. An oracle that
/// answers "converged" to everything therefore turns the whole gated suite
/// green without a single defect being caught, and nothing downstream would
/// notice. So this file works the way the project's break-checks work: it feeds
/// the oracle pairs that MUST be rejected, one per failure mode, and demands a
/// specific reason — not merely `agree == false`, which a stopped clock also
/// gets right.
///
/// Runs under a plain `flutter test`: the oracle imports nothing from `lib/`,
/// so there is no dylib, no relay and no container in the way.
RowRef _msg(String author, int seq) =>
    RowRef(kind: 'msg', authorHex: author, seq: seq);
RowRef _ctl(String author, int seq) =>
    RowRef(kind: 'ctl', authorHex: author, seq: seq);

const _a = 'aaaaaaaabbbbbbbbccccccccdddddddd';
const _b = 'bbbbbbbbccccccccddddddddeeeeeeee';

DeviceStateSnapshot _device(
  String label, {
  String? group = 'deadbeefcafef00d',
  String digest = 'digest-1',
  List<RowRef>? rows,
  List<String> conversation = const ['m1', 'm2'],
  int members = 2,
  int epoch = 0,
}) => DeviceStateSnapshot(
  label: label,
  deviceGroupIdHex: group,
  bundleDigest: digest,
  rows: rows ?? [_ctl(_a, 0), _ctl(_a, 1), _msg(_a, 0), _msg(_b, 0)],
  conversationMessageIds: conversation,
  memberCount: members,
  epoch: epoch,
);

void main() {
  group('the oracle accepts a genuinely converged pair', () {
    test('identical readings agree', () {
      final verdict = convergenceOf(_device('A'), _device('B'));
      expect(verdict.agree, isTrue, reason: verdict.describe());
      expect(verdict.reasons, isEmpty);
    });

    test('row ORDER is not a disagreement — the fold is a set, not a list', () {
      final forwards = _device('A', rows: [_msg(_a, 0), _msg(_a, 1)]);
      final backwards = _device('B', rows: [_msg(_a, 1), _msg(_a, 0)]);
      expect(convergenceOf(forwards, backwards).agree, isTrue);
    });

    test('local-only divergence is invisible: notes are never compared', () {
      final a = DeviceStateSnapshot(
        label: 'A',
        deviceGroupIdHex: 'deadbeefcafef00d',
        bundleDigest: 'digest-1',
        rows: [_msg(_a, 0)],
        notes: const {'queued': 4},
      );
      final b = DeviceStateSnapshot(
        label: 'B',
        deviceGroupIdHex: 'deadbeefcafef00d',
        bundleDigest: 'digest-1',
        rows: [_msg(_a, 0)],
        notes: const {'queued': 0},
      );
      expect(convergenceOf(a, b).agree, isTrue);
    });
  });

  group('the oracle rejects each way a pair can be wrong', () {
    test('different bundle digests', () {
      final verdict = convergenceOf(
        _device('A', digest: 'digest-1'),
        _device('B', digest: 'digest-2'),
      );
      expect(verdict.agree, isFalse);
      expect(verdict.describe(), contains('bundle digest differs'));
    });

    test('same rows, different content — says so explicitly', () {
      // The nastiest shape: the row SET matches, so a set comparison passes,
      // and only the digest sees that a body was rewritten.
      final verdict = convergenceOf(
        _device('A', digest: 'digest-1'),
        _device('B', digest: 'digest-2'),
      );
      expect(
        verdict.describe(),
        contains('identical row sets'),
        reason: 'a digest-only difference must be named as one, or the '
            'operator hunts for a missing row that does not exist',
      );
    });

    test('a row missing on one side is NAMED', () {
      final verdict = convergenceOf(
        _device('A', digest: 'd', rows: [_msg(_a, 0), _msg(_a, 1)]),
        _device('B', digest: 'e', rows: [_msg(_a, 0)]),
      );
      expect(verdict.agree, isFalse);
      expect(verdict.describe(), contains('only on A: msg/aaaaaaaa#1'));
      expect(verdict.describe(), contains('row counts differ: A=2 B=1'));
    });

    test('duplicate rows on ONE side fail even when the digests match', () {
      // `one-file-two-rows` in the flesh: the same logical row stored twice.
      final verdict = convergenceOf(
        _device('A', rows: [_msg(_a, 0), _msg(_a, 0)]),
        _device('B', rows: [_msg(_a, 0)]),
      );
      expect(verdict.agree, isFalse);
      expect(verdict.describe(), contains('A has duplicate rows'));
      expect(verdict.describe(), contains('msg/aaaaaaaa#0×2'));
    });

    test('duplicates on BOTH sides still fail — equality is not correctness', () {
      final verdict = convergenceOf(
        _device('A', rows: [_msg(_a, 0), _msg(_a, 0)]),
        _device('B', rows: [_msg(_a, 0), _msg(_a, 0)]),
      );
      expect(
        verdict.agree,
        isFalse,
        reason: 'two identically broken devices are not a converged pair',
      );
    });

    test('a gap in one writer chain fails', () {
      final verdict = convergenceOf(
        _device('A', rows: [_msg(_a, 0), _msg(_a, 1), _msg(_a, 2)]),
        _device('B', rows: [_msg(_a, 0), _msg(_a, 1), _msg(_a, 2)]),
      );
      expect(verdict.agree, isTrue, reason: 'contiguous is fine');

      final gapped = convergenceOf(
        _device('A', rows: [_msg(_a, 0), _msg(_a, 2)]),
        _device('B', rows: [_msg(_a, 0), _msg(_a, 2)]),
      );
      expect(gapped.agree, isFalse);
      expect(gapped.describe(), contains('missing seq 1'));
    });

    test('a gap is per WRITER, not across writers', () {
      // The per-writer frontier defect (9cbe6a4): a flat frontier treats two
      // authors' chains as one and invents a gap that is not there.
      final verdict = convergenceOf(
        _device('A', rows: [_msg(_a, 0), _msg(_b, 0), _msg(_b, 1)]),
        _device('B', rows: [_msg(_a, 0), _msg(_b, 0), _msg(_b, 1)]),
      );
      expect(verdict.agree, isTrue, reason: verdict.describe());
    });

    test('control and message chains are numbered independently', () {
      final verdict = convergenceOf(
        _device('A', rows: [_ctl(_a, 0), _msg(_a, 0)]),
        _device('B', rows: [_ctl(_a, 0), _msg(_a, 0)]),
      );
      expect(
        verdict.agree,
        isTrue,
        reason: 'ctl#0 and msg#0 by one author are not a duplicate pair',
      );
    });

    test('an unlinked device is a failure, not a trivial pass', () {
      final verdict = convergenceOf(
        _device('A', group: null),
        _device('B', group: null),
      );
      expect(
        verdict.agree,
        isFalse,
        reason: 'two devices with no device group agree about nothing; a '
            'harness that called this converged would pass every case '
            'before the link ceremony even ran',
      );
      expect(verdict.describe(), contains('device group missing'));
    });

    test('two DIFFERENT device groups fail', () {
      final verdict = convergenceOf(
        _device('A', group: 'aaaa1111'),
        _device('B', group: 'bbbb2222'),
      );
      expect(verdict.agree, isFalse);
      expect(verdict.describe(), contains('different device groups'));
    });

    test('member counts differing fails (a half-ghost member)', () {
      final verdict = convergenceOf(
        _device('A', members: 3),
        _device('B', members: 2),
      );
      expect(verdict.agree, isFalse);
      expect(verdict.describe(), contains('member counts differ: A=3 B=2'));
    });

    test('conversation divergence is opt-in and reported when asked for', () {
      final a = _device('A', conversation: ['m1', 'm2']);
      final b = _device('B', conversation: ['m1']);
      expect(
        convergenceOf(a, b).agree,
        isTrue,
        reason: 'the device-group criterion alone says nothing about a 1:1 '
            'conversation',
      );
      final strict = convergenceOf(a, b, requireConversationAgreement: true);
      expect(strict.agree, isFalse);
      expect(strict.describe(), contains('only on A: m2'));
    });
  });

  group('exactlyOnce', () {
    test('one copy passes', () {
      expect(exactlyOnce(_device('A', conversation: ['m1', 'm2']), 'm1'), isNull);
    });

    test('zero copies is named as absence, not as duplication', () {
      final why = exactlyOnce(_device('A', conversation: ['m2']), 'm1');
      expect(why, isNotNull);
      expect(why, contains('does not hold m1'));
      expect(why, contains('1 message(s)'));
    });

    test('two copies is named as duplication', () {
      final why = exactlyOnce(_device('A', conversation: ['m1', 'm1']), 'm1');
      expect(why, isNotNull);
      expect(why, contains('holds m1 2 times'));
    });
  });

  group('a verdict can be read by a human', () {
    test('a converged verdict says so in one word', () {
      expect(convergenceOf(_device('A'), _device('B')).describe(), 'converged');
    });

    test('every reason is carried into the description', () {
      final verdict = convergenceOf(
        _device('A', group: 'aaaa1111', digest: 'x', members: 3,
            rows: [_msg(_a, 0), _msg(_a, 0)]),
        _device('B', group: 'bbbb2222', digest: 'y', members: 2,
            rows: [_msg(_a, 2)]),
      );
      expect(verdict.agree, isFalse);
      for (final reason in verdict.reasons) {
        expect(verdict.describe(), contains(reason));
      }
      expect(
        verdict.reasons.length,
        greaterThanOrEqualTo(4),
        reason: 'a pair that is wrong five ways must not report only the '
            'first — the run costs minutes and every re-run costs another',
      );
    });
  });
}
