import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';

class _Authentication extends LocalScreenAuthentication {
  int calls = 0;
  bool allowed = true;
  @override
  Future<bool> authenticate(String reason) async {
    calls++;
    return allowed;
  }
}

class _ReadStore extends QuickUnlockSecretStore {
  int reads = 0;
  @override
  Future<String?> read(String key, {bool biometric = false}) async {
    expect(biometric, isTrue);
    reads++;
    return 'fixture-password';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final values = <String, String>{};
  final protectedNamespaces = <String>{};
  var denyAuthentication = false;
  var authenticatedReads = 0;
  const authenticatedChannel = MethodChannel('xveil/quick_unlock');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    values.clear();
    protectedNamespaces.clear();
    denyAuthentication = false;
    authenticatedReads = 0;
    messenger.setMockMethodCallHandler(authenticatedChannel, (call) async {
      expect(call.method, 'read');
      authenticatedReads++;
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      final key = arguments['key'] as String;
      final namespace =
          'xveil_quick_bio_v1_${crypto.sha256.convert(utf8.encode(key)).toString().substring(0, 24)}';
      if (denyAuthentication) return null;
      return values['$namespace:$key'];
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      final options = Map<String, dynamic>.from(arguments['options'] as Map);
      final namespace = options['storageNamespace'] as String;
      final key = '$namespace:${arguments['key']}';
      if (namespace.startsWith('xveil_quick_bio_v1_')) {
        protectedNamespaces.add(namespace);
        expect(options['keyCipherAlgorithm'], 'AES_GCM_NoPadding');
        expect(options['storageCipherAlgorithm'], 'AES_GCM_NoPadding');
        expect(options['enforceBiometrics'], 'true');
        expect(options['biometricType'], 'strongBiometricOnly');
        expect(options['resetOnError'], 'false');
        // Native 10.3.4 treats a marker-less namespace as a legacy algorithm.
        // This is the refusal observed on the physical phone, not a crypto mock.
        if (options['migrateOnAlgorithmChange'] != 'true') {
          throw PlatformException(
            code: 'Exception encountered',
            message: 'Key mismatch after algorithm change; migration disabled',
          );
        }
        if (denyAuthentication) {
          throw PlatformException(
            code: 'Exception encountered',
            message: 'Biometric authentication cancelled',
          );
        }
      }
      switch (call.method) {
        case 'write':
          values[key] = arguments['value'] as String;
          return null;
        case 'read':
          return values[key];
        case 'delete':
          values.remove(key);
          return null;
        default:
          throw StateError('Unexpected secret-store operation');
      }
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(authenticatedChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'Android cold and warm opens use one native authenticated read each',
    () async {
      final auth = _Authentication();
      QuickUnlockVault vault() => QuickUnlockVault(
        const QuickUnlockSecretStore(),
        'single-prompt',
        auth,
      );
      await vault().configure(password: 'fixture-password', system: true);
      final active = vault();
      expect(await active.openSystem('fixture'), 'fixture-password');
      expect(await active.openSystem('fixture'), 'fixture-password');
      expect(await vault().openSystem('fixture'), 'fixture-password');
      expect(
        auth.calls,
        0,
        reason: 'native CryptoObject read already authenticates',
      );
      expect(
        authenticatedReads,
        3,
        reason: 'warm reads must also authenticate',
      );
      denyAuthentication = true;
      expect(await active.openSystem('fixture'), isNull);
      expect(authenticatedReads, 4);
    },
  );

  test(
    'Android missing authenticated bridge never falls back to cached read',
    () async {
      final auth = _Authentication();
      final active = QuickUnlockVault(
        const QuickUnlockSecretStore(),
        'missing-bridge',
        auth,
      );
      await active.configure(password: 'fixture-password', system: true);
      messenger.setMockMethodCallHandler(authenticatedChannel, null);
      await expectLater(
        active.openSystem('fixture'),
        throwsA(isA<MissingPluginException>()),
      );
      expect(auth.calls, 0);
    },
  );

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    test('$platform still requires explicit OS authentication', () async {
      debugDefaultTargetPlatformOverride = platform;
      final store = _ReadStore();
      final auth = _Authentication()..allowed = false;
      expect(
        await store.readAuthenticated('fixture-key', 'fixture', auth),
        isNull,
      );
      expect(store.reads, 0);
      auth.allowed = true;
      expect(
        await store.readAuthenticated('fixture-key', 'fixture', auth),
        'fixture-password',
      );
      expect(auth.calls, 2);
      expect(store.reads, 1);
    });
  }

  test('forget rejects a late successful Android protected read', () async {
    final active = QuickUnlockVault(
      const QuickUnlockSecretStore(),
      'late-native',
      _Authentication(),
    );
    await active.configure(password: 'fixture-password', system: true);
    final credential = values.entries
        .singleWhere((e) => e.key.startsWith('xveil_quick_bio_v1_'))
        .value;
    final started = Completer<void>();
    final release = Completer<String?>();
    messenger.setMockMethodCallHandler(authenticatedChannel, (call) {
      started.complete();
      return release.future;
    });
    final opening = active.openSystem('fixture');
    await started.future;
    await active.forget();
    release.complete(credential);
    expect(await opening, isNull);
    expect(values, isEmpty);
  });

  test(
    'fresh biometric namespace initializes without weakening its cipher policy',
    () async {
      const store = QuickUnlockSecretStore();
      await store.write('fixture-new-slot', 'fixture-value', biometric: true);
      expect(
        await store.read('fixture-new-slot', biometric: true),
        'fixture-value',
      );
      await store.delete('fixture-new-slot', biometric: true);
      expect(
        await store.contains('fixture-new-slot', biometric: true),
        isFalse,
      );
      expect(protectedNamespaces, hasLength(1));
    },
  );

  test(
    'fresh configuration and a recreated vault restore the protected password',
    () async {
      const password = 'public fixture password';
      QuickUnlockVault vault() => QuickUnlockVault(
        const QuickUnlockSecretStore(),
        'fixture-profile',
        _Authentication(),
      );
      await vault().configure(password: password, system: true);
      expect((await vault().options()).system, isTrue);
      expect(await vault().openSystem('fixture'), password);
      await vault().configure(password: password, system: true);
      expect(
        protectedNamespaces,
        hasLength(2),
        reason: 're-enrollment creates a distinct authenticated namespace',
      );
      await vault().forget();
      expect((await vault().options()).enabled, isFalse);
    },
  );

  test(
    'refused biometric authentication cannot publish a configured credential',
    () async {
      final vault = QuickUnlockVault(
        const QuickUnlockSecretStore(),
        'fixture-cancel',
        _Authentication(),
      );
      denyAuthentication = true;
      await expectLater(
        vault.configure(password: 'fixture-password', system: true),
        throwsA(isA<PlatformException>()),
      );
      expect((await vault.options()).system, isFalse);
      expect(
        values.entries.where(
          (entry) => entry.key.startsWith('xveil_quick_bio_v1_'),
        ),
        isEmpty,
      );
      denyAuthentication = false;
      await vault.forget();
      expect(values, isEmpty);
    },
  );
}
