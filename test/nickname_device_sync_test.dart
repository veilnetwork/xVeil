import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/device_settings_sync.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/nickname_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_setting_storage.dart';

ProviderContainer _device(FakeSettingStorage storage) => ProviderContainer(
  overrides: [
    storageProvider.overrideWithValue(storage),
    // The public-name lookup is best effort and may be unavailable while a
    // device catches up. A mirrored claim must still be visible and durable.
    messagingServiceProvider.overrideWith(
      (ref) => throw StateError('network offline'),
    ),
  ],
);

Future<void> _loaded() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'a sibling applies a claim live, without an echo, and keeps it on restart',
    () async {
      final storage = FakeSettingStorage();
      final device = _device(storage);
      addTearDown(device.dispose);
      final hub = device.read(deviceSettingsSyncHubProvider);
      var echoes = 0;
      hub.onLocalSet = (_, _) => echoes++;
      hub.register(
        kSyncNicknameClaim,
        (raw) => device
            .read(nicknameControllerProvider.notifier)
            .applyMirroredClaim(raw),
      );

      const raw = '{"name":"alice","weight":9}';
      expect(await hub.applyIncoming(kSyncNicknameClaim, raw), isTrue);
      expect(device.read(nicknameControllerProvider).ownedName, 'alice');
      expect(device.read(nicknameControllerProvider).ownedWeight, 9);
      expect(storage.settings[kSyncNicknameClaim], raw);
      expect(echoes, 0);

      final restarted = _device(storage);
      addTearDown(restarted.dispose);
      restarted.read(nicknameControllerProvider);
      await _loaded();
      expect(restarted.read(nicknameControllerProvider).ownedName, 'alice');
      expect(restarted.read(nicknameControllerProvider).ownedWeight, 9);
    },
  );

  test(
    'an older same-name event cannot lower the stored claim weight',
    () async {
      final storage = FakeSettingStorage()
        ..settings[kSyncNicknameClaim] = '{"name":"alice","weight":17}';
      final device = _device(storage);
      addTearDown(device.dispose);

      await device
          .read(nicknameControllerProvider.notifier)
          .applyMirroredClaim('{"name":"alice","weight":9}');
      expect(device.read(nicknameControllerProvider).ownedName, 'alice');
      expect(device.read(nicknameControllerProvider).ownedWeight, 17);
      expect(storage.settings[kSyncNicknameClaim], contains('"weight":17'));
    },
  );

  test('invalid or oversized claim events are ignored', () async {
    final storage = FakeSettingStorage();
    final device = _device(storage);
    addTearDown(device.dispose);
    final notifier = device.read(nicknameControllerProvider.notifier);
    for (final raw in [
      '{"name":" alice","weight":1}',
      '{"name":"alice","weight":-1}',
      '{"name":"alice","weight":1.5}',
      '{"name":"${'я' * 1100}","weight":1}',
      'not json',
    ]) {
      expect(parseClaimedNickname(raw), isNull);
      await notifier.applyMirroredClaim(raw);
    }
    expect(device.read(nicknameControllerProvider).ownedName, isNull);
    expect(storage.settings[kSyncNicknameClaim], isNull);
  });
}
