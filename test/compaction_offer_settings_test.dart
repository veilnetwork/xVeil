import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

/// The two knobs behind the compaction offer, and the mark that stops it
/// pestering. They live in the container rather than in device preferences,
/// because they belong to the identity that owns the data — a decoy opening on
/// the same machine must not inherit the real profile's answer.
Future<ProviderContainer> _open() async {
  // The controller boots on construction and reads device preferences on the
  // way; without these two lines the test measures a missing binding rather
  // than the settings.
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  return ProviderContainer(
    overrides: [singleSpaceStorageProvider.overrideWithValue(storage)],
  );
}

void main() {
  test('an untouched profile gets three days and a gigabyte', () async {
    final c = await _open();
    addTearDown(c.dispose);
    final settings = await c
        .read(appControllerProvider.notifier)
        .compactionOfferSettings();
    // Absent means default-ON: the offer exists for the person who never opens
    // these settings, which is most people.
    expect(settings.enabled, isTrue);
    expect(settings.period, const Duration(days: 3));
    expect(settings.thresholdBytes, 1 << 30);
  });

  test('both knobs survive a round trip', () async {
    final c = await _open();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await ctrl.setCompactionOfferSettings(
      const CompactionOfferSettings(
        period: Duration(days: 14),
        thresholdBytes: 4 << 30,
      ),
    );
    final back = await ctrl.compactionOfferSettings();
    expect(back.period, const Duration(days: 14));
    expect(back.thresholdBytes, 4 << 30);
    expect(back.enabled, isTrue);
  });

  test('switching the offer off is remembered', () async {
    final c = await _open();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await ctrl.setCompactionOfferSettings(
      const CompactionOfferSettings(enabled: false),
    );
    expect((await ctrl.compactionOfferSettings()).enabled, isFalse);
    // And back on, so "off" is a setting rather than a one-way door.
    await ctrl.setCompactionOfferSettings(
      const CompactionOfferSettings(enabled: true),
    );
    expect((await ctrl.compactionOfferSettings()).enabled, isTrue);
  });

  test('a period under a day is stored as a day, not as zero', () async {
    // Duration.inDays truncates, so an hour would persist as "0" and read back
    // as the default — a setting that silently ignores what it was given.
    final c = await _open();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    await ctrl.setCompactionOfferSettings(
      const CompactionOfferSettings(period: Duration(hours: 5)),
    );
    expect((await ctrl.compactionOfferSettings()).period, const Duration(days: 1));
  });

  test('the offer clock starts when it is SHOWN, not when it is accepted', () async {
    final c = await _open();
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    expect(await ctrl.lastCompactionOfferAt(), isNull);

    final shown = DateTime(2026, 8, 10, 9, 30);
    await ctrl.noteCompactionOffered(at: shown);
    final back = await ctrl.lastCompactionOfferAt();
    expect(back, isNotNull);
    expect(back!.millisecondsSinceEpoch, shown.millisecondsSinceEpoch);

    // Declining IS an answer: the verdict must now hold its tongue for the
    // whole period, however much there is to reclaim.
    final settings = await ctrl.compactionOfferSettings();
    expect(
      compactionOfferVerdict(
        estimate: const CompactionEstimate(
          fileBytes: 40 << 30,
          liveBytes: 1 << 20,
          identitiesCounted: 1,
          identitiesKnown: 1,
        ),
        settings: settings,
        now: shown.add(const Duration(days: 2, hours: 23)),
        lastOfferedAt: back,
      ),
      CompactionOfferVerdict.tooSoon,
    );
  });

  test('asking before there is a container answers null, not an exception', () async {
    // The settings screen and the unlock path can both reach this before a
    // store exists. Silence is the only honest answer there — and it must be
    // an answer, not a crash, because the offer is meant to be asked about
    // freely rather than guarded by every caller.
    final c = await _open();
    addTearDown(c.dispose);
    expect(
      await c.read(appControllerProvider.notifier).compactionOffer(),
      isNull,
    );
  });

  test('compacting with an empty roster is refused, not attempted', () async {
    // compact_known KEEPS the spaces it is given passwords for and drops every
    // other one. An empty roster is therefore not a no-op: it is "delete every
    // identity in this container", and it must never reach the FFI.
    final c = await _open();
    addTearDown(c.dispose);
    await expectLater(
      c.read(appControllerProvider.notifier).compactStorageKeeping(
        roster: CompactionRoster(),
        reopenWith: 'pw',
      ),
      throwsA(isA<StateError>()),
    );
  });
}
