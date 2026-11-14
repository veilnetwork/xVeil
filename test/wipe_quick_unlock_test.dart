import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/startup_unlock.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';
import 'support/fake_hv_container.dart';

class _SecretStore extends QuickUnlockSecretStore {
  final values = <String, String>{};
  bool refuseDelete = false, refuseRead = false;
  Completer<void>? bioWriteEntered, bioWriteRelease;
  String key(String value, bool biometric) => '$biometric:$value';
  @override
  Future<String?> read(String key, {bool biometric = false}) async {
    if (refuseRead) throw StateError('synthetic OS refusal');
    return values[this.key(key, biometric)];
  }

  @override
  Future<void> write(String key, String value, {bool biometric = false}) async {
    if (biometric && bioWriteRelease != null) {
      if (!bioWriteEntered!.isCompleted) bioWriteEntered!.complete();
      await bioWriteRelease!.future;
    }
    values[this.key(key, biometric)] = value;
  }

  @override
  Future<void> delete(String key, {bool biometric = false}) async {
    if (!refuseDelete) values.remove(this.key(key, biometric));
  }

  @override
  Future<bool> contains(String key, {bool biometric = false}) async =>
      values.containsKey(this.key(key, biometric));
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _Vpn implements VpnBackend {
  @override
  Future<VpnBackendState> probe() => status();
  @override
  Future<VpnBackendState> status() async =>
      const VpnBackendState(VpnBackendPhase.unsupported);
  @override
  Future<VpnBackendState> stop() => status();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ObservedVault extends QuickUnlockVault {
  _ObservedVault(super.store, super.scope, super.authentication);
  final forgetting = Completer<void>();
  @override
  Future<void> forget() {
    if (!forgetting.isCompleted) forgetting.complete();
    return super.forget();
  }
}

Future<List<String>> _runWipe(
  QuickUnlockVault vault, {
  String? legacyPath,
}) async {
  final temp = Directory.systemTemp.createTempSync('xveil-wipe-quick-');
  final storage = FakeHvContainer().storage();
  final app = ProviderContainer(
    overrides: [
      singleSpaceStorageProvider.overrideWithValue(storage),
      quickUnlockVaultProvider.overrideWithValue(vault),
      notificationServiceProvider.overrideWithValue(_Notifications()),
      vpnBackendProvider.overrideWithValue(_Vpn()),
      whisperModelStoreProvider.overrideWithValue(
        WhisperModelStore(supportDirectory: () async => temp),
      ),
      translationModelsRootProvider.overrideWithValue(() async => null),
      if (legacyPath != null)
        deniableBootProvider.overrideWithValue(
          DeniableBootConfig(
            runtimeDir: '${temp.path}/unused-runtime',
            storePath: legacyPath,
          ),
        ),
    ],
  );
  try {
    final ctrl = app.read(appControllerProvider.notifier);
    await app.read(prefsProvider.future);
    return await ctrl.wipeContainers();
  } finally {
    app.dispose();
    await storage.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final flag in [null, false, true]) {
    for (final refuses in [false, true]) {
      test(
        'wipe verifies OS credential deletion with opt-in=$flag refusal=$refuses',
        () async {
          SharedPreferences.setMockInitialValues({
            kStartupUnlockOptIn: ?flag,
          });
          final store = _SecretStore();
          final vault = QuickUnlockVault(
            store,
            'synthetic-wipe-scope',
            LocalScreenAuthentication(),
          );
          await vault.configure(
            password: 'synthetic original password',
            system: true,
          );
          expect((await vault.options()).enabled, isTrue);
          store.refuseDelete = refuses;
          final remaining = await _runWipe(vault);
          expect(
            remaining.contains('quick-unlock'),
            refuses,
            reason: 'a UI preference is not a witness of OS-vault absence',
          );
          expect(store.values.isEmpty, !refuses);
          if (!refuses) {
            expect((await vault.options()).enabled, isFalse);
            final prefs = await SharedPreferences.getInstance();
            expect(prefs.containsKey(kStartupUnlockOptIn), isFalse);
          }
        },
      );
    }
  }
  final invalidRecords = <String>[
    '',
    'not-json',
    'null',
    '{}',
    'x' * 16001,
    jsonEncode({'v': 1.0, 'id': 'retained', 'system': false}),
    jsonEncode({'v': 1, 'id': '', 'system': false}),
    jsonEncode({'v': 1, 'id': 'retained', 'system': true, 'bioSlot': ''}),
    jsonEncode({'v': 1, 'id': 'retained', 'system': true, 'bioSlot': 'x' * 65}),
    jsonEncode({'v': 2, 'id': 'retained', 'system': true, 'bioSlot': 'slot'}),
    jsonEncode({'v': 1, 'id': 'retained', 'system': 'yes', 'bioSlot': 'slot'}),
    jsonEncode({'v': 1, 'id': 'retained', 'system': true}),
    jsonEncode({
      'v': 1,
      'id': 'retained',
      'system': false,
      'bioPending': 'yes',
    }),
    jsonEncode({
      'v': 1,
      'id': 'retained',
      'system': false,
      'futureSlot': 'slot',
    }),
  ];
  for (var index = 0; index < invalidRecords.length; index++) {
    for (final action in ['forget', 'configure']) {
      test(
        '$action preserves unreadable OS cleanup metadata case $index',
        () async {
          final store = _SecretStore();
          final vault = QuickUnlockVault(
            store,
            'synthetic-corrupt-scope',
            LocalScreenAuthentication(),
          );
          await vault.configure(
            password: 'synthetic original password',
            system: true,
          );
          final metadata = store.values.keys.singleWhere(
            (k) => k.startsWith('false:'),
          );
          store.values[metadata] = invalidRecords[index];
          final before = Map<String, String>.of(store.values);
          if (action == 'forget') {
            await expectLater(vault.forget(), throwsStateError);
          } else {
            await expectLater(
              vault.configure(password: 'synthetic replacement', system: true),
              throwsStateError,
            );
          }
          expect(
            store.values,
            before,
            reason: 'do not lose the only pointer to the protected slot',
          );
        },
      );
    }
  }
  for (final action in ['forget', 'configure']) {
    test(
      '$action retires a referenced slot even when option flags are off',
      () async {
        final store = _SecretStore();
        final vault = QuickUnlockVault(
          store,
          'synthetic-slot-scope',
          LocalScreenAuthentication(),
        );
        await vault.configure(
          password: 'synthetic original password',
          system: true,
        );
        final metadata = store.values.keys.singleWhere(
          (k) => k.startsWith('false:'),
        );
        final oldSlot = store.values.keys.singleWhere(
          (k) => k.startsWith('true:'),
        );
        final parsed =
            jsonDecode(store.values[metadata]!) as Map<String, dynamic>;
        parsed['system'] = false;
        store.values[metadata] = jsonEncode(parsed);
        if (action == 'forget') {
          await vault.forget();
        } else {
          await vault.configure(
            password: 'synthetic replacement',
            system: true,
          );
        }
        expect(store.values.containsKey(oldSlot), isFalse);
      },
    );
  }
  test(
    'wipe revokes an accepted protected write before its opt-in was recorded',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = _SecretStore()
        ..bioWriteEntered = Completer<void>()
        ..bioWriteRelease = Completer<void>();
      final vault = _ObservedVault(
        store,
        'synthetic-pending-scope',
        LocalScreenAuthentication(),
      );
      final configuring = vault.configure(
        password: 'synthetic pending password',
        system: true,
      );
      final rejected = expectLater(configuring, throwsStateError);
      await store.bioWriteEntered!.future;
      final wiping = _runWipe(vault);
      try {
        await Future.any<void>([
          vault.forgetting.future,
          wiping.then(
            (_) => throw StateError('wipe passed the pending OS write'),
          ),
        ]);
      } finally {
        store.bioWriteRelease!.complete();
      }
      await rejected;
      expect(await wiping, isNot(contains('quick-unlock')));
      expect(store.values, isEmpty);
    },
  );

  test('wipe preserves the OS records of another scope', () async {
    SharedPreferences.setMockInitialValues({});
    final store = _SecretStore();
    final other = QuickUnlockVault(
      store,
      'synthetic-other-scope',
      LocalScreenAuthentication(),
    );
    await other.configure(password: 'synthetic other password', system: true);
    final otherRecords = Map<String, String>.of(store.values);
    final selected = QuickUnlockVault(
      store,
      'synthetic-selected-scope',
      LocalScreenAuthentication(),
    );
    await selected.configure(
      password: 'synthetic selected password',
      system: true,
    );
    expect(await _runWipe(selected), isNot(contains('quick-unlock')));
    expect(store.values, otherRecords);
  });

  for (final failure in ['read', 'metadata']) {
    test(
      'unverified OS $failure does not stop deletion of the owned container',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = _SecretStore();
        final vault = QuickUnlockVault(
          store,
          'synthetic-failed-scope',
          LocalScreenAuthentication(),
        );
        await vault.configure(
          password: 'synthetic stored password',
          system: true,
        );
        if (failure == 'read') {
          store.refuseRead = true;
        } else {
          final metadata = store.values.keys.singleWhere(
            (k) => k.startsWith('false:'),
          );
          store.values[metadata] = 'synthetic corrupt metadata';
        }
        final before = Map<String, String>.of(store.values);
        final root = Directory.systemTemp.createTempSync('xveil-wipe-source-');
        final container = File('${root.path}/synthetic-container.hv')
          ..writeAsStringSync('synthetic owned bytes');
        try {
          final remaining = await _runWipe(vault, legacyPath: container.path);
          expect(remaining, contains('quick-unlock'));
          expect(container.existsSync(), isFalse);
          expect(store.values, before);
        } finally {
          root.deleteSync(recursive: true);
        }
      },
    );
  }
}
