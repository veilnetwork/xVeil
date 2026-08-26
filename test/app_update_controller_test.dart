import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a stored opt-out is honoured on the very first launch', () async {
    // The setting exists to stop an outbound connection to github.com that
    // says this device runs xVeil. It is loaded asynchronously, and the
    // automatic check runs when the app becomes usable — which can be first.
    // Reading the provider optimistically answered "on" for somebody who had
    // turned it off, and the request went out before their choice arrived.
    SharedPreferences.setMockInitialValues({
      kUpdateCheckEnabledPrefKey: false,
    });
    final container = ProviderContainer();
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
    SharedPreferences.setMockInitialValues({kUpdateCheckEnabledPrefKey: true});
    final container = ProviderContainer();
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
    SharedPreferences.setMockInitialValues({kUpdateCheckEnabledPrefKey: true});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final asked = <Uri>[];

    await container.read(updateCheckEnabledProvider.notifier).set(false);
    await container
        .read(appUpdateProvider.notifier)
        .checkIfDue(checker: answering(body, asked: asked));

    expect(asked, isEmpty);
  });

  test('the first run asks and remembers that it did', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final asked = <Uri>[];

    await container
        .read(appUpdateProvider.notifier)
        .checkIfDue(checker: answering(body, asked: asked));

    expect(asked, hasLength(1));
    expect(container.read(appUpdateProvider)?.tag, 'v9.9.9');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(kUpdateLastCheckPrefKey), isNotNull);
  });

  test('a second launch the same day does not ask again', () async {
    final container = ProviderContainer();
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
    final container = ProviderContainer();
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
    final container = ProviderContainer();
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
    final container = ProviderContainer();
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
    final first = ProviderContainer();
    await first.read(updateCheckEnabledProvider.notifier).set(false);
    first.dispose();

    final second = ProviderContainer();
    addTearDown(second.dispose);
    // The notifier loads asynchronously; read once to build it, then settle.
    second.read(updateCheckEnabledProvider);
    await Future<void>.delayed(Duration.zero);

    expect(second.read(updateCheckEnabledProvider), isFalse);
  });

  test('pressing check now ignores the interval', () async {
    final container = ProviderContainer();
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
    final container = ProviderContainer();
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
    final container = ProviderContainer();
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
}
