import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';

class _Authentication extends LocalScreenAuthentication {
  @override
  Future<bool> authenticate(String reason) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final values = <String, String>{};
  final protectedNamespaces = <String>{};
  var denyAuthentication = false;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    values.clear();
    protectedNamespaces.clear();
    denyAuthentication = false;
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
    debugDefaultTargetPlatformOverride = null;
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
