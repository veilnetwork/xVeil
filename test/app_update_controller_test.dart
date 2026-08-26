import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/update/install_prefs.dart';
import 'package:xveil/data/update/app_update.dart';
import 'package:xveil/state/app_update_controller.dart';

/// The check has to be quiet in two directions at once: it must not nag, and
/// it must not turn a launch into an error. Everything below is one of those.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const page = 'https://github.com/veilnetwork/xVeil/releases/tag/v9.9.9';
  const body =
      '{"tag_name":"v9.9.9","html_url":"$page",'
      '"draft":false,"prerelease":false}';

  AppUpdateChecker answering(String text, {List<Uri>? asked}) =>
      AppUpdateChecker(
        running: '0.13.3+11',
        fetcher: (uri) async {
          asked?.add(uri);
          return text;
        },
      );

  late Directory support;
  late InstallUpdatePrefs installPrefs;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    support = Directory.systemTemp.createTempSync('xveil-install');
    installPrefs = InstallUpdatePrefs(InstallUpdatePrefs.pathIn(support.path));
  });
  tearDown(() => support.deleteSync(recursive: true));

  /// A container reading the install-wide pair from this test's own file.
  ProviderContainer withInstallPrefs() => ProviderContainer(
    overrides: [
      installUpdatePrefsProvider.overrideWith((ref) async => installPrefs),
    ],
  );

  test('a stored opt-out is honoured on the very first launch', () async {
    // The setting exists to stop an outbound connection to github.com that
    // says this device runs xVeil. It is loaded asynchronously, and the
    // automatic check runs when the app becomes usable — which can be first.
    // Reading the provider optimistically answered "on" for somebody who had
    // turned it off, and the request went out before their choice arrived.
    installPrefs.enabled = false;
    final container = withInstallPrefs();
    addTearDown(container.dispose);
    final asked = <Uri>[];

    // Deliberately WITHOUT reading updateCheckEnabledProvider first: that read
    // is what would have given the stored value time to arrive, and a launch
    // does not necessarily do it.
    await container
        .read(appUpdateProvider.notifier)
        .checkIfDue(checker: answering(body, asked: asked));

    expect(asked, isEmpty, reason: 'asked github.com after an opt-out');
    expect(container.read(appUpdateProvider), isNull);
  });

  test('and a stored opt-IN still asks', () async {
    // Vacuity guard: a check that never asks satisfies the test above.
    installPrefs.enabled = true;
    final container = withInstallPrefs();
    addTearDown(container.dispose);
    final asked = <Uri>[];

    await container
        .read(appUpdateProvider.notifier)
        .checkIfDue(checker: answering(body, asked: asked));

    expect(asked, hasLength(1));
  });

  test('a choice made in this session wins over the stored one', () async {
    // The switch was just moved. The stored value may still be being written,
    // and it must not be the one that decides.
    installPrefs.enabled = true;
    final container = withInstallPrefs();
    addTearDown(container.dispose);
    final asked = <Uri>[];

    await container.read(updateCheckEnabledProvider.notifier).set(false);
    await container
        .read(appUpdateProvider.notifier)
        .checkIfDue(checker: answering(body, asked: asked));

    expect(asked, isEmpty);
  });

  test('the first run asks and remembers that it did', () async {
    final container = withInstallPrefs();
    addTearDown(container.dispose);
    final asked = <Uri>[];

    await container
        .read(appUpdateProvider.notifier)
        .checkIfDue(checker: answering(body, asked: asked));

    expect(asked, hasLength(1));
    expect(container.read(appUpdateProvider)?.tag, 'v9.9.9');
    expect(installPrefs.lastCheck, isNotNull);
  });

  test('a second launch the same day does not ask again', () async {
    final container = withInstallPrefs();
    addTearDown(container.dispose);
    final controller = container.read(appUpdateProvider.notifier);
    final now = DateTime.utc(2026, 8, 26, 12);

    await controller.checkIfDue(now: now, checker: answering(body));
    final asked = <Uri>[];
    await controller.checkIfDue(
      now: now.add(const Duration(hours: 3)),
      checker: answering(body, asked: asked),
    );

    expect(asked, isEmpty, reason: 'once a day, not once a launch');
  });

  test('a day later it asks again', () async {
    final container = withInstallPrefs();
    addTearDown(container.dispose);
    final controller = container.read(appUpdateProvider.notifier);
    final now = DateTime.utc(2026, 8, 26, 12);

    await controller.checkIfDue(now: now, checker: answering(body));
    final asked = <Uri>[];
    await controller.checkIfDue(
      now: now.add(const Duration(hours: 25)),
      checker: answering(body, asked: asked),
    );

    expect(asked, hasLength(1));
  });

  test('a check that FAILS still counts as asked today', () async {
    // Otherwise a device that cannot reach github.com asks on every launch —
    // exactly the traffic pattern the interval exists to prevent.
    final container = withInstallPrefs();
    addTearDown(container.dispose);
    final controller = container.read(appUpdateProvider.notifier);
    final now = DateTime.utc(2026, 8, 26, 12);

    await controller.checkIfDue(
      now: now,
      checker: AppUpdateChecker(
        running: '0.13.3+11',
        fetcher: (_) async => throw Exception('offline'),
      ),
    );
    expect(container.read(appUpdateProvider), isNull);

    final asked = <Uri>[];
    await controller.checkIfDue(
      now: now.add(const Duration(hours: 2)),
      checker: answering(body, asked: asked),
    );
    expect(asked, isEmpty);
  });

  test('with the switch off it never asks', () async {
    final container = withInstallPrefs();
    addTearDown(container.dispose);
    await container.read(updateCheckEnabledProvider.notifier).set(false);

    final asked = <Uri>[];
    await container
        .read(appUpdateProvider.notifier)
        .checkIfDue(checker: answering(body, asked: asked));

    expect(asked, isEmpty);
    expect(container.read(appUpdateProvider), isNull);
  });

  test('the switch survives a rebuild', () async {
    final first = withInstallPrefs();
    await first.read(updateCheckEnabledProvider.notifier).set(false);
    first.dispose();

    final second = withInstallPrefs();
    addTearDown(second.dispose);
    // The notifier loads asynchronously; read once to build it, then settle.
    second.read(updateCheckEnabledProvider);
    await Future<void>.delayed(Duration.zero);

    expect(second.read(updateCheckEnabledProvider), isFalse);
  });

  test('pressing check now ignores the interval', () async {
    final container = withInstallPrefs();
    addTearDown(container.dispose);
    final controller = container.read(appUpdateProvider.notifier);

    await controller.checkIfDue(checker: answering(body));
    final asked = <Uri>[];
    final found = await controller.checkNow(
      checker: answering(body, asked: asked),
    );

    expect(asked, hasLength(1), reason: 'the person is looking at the screen');
    expect(found?.tag, 'v9.9.9');
  });

  test('dismissing puts the offer away without forgetting the release', () async {
    final container = withInstallPrefs();
    addTearDown(container.dispose);
    final controller = container.read(appUpdateProvider.notifier);

    await controller.checkIfDue(checker: answering(body));
    expect(container.read(appUpdateProvider), isNotNull);

    controller.dismiss();
    expect(container.read(appUpdateProvider), isNull);

    // Pressing check-now finds it again: dismissing is not "never tell me".
    expect((await controller.checkNow(checker: answering(body)))?.tag, 'v9.9.9');
  });

  test('nothing newer means nothing to show', () async {
    // Premise for the tests above: they pass because v9.9.9 IS newer, not
    // because the controller shows whatever it is handed.
    final container = withInstallPrefs();
    addTearDown(container.dispose);

    await container.read(appUpdateProvider.notifier).checkIfDue(
      checker: AppUpdateChecker(
        running: '0.13.3+11',
        fetcher: (_) async =>
            '{"tag_name":"v0.13.3","html_url":"$page"}',
      ),
    );

    expect(container.read(appUpdateProvider), isNull);
  });

  group('the choice belongs to the install, not to a profile', () {
    // `SharedPreferences` looks install-wide and is not: production swaps the
    // platform backend for a file inside the ACTIVE PROFILE's directory. So a
    // person who turned checks off in one profile got a request to github.com
    // from the next one, and the daily throttle restarted per profile — one
    // beacon each, timed to that profile being opened.
    //
    // Modelled the way it happens: the same install file, two containers, as
    // two profiles would be.
    test('an opt-out made in one profile holds in another', () async {
      final a = withInstallPrefs();
      await a.read(updateCheckEnabledProvider.notifier).set(false);
      a.dispose();

      final b = withInstallPrefs();
      addTearDown(b.dispose);
      final asked = <Uri>[];
      await b
          .read(appUpdateProvider.notifier)
          .checkIfDue(checker: answering(body, asked: asked));

      expect(
        asked,
        isEmpty,
        reason: 'the second profile asked github.com anyway',
      );
    });

    test('and the daily throttle is not restarted by switching profile',
        () async {
      final now = DateTime(2026, 8, 26, 9);
      final a = withInstallPrefs();
      final askedA = <Uri>[];
      await a
          .read(appUpdateProvider.notifier)
          .checkIfDue(now: now, checker: answering(body, asked: askedA));
      expect(askedA, hasLength(1));
      a.dispose();

      final b = withInstallPrefs();
      addTearDown(b.dispose);
      final askedB = <Uri>[];
      await b.read(appUpdateProvider.notifier).checkIfDue(
            now: now.add(const Duration(hours: 1)),
            checker: answering(body, asked: askedB),
          );

      expect(
        askedB,
        isEmpty,
        reason: 'each profile got its own beacon, one per day each',
      );
    });

    test('the stamp names no profile', () {
      // What is shared has to be worth sharing: a stamp that said WHICH
      // profile checked would make a hidden one announce itself, which is the
      // opposite of the point.
      installPrefs.lastCheck = DateTime(2026, 8, 26);
      installPrefs.enabled = false;

      final raw = File(InstallUpdatePrefs.pathIn(support.path))
          .readAsStringSync();

      expect(raw, contains('lastCheckMs'));
      expect(raw, contains('enabled'));
      expect(raw, isNot(contains('profile')));
    });
  });

  group('a choice made before this store existed', () {
    // The pair moved from `SharedPreferences` to a file beside the profile
    // directories. What the move left behind was the choice: nothing read the
    // old key, so an upgrade found an empty store, took the default, and asked
    // github.com on behalf of somebody who had turned checks off
    // (report16 XV-13).
    test('an opt-out from the old store is honoured after the upgrade', () async {
      SharedPreferences.setMockInitialValues({
        kUpdateCheckEnabledPrefKey: false,
      });
      final container = withInstallPrefs();
      addTearDown(container.dispose);
      final asked = <Uri>[];

      await container
          .read(appUpdateProvider.notifier)
          .checkIfDue(checker: answering(body, asked: asked));

      expect(
        asked,
        isEmpty,
        reason: 'the upgrade asked github.com despite a stored opt-out',
      );
      expect(installPrefs.enabled, isFalse, reason: 'it was not carried over');
    });

    test('an opt-IN from the old store is NOT carried across profiles', () async {
      // The old keys are per profile, so a `true` in one says nothing about
      // another — while an opt-out anywhere is a choice to respect
      // everywhere. Only the direction that sends no packet travels.
      SharedPreferences.setMockInitialValues({
        kUpdateCheckEnabledPrefKey: true,
      });
      final container = withInstallPrefs();
      addTearDown(container.dispose);

      await container.read(updateCheckEnabledProvider.notifier).resolved();

      expect(installPrefs.enabled, isNull, reason: 'a true was written in');
    });

    test('the old stamp is carried, so the throttle is not reset', () async {
      final earlier = DateTime(2026, 8, 26, 9);
      SharedPreferences.setMockInitialValues({
        kUpdateLastCheckPrefKey: earlier.millisecondsSinceEpoch,
      });
      final container = withInstallPrefs();
      addTearDown(container.dispose);
      final asked = <Uri>[];

      await container.read(appUpdateProvider.notifier).checkIfDue(
            now: earlier.add(const Duration(hours: 1)),
            checker: answering(body, asked: asked),
          );

      expect(
        asked,
        isEmpty,
        reason: 'the upgrade reset the daily throttle and let a check out',
      );
    });

    test('and a later stamp already here is not moved backwards', () async {
      final earlier = DateTime(2026, 8, 26, 9);
      final later = DateTime(2026, 8, 26, 20);
      installPrefs.lastCheck = later;
      SharedPreferences.setMockInitialValues({
        kUpdateLastCheckPrefKey: earlier.millisecondsSinceEpoch,
      });
      final container = withInstallPrefs();
      addTearDown(container.dispose);

      await container.read(updateCheckEnabledProvider.notifier).resolved();

      expect(installPrefs.lastCheck, later);
    });

    test('running it again takes nothing away', () async {
      // There is no "already migrated" marker: the carry is idempotent by
      // construction, and a marker that guards nothing is persisted state that
      // can be wrong. What must hold is this — somebody who turns checks back
      // ON keeps them on, however many times the carry runs.
      SharedPreferences.setMockInitialValues({
        kUpdateCheckEnabledPrefKey: false,
      });
      final first = withInstallPrefs();
      await first.read(updateCheckEnabledProvider.notifier).resolved();
      first.dispose();
      expect(installPrefs.enabled, isFalse);

      installPrefs.enabled = true;
      final second = withInstallPrefs();
      addTearDown(second.dispose);

      await second.read(updateCheckEnabledProvider.notifier).resolved();

      expect(installPrefs.enabled, isTrue);
    });

    test('a stamp that is NEWER than the one here moves it forward', () async {
      // The other direction of the same rule. Without it an upgrade could
      // leave the throttle believing the last check was older than it was, and
      // let one out early.
      final older = DateTime(2026, 8, 26, 9);
      final newer = DateTime(2026, 8, 26, 20);
      installPrefs.lastCheck = older;
      SharedPreferences.setMockInitialValues({
        kUpdateLastCheckPrefKey: newer.millisecondsSinceEpoch,
      });
      final container = withInstallPrefs();
      addTearDown(container.dispose);

      await container.read(updateCheckEnabledProvider.notifier).resolved();

      expect(installPrefs.lastCheck, newer);
    });
  });
}
