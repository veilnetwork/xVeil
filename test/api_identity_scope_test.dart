import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/api_server.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/providers.dart';

late Storage _activeStorage;
late Identity _initialIdentity;

class _SwitchingAppController extends AppController {
  @override
  AppState build() => AppState(AppPhase.ready, identity: _initialIdentity);

  void expose(Identity identity, Storage storage) {
    _activeStorage = storage;
    ref.invalidate(storageProvider);
    state = AppState(AppPhase.ready, identity: identity);
  }

  void exposeLocked() {
    state = const AppState(AppPhase.locked);
  }
}

Future<HiddenVolumeStorage> _storageWithToken(String token) async {
  final log = FakeKvLogStore();
  final storage = HiddenVolumeStorage(
    ({required Uint8List password, required bool create}) => log,
  );
  expect(await storage.open(password: 'pw', createIfMissing: true), isTrue);
  await storage.putSetting(
    'api.tokens',
    jsonEncode([
      {'id': token, 'name': token, 'token': token, 'ro': false},
    ]),
  );
  await storage.putSetting('api.enabled', '0');
  return storage;
}

Future<void> _waitForToken(ProviderContainer container, String token) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final tokens = container.read(apiServerControllerProvider).tokens;
    if (tokens.any((entry) => entry.token == token)) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('API config did not switch to token $token');
}

void main() {
  test(
    'API tokens reload by node id and disappear when identity locks',
    () async {
      final first = await _storageWithToken('token-a');
      final second = await _storageWithToken('token-b');
      addTearDown(first.close);
      addTearDown(second.close);
      _activeStorage = first;
      _initialIdentity = Identity(
        nodeId: NodeId.fromHex('11' * 32),
        displayName: 'A',
      );
      final secondIdentity = Identity(
        nodeId: NodeId.fromHex('22' * 32),
        displayName: 'B',
      );
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_SwitchingAppController.new),
          storageProvider.overrideWith((ref) => _activeStorage),
          groupServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      container.read(apiServerControllerProvider);
      await _waitForToken(container, 'token-a');
      expect(
        container.read(apiServerControllerProvider).tokens.single.token,
        'token-a',
      );

      final app =
          container.read(appControllerProvider.notifier)
              as _SwitchingAppController;
      app.expose(secondIdentity, second);
      await _waitForToken(container, 'token-b');
      expect(
        container.read(apiServerControllerProvider).tokens.single.token,
        'token-b',
      );

      app.exposeLocked();
      for (var attempt = 0; attempt < 100; attempt++) {
        if (container.read(apiServerControllerProvider).tokens.isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(container.read(apiServerControllerProvider), ApiConfig.empty);
      expect(
        container.read(apiServerControllerProvider.notifier).running,
        isFalse,
      );
    },
  );
}
