import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';

const _gib = 1 << 30;

CompactionEstimate _est({
  required int file,
  required int live,
  int counted = 1,
  int known = 1,
}) => CompactionEstimate(
  fileBytes: file,
  liveBytes: live,
  identitiesCounted: counted,
  identitiesKnown: known,
);

void main() {
  group('estimate', () {
    test('reclaimable is the file minus what is live, never negative', () {
      final e = _est(file: 2707103744, live: 24551424);
      expect(e.reclaimableBytes, 2707103744 - 24551424);
      expect(e.projectedBytes, 24551424);

      // Mid-commit a space can report more live chunks than the file has
      // slots. A negative "reclaim" would render as a file that grows by
      // compacting.
      expect(_est(file: 100, live: 140).reclaimableBytes, 0);
    });

    test('an estimate is exact only when every identity was counted', () {
      // One identity of two: the sibling's live data is not decryptable here
      // and therefore looks exactly like garbage — the figure OVERSTATES, and
      // saying so is the difference between an offer and a lie.
      expect(_est(file: 10, live: 4, counted: 1, known: 2).isExact, isFalse);
      expect(_est(file: 10, live: 4, counted: 2, known: 2).isExact, isTrue);
      // A container whose identity count is unknown cannot be called exact.
      expect(_est(file: 10, live: 4, counted: 1, known: 0).isExact, isFalse);
    });
  });

  group('offer verdict', () {
    final now = DateTime(2026, 8, 9, 12);
    const settings = CompactionOfferSettings();

    test('defaults are three days and a gigabyte', () {
      expect(settings.period, const Duration(days: 3));
      expect(settings.thresholdBytes, 1 << 30);
    });

    test('offers once there is more than the threshold to reclaim', () {
      expect(
        compactionOfferVerdict(
          estimate: _est(file: 3 * _gib, live: 100 << 20),
          settings: settings,
          now: now,
        ),
        CompactionOfferVerdict.offer,
      );
    });

    test('stays quiet below the threshold', () {
      expect(
        compactionOfferVerdict(
          // 900 MiB reclaimable — under a gigabyte.
          estimate: _est(file: _gib, live: 124 << 20),
          settings: settings,
          now: now,
        ),
        CompactionOfferVerdict.belowThreshold,
      );
    });

    test('waits out the period after an offer was shown', () {
      final estimate = _est(file: 4 * _gib, live: 1 << 20);
      // Declining IS an answer: the clock runs from when the offer was shown,
      // not from when compaction last ran, or a decline would be re-asked the
      // next time the app looked.
      expect(
        compactionOfferVerdict(
          estimate: estimate,
          settings: settings,
          now: now,
          lastOfferedAt: now.subtract(const Duration(days: 2, hours: 23)),
        ),
        CompactionOfferVerdict.tooSoon,
      );
      expect(
        compactionOfferVerdict(
          estimate: estimate,
          settings: settings,
          now: now,
          lastOfferedAt: now.subtract(const Duration(days: 3, seconds: 1)),
        ),
        CompactionOfferVerdict.offer,
      );
    });

    test('a custom period and threshold are honoured', () {
      final estimate = _est(file: 2 * _gib, live: 1 << 20);
      const weekly = CompactionOfferSettings(
        period: Duration(days: 7),
        thresholdBytes: 4 * _gib,
      );
      expect(
        compactionOfferVerdict(
          estimate: estimate,
          settings: weekly,
          now: now,
          lastOfferedAt: now.subtract(const Duration(days: 4)),
        ),
        CompactionOfferVerdict.tooSoon,
      );
      expect(
        compactionOfferVerdict(
          estimate: estimate,
          settings: weekly,
          now: now,
          lastOfferedAt: now.subtract(const Duration(days: 8)),
        ),
        // Past the period, but 2 GiB is under this person's 4 GiB threshold.
        CompactionOfferVerdict.belowThreshold,
      );
    });

    test('switched off means never', () {
      expect(
        compactionOfferVerdict(
          estimate: _est(file: 100 * _gib, live: 1),
          settings: settings.copyWith(enabled: false),
          now: now,
        ),
        CompactionOfferVerdict.disabled,
      );
    });
  });

  group('roster', () {
    test('an identity reached through two masters is compacted once', () {
      // `compact_known` KEEPS the spaces it is given passwords for and drops
      // the rest, so the roster is what survives. A space that hangs under two
      // masters must appear once — handing its password twice asks the
      // container to keep the same space twice.
      final r = CompactionRoster();
      expect(r.addUnlocked('master-a', passwordBytes: [1, 1]), isTrue);
      expect(
        r.addSubordinate('shared', passwordBytes: [1, 1], master: 'master-a'),
        isTrue,
      );
      expect(r.addUnlocked('master-b', passwordBytes: [2, 2]), isTrue);
      expect(
        r.addSubordinate('shared', passwordBytes: [2, 2], master: 'master-b'),
        isFalse,
        reason: 'already on the list under its first master',
      );

      expect(r.length, 3);
      expect(r.nodeIds, ['master-a', 'shared', 'master-b']);
      expect(r.masterOf('shared'), 'master-a');
    });

    test('a password typed twice does not become a second space', () {
      final r = CompactionRoster();
      expect(r.addUnlocked('one', passwordBytes: [7]), isTrue);
      expect(r.addUnlocked('one', passwordBytes: [7]), isFalse);
      expect(r.length, 1);
      expect(r.passwords(), [
        [7],
      ]);
    });

    test('subordinates sharing a master password are passed once', () {
      // Two identities under one master share ITS password; sending it twice
      // would have `compact_known` keep the same space twice.
      final r = CompactionRoster()
        ..addUnlocked('master', passwordBytes: [9, 9])
        ..addSubordinate('sub-1', passwordBytes: [9, 9], master: 'master')
        ..addSubordinate('sub-2', passwordBytes: [9, 9], master: 'master');
      expect(r.length, 3, reason: 'three identities are listed to the person');
      expect(
        r.passwords(),
        [
          [9, 9],
        ],
        reason: 'but one password opens all three',
      );
      expect(r.unlockedDirectly, ['master']);
    });
  });
}
