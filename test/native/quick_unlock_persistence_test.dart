@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';

import '../support/retirement_secret_store.dart';

// Models the pinned Android plugin's apply(): immediate RAM visibility, separate
// persistence. It never accesses the developer's actual OS credential store.
class _AppliedSecrets {
  static const plugin = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  static const native = MethodChannel('xveil/quick_unlock');
  final memory = <String, String>{}, disk = <String, String>{};
  final flushes = <Map<String, dynamic>>[];
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = false, denyProtectedFlush = false, rejectPlugin = false;
  Object? flushReply = true;

  String namespace(String key, bool biometric) => biometric
      ? 'xveil_quick_bio_v1_${crypto.sha256.convert(utf8.encode(key)).toString().substring(0, 24)}'
      : 'xveil_quick_pattern_v1';

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final options = Map<String, dynamic>.from(args['options'] as Map);
      final key = '${options['storageNamespace']}:${args['key']}';
      switch (call.method) {
        case 'read':
          return memory[key];
        case 'write':
          if (rejectPlugin) throw PlatformException(code: 'synthetic_refusal');
          memory[key] = args['value'] as String;
          return null;
        case 'delete':
          if (rejectPlugin) throw PlatformException(code: 'synthetic_refusal');
          memory.remove(key);
          return null;
        default:
          throw StateError('unexpected fixture plugin operation');
      }
    });
    messenger.setMockMethodCallHandler(native, (call) async {
      expect(call.method, 'flush');
      final args = Map<String, dynamic>.from(call.arguments as Map);
      expect(args.keys.toSet(), {'key', 'biometric'});
      flushes.add(args);
      if (!entered.isCompleted) entered.complete();
      if (hold) await release.future;
      final biometric = args['biometric'] as bool;
      if (biometric && denyProtectedFlush) return false;
      if (flushReply != true) return flushReply;
      final prefix = '${namespace(args['key'] as String, biometric)}:';
      disk.removeWhere((key, _) => key.startsWith(prefix));
      disk.addEntries(memory.entries.where((e) => e.key.startsWith(prefix)));
      return true;
    });
  }

  void restartBackend() {
    memory
      ..clear()
      ..addAll(disk);
  }

  void close() {
    if (!release.isCompleted) release.complete();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(native, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = 'a' * 64;
  final key = 'xveil.quick.v1.$scope';
  late _AppliedSecrets backend;
  QuickUnlockVault vault() => QuickUnlockVault(
    QuickUnlockSecretStore(),
    scope,
    RetirementAuthentication(),
  );
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    backend = _AppliedSecrets()..install();
  });
  tearDown(() {
    backend.close();
    debugDefaultTargetPlatformOverride = null;
  });

  for (final deleting in [false, true]) {
    test(
      'Android ${deleting ? 'delete' : 'write'} waits for persistence',
      () async {
        final address = '${backend.namespace(key, false)}:$key';
        if (deleting) {
          backend.memory[address] = 'synthetic value';
          backend.disk[address] = 'synthetic value';
        }
        backend.hold = true;
        const store = QuickUnlockSecretStore();
        var settled = false;
        final operation =
            (deleting ? store.delete(key) : store.write(key, 'synthetic value'))
                .whenComplete(() => settled = true);
        // No elapsed-time oracle: the old implementation completes the operation
        // without ever requesting a persistence barrier.
        final reachedBarrier = await Future.any([
          backend.entered.future.then((_) => true),
          operation.then((_) => false),
        ]);
        try {
          expect(reachedBarrier, isTrue);
          expect(settled, isFalse);
          expect(backend.memory.containsKey(address), !deleting);
          expect(backend.disk.containsKey(address), deleting);
        } finally {
          backend.release.complete();
        }
        await operation;
        backend.restartBackend();
        expect(await store.read(key), deleting ? null : 'synthetic value');
      },
    );
  }

  for (final reply in [false, null]) {
    test('unconfirmed persistence reply $reply refuses success', () async {
      backend.flushReply = reply;
      await expectLater(
        const QuickUnlockSecretStore().write(key, 'synthetic value'),
        throwsStateError,
      );
      expect(backend.disk, isEmpty);
    });
  }

  test(
    'missing persistence bridge never treats RAM readback as durable',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_AppliedSecrets.native, null);
      await expectLater(
        const QuickUnlockSecretStore().write(key, 'synthetic value'),
        throwsA(isA<MissingPluginException>()),
      );
      expect(backend.memory, isNotEmpty);
      expect(backend.disk, isEmpty);
    },
  );

  test(
    'plugin refusal cannot be turned into success by a later flush',
    () async {
      backend.rejectPlugin = true;
      await expectLater(
        const QuickUnlockSecretStore().delete(key),
        throwsA(isA<PlatformException>()),
      );
      expect(backend.flushes, isEmpty);
    },
  );

  test(
    'failed protected persistence retains cold-recoverable cleanup intent',
    () async {
      await vault().configure(password: 'synthetic password', system: true);
      // The fixture starts with an already persisted enrollment, including
      // when the same test is run against the pre-barrier implementation.
      backend.disk.addAll(backend.memory);
      final protected = backend.disk.keys.singleWhere(
        (key) => key.startsWith('xveil_quick_bio_v1_'),
      );
      backend.denyProtectedFlush = true;
      await expectLater(vault().forget(), throwsStateError);
      expect(backend.disk.containsKey(protected), isTrue);
      backend.restartBackend();
      final pending =
          jsonDecode(backend.disk['${backend.namespace(key, false)}:$key']!)
              as Map;
      expect(pending['bioPending'], isTrue);
      expect(pending['system'], isFalse);
      expect((await vault().options()).enabled, isFalse);
      backend.denyProtectedFlush = false;
      await vault().forget();
      backend.restartBackend();
      expect(backend.disk, isEmpty);
      expect(backend.memory, isEmpty);
    },
  );

  test(
    'native payload survives unconfirmed Android credential removal',
    () async {
      final fixture = Directory.systemTemp.createTempSync(
        'xveil-vault-persist-',
      );
      ManagedRootErasure? erasure;
      try {
        final profile = '${fixture.path}/profile';
        expect(
          const ManagedFsPlatform().createPrivateDirectory(profile),
          isTrue,
        );
        final owner = ManagedDirectoryCatalog.createOrOpen(profile);
        final id = ManagedIdentityId('1' * 32);
        try {
          final data = ManagedIdentityFiles.createUnencrypted(owner, id: id);
          try {
            data.commit([
              PutOp(1, Uint8List.fromList([1]), Uint8List.fromList([2, 3, 4])),
            ]);
          } finally {
            data.close();
          }
        } finally {
          owner.close();
        }
        final payloads = <String, List<int>>{
          for (final file in Directory(
            '$profile/identities',
          ).listSync(recursive: true))
            if (file is File) file.path: file.readAsBytesSync(),
        };
        expect(payloads, isNotEmpty);
        final exclusive = ManagedDirectoryCatalog.openExclusiveMaintenance(
          profile,
        )!;
        try {
          await ManagedRootErasure.prepare(
            exclusive,
            unlockScopes: StorageUnlockScopes([scope]),
          );
        } finally {
          exclusive.close();
        }
        erasure = ManagedRootErasure.openPending(profile);
        final store = QuickUnlockSecretStore();
        await QuickUnlockVault(
          store,
          scope,
          RetirementAuthentication(),
        ).configure(password: 'synthetic password', system: true);
        backend.disk.addAll(backend.memory);
        final retirement = QuickUnlockRetirement.forManagedErasure(
          erasure,
          store,
          RetirementAuthentication(),
        );
        backend.denyProtectedFlush = true;
        await expectLater(
          erasure.removeManagedFiles(retireScopes: (_) => retirement.retire()),
          throwsA(isA<QuickUnlockRetirementFailure>()),
        );
        for (final entry in payloads.entries) {
          expect(File(entry.key).readAsBytesSync(), entry.value);
        }
        expect(erasure.phase, ManagedRootErasurePhase.removing);
        backend.denyProtectedFlush = false;
        await erasure.removeManagedFiles(
          retireScopes: (_) => retirement.retire(),
        );
        await erasure.finish(verifyOtherDataAbsent: retirement.verifyAbsent);
        expect(Directory('$profile/identities').existsSync(), isFalse);
        expect(backend.disk, isEmpty);
      } finally {
        erasure?.close();
        fixture.deleteSync(recursive: true);
      }
    },
  );
}
