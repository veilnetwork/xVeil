import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/quick_unlock_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const plugin = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const native = MethodChannel('xveil/quick_unlock');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final key = 'xveil.quick.v1.${'a' * 64}.bio.synthetic';
  final calls = <MethodCall>[];
  var cipherOperations = 0;
  bool? presence;
  Object? removal;
  Completer<void>? removalEntered, removalRelease;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    cipherOperations = 0;
    presence = false;
    removal = true;
    removalEntered = removalRelease = null;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      cipherOperations++;
      // FSS initializes its cipher before read, containsKey and delete, even
      // for absent records. Model a cold/inaccessible biometric key here.
      throw PlatformException(code: 'synthetic_cipher_unavailable');
    });
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call);
      expect(Map<String, dynamic>.from(call.arguments as Map), {
        'key': key,
        'biometric': true,
      });
      switch (call.method) {
        case 'contains':
          return presence;
        case 'remove':
          removalEntered?.complete();
          await removalRelease?.future;
          return removal;
        default:
          fail('Unexpected native saved-entry operation');
      }
    });
  });
  tearDown(() {
    if (removalRelease case final gate?) {
      if (!gate.isCompleted) gate.complete();
    }
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(native, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final exists in [false, true]) {
    test(
      'raw record presence $exists needs no cipher initialization',
      () async {
        presence = exists;
        expect(
          await const QuickUnlockSecretStore().contains(key, biometric: true),
          exists,
        );
        expect(calls.single.method, 'contains');
        expect(cipherOperations, 0);
      },
    );
  }

  test('unknown raw presence never means absence', () async {
    presence = null;
    await expectLater(
      const QuickUnlockSecretStore().contains(key, biometric: true),
      throwsStateError,
    );
    expect(cipherOperations, 0);
  });

  test('missing presence bridge has no decrypting or empty fallback', () async {
    messenger.setMockMethodCallHandler(native, null);
    await expectLater(
      const QuickUnlockSecretStore().contains(key, biometric: true),
      throwsA(isA<MissingPluginException>()),
    );
    expect(cipherOperations, 0);
  });

  test('explicit removal settles only after native commit', () async {
    removalEntered = Completer<void>();
    removalRelease = Completer<void>();
    var completed = false;
    final deleting = const QuickUnlockSecretStore()
        .delete(key, biometric: true)
        .then<Object?>((_) {
          completed = true;
          return null;
        }, onError: (Object error) => error);
    final entered = await Future.any([
      removalEntered!.future.then((_) => true),
      deleting.then((_) => false),
    ]);
    try {
      expect(entered, isTrue);
      expect(completed, isFalse);
      expect(cipherOperations, 0);
    } finally {
      removalRelease!.complete();
    }
    expect(await deleting, isNull);
    expect(completed, isTrue);
  });

  for (final reply in [false, null]) {
    test('unconfirmed native removal $reply refuses success', () async {
      removal = reply;
      await expectLater(
        const QuickUnlockSecretStore().delete(key, biometric: true),
        throwsStateError,
      );
      expect(cipherOperations, 0);
    });
  }

  test('missing removal bridge cannot initialize or reset a cipher', () async {
    messenger.setMockMethodCallHandler(native, null);
    await expectLater(
      const QuickUnlockSecretStore().delete(key, biometric: true),
      throwsA(isA<MissingPluginException>()),
    );
    expect(cipherOperations, 0);
  });

  for (final deleting in [false, true]) {
    test(
      'unreadable record store refuses ${deleting ? 'removal' : 'presence'}',
      () async {
        messenger.setMockMethodCallHandler(native, (call) async {
          throw PlatformException(code: 'record_store_unreadable');
        });
        await expectLater(
          deleting
              ? const QuickUnlockSecretStore().delete(key, biometric: true)
              : const QuickUnlockSecretStore().contains(key, biometric: true),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'record_store_unreadable',
            ),
          ),
        );
        expect(cipherOperations, 0);
      },
    );
  }

  test('Darwin keeps the matching local-only read policy', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      expect(call.method, 'read');
      cipherOperations++;
      return 'synthetic existing value';
    });
    expect(
      await const QuickUnlockSecretStore().contains(key, biometric: true),
      isTrue,
    );
    expect(calls, isEmpty);
    expect(cipherOperations, 1);
  });
}
