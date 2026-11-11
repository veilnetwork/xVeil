import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

late Storage _active;
class _Messaging implements MessagingService {
  @override
  Stream<IncomingNotice> get incoming => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
class _App extends AppController {
  @override
  AppState build() => AppState(AppPhase.ready,
    identity: Identity(nodeId: NodeId.fromHex('11' * 32), displayName: 'A'));
  void switchTo(Storage storage) {
    _active = storage;
    ref.invalidate(storageProvider);
    state = AppState(AppPhase.ready,
      identity: Identity(nodeId: NodeId.fromHex('22' * 32), displayName: 'B'));
  }
}

class _HeldStore extends HiddenVolumeStorage {
  _HeldStore(FakeKvLogStore log)
    : super(({required Uint8List password, required bool create}) => log);
  String? holdKey;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> putSetting(String key, String value) async {
    await super.putSetting(key, value);
    if (key == holdKey) {
      entered.complete();
      await release.future;
    }
  }
}

Future<void> _until(bool Function() check) async {
  for (var i = 0; i < 500 && !check(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(check(), isTrue, reason: 'test precondition did not settle');
}

Future<_HeldStore> _store(String id, {required bool enabled, bool token = true}) async {
  final storage = _HeldStore(FakeKvLogStore());
  expect(await storage.open(password: 'fixture', createIfMissing: true), isTrue);
  await storage.putSetting('api.enabled', enabled ? '1' : '0');
  await storage.putSetting('api.tokens', jsonEncode([
    if (token) {'id': id, 'name': id, 'token': id, 'ro': false},
  ]));
  await storage.putSetting('api.webhook', 'http://127.0.0.1:1/$id');
  return storage;
}

void main() {
  setUp(() => ApiServerController.debugBindPort = 0);
  tearDown(() => ApiServerController.debugBindPort = kApiPort);
  for (final scenario in ['enable-existing', 'enable-new-token', 'disable']) {
    test('late $scenario for A cannot change B opt-in or listener', () async {
      final disable = scenario == 'disable';
      final newToken = scenario == 'enable-new-token';
      final a = await _store('token-a', enabled: disable, token: !newToken);
      final b = await _store('token-b', enabled: disable);
      addTearDown(a.close);
      addTearDown(b.close);
      _active = a;
      final providers = ProviderContainer(overrides: [
        appControllerProvider.overrideWith(_App.new),
        storageProvider.overrideWith((ref) => _active),
        groupServiceProvider.overrideWithValue(null),
        messagingServiceProvider.overrideWithValue(_Messaging()),
        realStackProvider.overrideWith((ref) => null),
      ]);
      addTearDown(providers.dispose);
      providers.read(apiServerControllerProvider);
      final controller = providers.read(apiServerControllerProvider.notifier);
      await _until(() => providers.read(apiServerControllerProvider).webhookUrl?.endsWith('/token-a') ?? false);
      if (disable) await _until(() => controller.boundPort != null);
      a.holdKey = newToken ? 'api.tokens' : 'api.enabled';
      final pending = disable ? controller.disable() : controller.enable();
      await a.entered.future;
      (providers.read(appControllerProvider.notifier) as _App).switchTo(b);
      await _until(() => providers.read(apiServerControllerProvider).tokens.singleOrNull?.id == 'token-b');
      if (disable) await _until(() => controller.boundPort != null);
      a.release.complete();
      await pending;
      expect(await b.getSetting('api.enabled'), disable ? '1' : '0');
      expect(providers.read(apiServerControllerProvider).enabled, disable);
      expect(controller.running, disable);
      if (disable) {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final request = await client.getUrl(Uri.parse('http://127.0.0.1:${controller.boundPort}/v1/account'));
        request.headers.set('Authorization', 'Bearer token-b');
        final response = await request.close();
        expect(response.statusCode, 200);
        expect(jsonDecode(await utf8.decodeStream(response))['nodeId'], '22' * 32);
      }
    });
  }
}
