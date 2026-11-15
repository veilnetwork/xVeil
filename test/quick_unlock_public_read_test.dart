import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/quick_unlock_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('xveil/quick_unlock');
  const plugin = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const key = 'xveil.quick.v1.synthetic';
  var pluginCalls = 0;
  final requests = <MethodCall>[];
  String? value;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    pluginCalls = 0;
    requests.clear();
    value = null;
    messenger.setMockMethodCallHandler(plugin, (_) async {
      pluginCalls++;
      throw PlatformException(code: 'synthetic_initializer_would_mutate');
    });
    messenger.setMockMethodCallHandler(native, (call) async {
      requests.add(call);
      expect(call.method, 'readPublic');
      expect(call.arguments, {'key': key, 'biometric': false});
      return value;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(native, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final existing in [false, true]) {
    test(
      'public read existing=$existing avoids plugin initialization',
      () async {
        value = existing ? 'synthetic metadata' : null;
        expect(await const QuickUnlockSecretStore().read(key), value);
        expect(requests, hasLength(1));
        expect(pluginCalls, 0);
      },
    );
  }

  test('missing read-only bridge never falls back to initialization', () async {
    messenger.setMockMethodCallHandler(native, null);
    await expectLater(
      const QuickUnlockSecretStore().read(key),
      throwsA(isA<MissingPluginException>()),
    );
    expect(pluginCalls, 0);
  });

  test('unreadable existing metadata stays an error', () async {
    messenger.setMockMethodCallHandler(native, (_) async {
      throw PlatformException(code: 'record_store_unreadable');
    });
    await expectLater(
      const QuickUnlockSecretStore().read(key),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'record_store_unreadable',
        ),
      ),
    );
    expect(pluginCalls, 0);
  });

  test('accepted public read waits for the native reply', () async {
    final entered = Completer<void>(), release = Completer<String?>();
    messenger.setMockMethodCallHandler(native, (_) {
      entered.complete();
      return release.future;
    });
    var completed = false;
    final read = const QuickUnlockSecretStore()
        .read(key)
        .whenComplete(() => completed = true);
    await entered.future;
    expect(completed, isFalse);
    expect(pluginCalls, 0);
    release.complete('synthetic metadata');
    expect(await read, 'synthetic metadata');
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    test('$platform keeps its existing credential reader', () async {
      debugDefaultTargetPlatformOverride = platform;
      messenger.setMockMethodCallHandler(plugin, (call) async {
        pluginCalls++;
        expect(call.method, 'read');
        return 'synthetic metadata';
      });
      expect(
        await const QuickUnlockSecretStore().read(key),
        'synthetic metadata',
      );
      expect(pluginCalls, 1);
      expect(requests, isEmpty);
    });
  }
}
