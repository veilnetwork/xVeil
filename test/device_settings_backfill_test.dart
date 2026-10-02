import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/state/device_settings_sync.dart';
import 'package:xveil/state/locale_controller.dart';
import 'package:xveil/state/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'only explicit pre-link preferences seed an empty device group',
    () async {
      SharedPreferences.setMockInitialValues({
        kSyncShowReactions: false,
        kSyncLocale: 'ru',
        kSyncSignaturePolicy: 'refuse',
        'theme_chosen': 'dark',
      });
      final stored = storedDeviceSyncPreferences(
        await SharedPreferences.getInstance(),
      );
      expect(stored, {
        kSyncShowReactions: '0',
        kSyncLocale: 'ru',
        kSyncSignaturePolicy: 'refuse',
      });
      expect(devicePreferencesNeedingBackfill(stored, const {}), stored);
    },
  );

  test(
    'a folded sibling choice is not overwritten by stale local prefs',
    () async {
      SharedPreferences.setMockInitialValues({
        kSyncShowReactions: true,
        kSyncLocale: 'en',
        kSyncSignaturePolicy: 'auto',
      });
      final stored = storedDeviceSyncPreferences(
        await SharedPreferences.getInstance(),
      );
      final folded = foldDeviceSync([
        DeviceSyncEvent(
          kind: DeviceSyncKind.settingSet,
          key: kSyncShowReactions,
          tsMs: 100,
          payload: const {'v': '0'},
        ),
        DeviceSyncEvent(
          kind: DeviceSyncKind.settingSet,
          key: kSyncSignaturePolicy,
          tsMs: 101,
          payload: const {'v': 'ask'},
        ),
      ]);
      expect(devicePreferencesNeedingBackfill(stored, folded), {
        kSyncLocale: 'en',
      });
    },
  );

  test(
    'defaults and unrecognized policy do not claim group settings',
    () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        storedDeviceSyncPreferences(await SharedPreferences.getInstance()),
        isEmpty,
      );
      SharedPreferences.setMockInitialValues({
        kSyncShowReactions: 'bad type',
        kSyncLocale: 'ru',
      });
      expect(
        storedDeviceSyncPreferences(await SharedPreferences.getInstance()),
        {kSyncLocale: 'ru'},
      );
      SharedPreferences.setMockInitialValues({kSyncSignaturePolicy: 'future'});
      expect(
        storedDeviceSyncPreferences(await SharedPreferences.getInstance()),
        isEmpty,
      );
    },
  );

  test(
    'incoming locale survives an older asynchronous preference load',
    () async {
      SharedPreferences.setMockInitialValues({kSyncLocale: 'en'});
      final oldPrefs = await SharedPreferences.getInstance();
      final gate = Completer<SharedPreferences>();
      final device = ProviderContainer(
        overrides: [prefsProvider.overrideWith((ref) => gate.future)],
      );
      addTearDown(device.dispose);
      expect(device.read(localeProvider), isNull);

      final applied = device
          .read(localeProvider.notifier)
          .setLocale(const Locale('ru'));
      gate.complete(oldPrefs);
      await applied;
      await pumpEventQueue();
      expect(device.read(localeProvider), const Locale('ru'));
      expect(oldPrefs.getString(kSyncLocale), 'ru');
    },
  );
}
