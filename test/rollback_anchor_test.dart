import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';

void main() {
  /// Nothing anchored yet is not an accusation.
  test('an unanchored space is a first run, not a fork', () {
    final check = checkRollbackAnchor(
      anchorSeq: null,
      currentSeq: 91,
      history: const [],
    );
    expect(check.verdict, AnchorVerdict.firstRun);
    expect(check.isSuspicious, isFalse);
    expect(check.mayReuseSendPositions, isFalse);
  });

  /// The ordinary open: forward, and the container still knows the commit we
  /// anchored.
  test('a container that moved forward on its own timeline is clean', () {
    final check = checkRollbackAnchor(
      anchorSeq: 90,
      currentSeq: 93,
      history: const [88, 89, 90, 91, 92, 93],
    );
    expect(check.verdict, AnchorVerdict.clean);
    expect(check.isSuspicious, isFalse);
  });

  /// A container standing exactly where it was left is clean too — the app is
  /// opened far more often than it commits.
  test('a container that did not move is clean', () {
    final check = checkRollbackAnchor(
      anchorSeq: 90,
      currentSeq: 90,
      history: const [89, 90],
    );
    expect(check.verdict, AnchorVerdict.clean);
  });

  /// The one that re-uses key material.
  ///
  /// Behind the anchor means commits that were made are not here — and the
  /// send-position reservations they carried are not here either, while the
  /// positions they reserved may already be on the wire (report8 M8-14).
  test('a container put back to an older copy is a rollback', () {
    final check = checkRollbackAnchor(
      anchorSeq: 900,
      currentSeq: 880,
      history: const [878, 879, 880],
      reserveAhead: 32,
    );
    expect(check.verdict, AnchorVerdict.rolledBack);
    expect(check.mayReuseSendPositions, isTrue);
    expect(check.lostCommits, 20);
    expect(
      check.lostSendPositions,
      20 * 32,
      reason:
          'the burn has to cover every position the lost commits could '
          'have reserved, or a nonce comes back',
    );
  });

  /// Ahead, inside the window, and the container does not know the commit we
  /// anchored: its history is not the one this device wrote.
  test('a container whose history does not contain our anchor is a fork', () {
    // INSIDE the window the container reports, and missing from it. Below the
    // window is a different answer — see the out-of-range test further down.
    final check = checkRollbackAnchor(
      anchorSeq: 92,
      currentSeq: 95,
      history: const [90, 91, 93, 94, 95],
    );
    expect(check.verdict, AnchorVerdict.forked);
    expect(check.isSuspicious, isTrue);
    expect(
      check.mayReuseSendPositions,
      isFalse,
      reason: 'a fork is ahead of us; it did not put a spent position back',
    );
  });

  /// THE ORDER OF THE TESTS. A device away for longer than the window comes
  /// back to a container that no longer keeps the commit it anchored — and
  /// that is not evidence of anything.
  ///
  /// Checking membership before distance calls every long-offline device an
  /// adversary. The library's guide warns about exactly this, and the warning
  /// is there because the mistake is the natural one to make: absence looks
  /// like proof until you remember what aged out.
  test('an anchor older than the window is out of range, not a fork', () {
    final check = checkRollbackAnchor(
      anchorSeq: 10,
      currentSeq: 10 + anchorHorizon + 1,
      history: const [2000, 2001], // long since past 10
    );
    expect(
      check.verdict,
      AnchorVerdict.outOfRange,
      reason: 'a long-offline device was called adversarial',
    );
    expect(check.isSuspicious, isFalse);
  });

  /// And the boundary itself is INSIDE the window, so the membership test
  /// still applies there.
  test('the last commit inside the window is still judged on membership', () {
    final atEdge = checkRollbackAnchor(
      anchorSeq: 10,
      currentSeq: 10 + anchorHorizon,
      history: const [10, 11],
    );
    expect(atEdge.verdict, AnchorVerdict.clean);

    final atEdgeMissing = checkRollbackAnchor(
      anchorSeq: 10,
      currentSeq: 10 + anchorHorizon,
      history: const [9, 11, 12],
    );
    expect(
      atEdgeMissing.verdict,
      AnchorVerdict.forked,
      reason: 'the horizon is inclusive; one past it is where proof stops',
    );
  });

  /// The window the container REPORTS, not the one the subtraction predicts.
  ///
  /// `horizon` is a guess at what was retired; the history is what actually
  /// was. They disagree on a container younger than the horizon, and on one
  /// that was compacted — its history restarts at 1 however far the counter
  /// has run. An anchor below the oldest commit still held has aged out, and
  /// its absence is not evidence of anything.
  test('an anchor below the reported window is out of range, not a fork', () {
    final compacted = checkRollbackAnchor(
      anchorSeq: 40,
      currentSeq: 45,
      history: const [41, 42, 43, 44, 45],
    );
    expect(
      compacted.verdict,
      AnchorVerdict.outOfRange,
      reason:
          'the container no longer holds the commit we anchored, and the '
          'subtraction says nothing about that',
    );

    // A container that reports nothing cannot be judged on membership either.
    final silent = checkRollbackAnchor(
      anchorSeq: 3,
      currentSeq: 3,
      history: const [],
    );
    expect(silent.verdict, AnchorVerdict.outOfRange);

    // Vacuity: the same shape WITH the anchor in the window is a fork, or the
    // two assertions above would pass with the membership test deleted.
    final forked = checkRollbackAnchor(
      anchorSeq: 42,
      currentSeq: 45,
      history: const [41, 43, 44, 45],
    );
    expect(forked.verdict, AnchorVerdict.forked);
  });

  /// The bound is an over-estimate on purpose, and zero when there is nothing
  /// to bound.
  test(
    'the positions at risk are bounded by the commits that went missing',
    () {
      expect(sendPositionsAtRisk(lostCommits: 0, reserveAhead: 32), 0);
      expect(sendPositionsAtRisk(lostCommits: -3, reserveAhead: 32), 0);
      expect(sendPositionsAtRisk(lostCommits: 5, reserveAhead: 0), 0);
      expect(
        sendPositionsAtRisk(lostCommits: 5, reserveAhead: 32),
        160,
        reason:
            'renewing a reservation costs a commit, so five lost commits '
            'hide at most five renewals of any one conversation',
      );
    },
  );

  /// The horizon is a COPY of a Rust constant the FFI does not export.
  ///
  /// Nothing makes the two agree at build time, and a copy that drifts up
  /// turns an ordinary long-offline return into an accusation while
  /// everything still compiles — the shape of defect this project has been
  /// bitten by before (a positional contract guarded only by a comment).
  test('the horizon still matches the constant it mirrors', () {
    final rust = File(
      'third_party/hidden-volume/crates/hidden-volume/src/lib.rs',
    );
    if (!rust.existsSync()) {
      fail(
        'hidden-volume sources are missing, so this guard cannot check the '
        'constant it exists to check — do not weaken it into a skip',
      );
    }
    final match = RegExp(
      r'pub const ANCHOR_HORIZON:\s*u64\s*=\s*(\d+)\s*;',
    ).firstMatch(rust.readAsStringSync());
    expect(
      match,
      isNotNull,
      reason: 'ANCHOR_HORIZON moved or was renamed; re-aim this guard',
    );
    expect(
      int.parse(match!.group(1)!),
      anchorHorizon,
      reason: 'the app believes a different horizon than the container keeps',
    );
  });

  group('a seq is not a branch (report22 HV-FORK-SEQ)', () {
    // Both sides of a fork count commits the same way, so a container that
    // reached the anchored NUMBER says nothing about being the container that
    // left it. hidden-volume 2.3.0 exports what each commit published; the
    // anchor holds that pair and matches it exactly.

    test('the same seq under a different root is a fork', () {
      final check = checkRollbackAnchor(
        anchorSeq: 7,
        anchorRoot: 'aaaa',
        currentSeq: 9,
        history: const [5, 6, 7, 8, 9],
        roots: const {7: 'bbbb'},
      );
      expect(
        check.verdict,
        AnchorVerdict.forked,
        reason:
            'the anchored number is present, and the era it names is somebody '
            "else's — which is exactly what the seq test could not see",
      );
    });

    test('the same seq under the same root is a clean continuation', () {
      final check = checkRollbackAnchor(
        anchorSeq: 7,
        anchorRoot: 'aaaa',
        currentSeq: 9,
        history: const [5, 6, 7, 8, 9],
        roots: const {7: 'aaaa'},
      );
      expect(check.verdict, AnchorVerdict.clean);
    });

    test('an anchor from before roots existed is still honoured', () {
      // The first launch after an update carries an anchor with no root. It is
      // an honest anchor written by this device, and refusing it would report
      // a fork on every upgrade.
      final check = checkRollbackAnchor(
        anchorSeq: 7,
        currentSeq: 9,
        history: const [5, 6, 7, 8, 9],
        roots: const {7: 'aaaa'},
      );
      expect(check.verdict, AnchorVerdict.clean);
    });

    test('an era the container cannot identify accuses nobody', () {
      // The seq is in the history but its Superblock did not decode. Nothing
      // is proved either way, and calling that a fork would accuse a container
      // that is merely damaged.
      final check = checkRollbackAnchor(
        anchorSeq: 7,
        anchorRoot: 'aaaa',
        currentSeq: 9,
        history: const [5, 6, 7, 8, 9],
        roots: const {},
      );
      expect(check.verdict, AnchorVerdict.outOfRange);
    });

    test('a missing seq is still a fork, root or no root', () {
      expect(
        checkRollbackAnchor(
          anchorSeq: 7,
          anchorRoot: 'aaaa',
          currentSeq: 9,
          history: const [5, 6, 8, 9],
          roots: const {},
        ).verdict,
        AnchorVerdict.forked,
      );
    });
  });

  group('the anchor record carries the era', () {
    test('a pair round-trips, and so does a record without one', () {
      const withRoot = AnchorRecord(generation: 'ab12', seq: 7, root: 'cd34');
      final back = AnchorRecord.decode(withRoot.encode());
      expect(back?.generation, 'ab12');
      expect(back?.seq, 7);
      expect(back?.root, 'cd34');

      const bare = AnchorRecord(generation: 'ab12', seq: 7);
      final bareBack = AnchorRecord.decode(bare.encode());
      expect(bareBack?.root, isNull, reason: 'a bare record grew a root');
      expect(bareBack?.seq, 7);
    });

    test('an anchor written by an older build still reads', () {
      // Two-part form, on disk from before this change.
      final old = AnchorRecord.decode('ab12:7');
      expect(old?.generation, 'ab12');
      expect(old?.seq, 7);
      expect(old?.root, isNull);
    });

    test('nonsense is refused rather than half-read', () {
      for (final raw in ['', 'ab12', 'ab12:x', 'ab12:7:', 'a:b:c:d', ':7']) {
        expect(
          AnchorRecord.decode(raw),
          isNull,
          reason: 'accepted $raw',
        );
      }
    });
  });
}
