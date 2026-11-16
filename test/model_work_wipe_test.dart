import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/profile_model_work.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/data/veil_bundle.dart';
import 'package:xveil/data/translation_model_store.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/identity_scoped_prefs.dart';
import 'package:xveil/state/model_import.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/profile_model_work.dart';
import 'package:xveil/state/startup_unlock.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';
import 'support/fake_hv_container.dart';
import 'support/retirement_secret_store.dart';

class _Work extends ProfileModelWork {
  final retiring = Completer<void>();
  @override
  Future<void> retire() {
    if (!retiring.isCompleted) retiring.complete();
    return super.retire();
  }
}

class _HeldBundle implements File {
  _HeldBundle(this.inner);
  final File inner;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  String get path => inner.path;
  @override
  Future<int> length() async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return inner.length();
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      inner.open(mode: mode);
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      inner.openRead(start, end);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The backend may have passed its last cancellation check before committing.
/// This fixture models that boundary with an actual late file publication.
class _Store extends WhisperModelStore {
  _Store(Directory root, this.cooperative)
    : super(supportDirectory: () async => root);
  final bool cooperative;
  final entered = Completer<void>(),
      release = Completer<void>(),
      removed = Completer<void>();
  bool Function()? cancellation;
  int downloads = 0;
  @override
  Future<WhisperModelDownload> download({
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
    Uri? from,
  }) async {
    downloads++;
    cancellation = isCancelled;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    if (cooperative && isCancelled!()) {
      return const WhisperModelDownload.cancelled();
    }
    final root = await modelDirectory();
    root.createSync(recursive: true);
    final target = File('${root.path}/${WhisperModelStore.fileName}');
    target.writeAsStringSync('synthetic late publication');
    return WhisperModelDownload.ok(target.path);
  }

  @override
  Future<void> remove() async {
    await super.remove();
    if (!removed.isCompleted) removed.complete();
  }
}

class _Idle extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'wipe cannot give a delayed bundle import a fresh model owner',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'xveil-import-wipe-',
      );
      final root = Directory('${directory.path}/translate');
      final source = Directory('${directory.path}/source')..createSync();
      for (final name in kPairFiles) {
        File('${source.path}/$name').writeAsStringSync('synthetic $name bytes');
      }
      final bundle = File('${directory.path}/model.veiltranslate');
      await writeBundle(
        sourceDir: source,
        pair: const TranslationPair('ru', 'en'),
        out: bundle,
      );
      final work = _Work(), store = _Store(directory, false);
      var workOwners = 0;
      final app = ProviderContainer(
        overrides: [
          quickUnlockSecretStoreProvider.overrideWithValue(
            RetirementSecretStore(),
          ),
          appControllerProvider.overrideWith(_Idle.new),
          profileModelWorkProvider.overrideWith(
            (ref) => workOwners++ == 0 ? work : ProfileModelWork(),
          ),
          singleSpaceStorageProvider.overrideWithValue(
            FakeHvContainer().storage(),
          ),
          notificationServiceProvider.overrideWithValue(_Notifications()),
          vpnBackendProvider.overrideWithValue(_Vpn()),
          whisperModelStoreProvider.overrideWithValue(store),
          translationModelsRootProvider.overrideWithValue(() async => root),
        ],
      );
      final held = _HeldBundle(bundle);
      final importing = installReceivedModel(
        held,
        into: targetsFromContainer(app),
        acceptUnverified: true,
      );
      try {
        await held.entered.future;
        expect(
          await app.read(appControllerProvider.notifier).wipeContainers(),
          isEmpty,
        );
        expect(root.existsSync(), isFalse);
        held.release.complete();
        expect((await importing).succeeded, isFalse);
        expect(
          root.existsSync(),
          isFalse,
          reason: 'a pre-wipe inspection cannot recreate installed models',
        );
        final fresh = await installReceivedModel(
          bundle,
          into: targetsFromContainer(app),
          acceptUnverified: true,
        );
        expect(fresh.succeeded, isTrue, reason: fresh.error);
        for (final name in kPairFiles) {
          expect(
            File('${root.path}/ru-en/$name').readAsStringSync(),
            'synthetic $name bytes',
          );
        }
      } finally {
        if (!held.release.isCompleted) held.release.complete();
        await importing;
        app.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );
  for (final cooperative in [false, true]) {
    test(
      'wipe joins speech publication and seals admission; cooperative=$cooperative',
      () async {
        SharedPreferences.setMockInitialValues({
          kWhisperAutoFetchPrefKey: true,
        });
        FlutterSecureStorage.setMockInitialValues({});
        final directory = Directory.systemTemp.createTempSync(
          'xveil-model-wipe-',
        );
        final work = _Work(), store = _Store(directory, cooperative);
        var workOwners = 0;
        final app = ProviderContainer(
          overrides: [
            quickUnlockSecretStoreProvider.overrideWithValue(
              RetirementSecretStore(),
            ),
            appControllerProvider.overrideWith(_Idle.new),
            profileModelWorkProvider.overrideWith(
              (ref) => workOwners++ == 0 ? work : ProfileModelWork(),
            ),
            singleSpaceStorageProvider.overrideWithValue(
              FakeHvContainer().storage(),
            ),
            notificationServiceProvider.overrideWithValue(_Notifications()),
            vpnBackendProvider.overrideWithValue(_Vpn()),
            whisperModelStoreProvider.overrideWithValue(store),
            translationModelsRootProvider.overrideWithValue(() async => null),
          ],
        );
        final root = await store.modelDirectory();
        final model = File('${root.path}/${WhisperModelStore.fileName}');
        final controller = app.read(whisperModelControllerProvider.notifier);
        final downloading = controller.download();
        await store.entered.future;
        final wiping = app
            .read(appControllerProvider.notifier)
            .wipeContainers();
        try {
          // No clock threshold: distinguish an owned join from the old direct
          // delete, which completed while the accepted writer was still held.
          final oldDelete = await Future.any([
            work.retiring.future.then((_) => false),
            store.removed.future.then((_) => true),
          ]);
          if (oldDelete) await wiping;
          store.release.complete();
          await downloading;
          expect(await wiping, isEmpty);
          expect(
            model.existsSync(),
            isFalse,
            reason: 'accepted publication must settle before the final delete',
          );
          expect(store.cancellation!(), isTrue);
          expect(work.begin(), isNull);
          expect(
            (await SharedPreferences.getInstance()).containsKey(
              kWhisperAutoFetchPrefKey,
            ),
            isFalse,
          );
          final fresh = app.read(whisperModelControllerProvider.notifier);
          expect(await fresh.download(), isTrue);
          expect(workOwners, 2);
          expect(model.existsSync(), isTrue);
        } finally {
          if (!store.release.isCompleted) store.release.complete();
          await downloading;
          await wiping;
          app.dispose();
          directory.deleteSync(recursive: true);
        }
      },
    );
  }

  test(
    'wipe seals a translation import held before directory resolution',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'xveil-translation-wipe-',
      );
      final root = Directory('${directory.path}/translate');
      final source = Directory('${directory.path}/source')..createSync();
      for (final name in kPairFiles) {
        File('${source.path}/$name').writeAsStringSync('synthetic $name bytes');
      }
      final bundle = File('${directory.path}/model.veiltranslate');
      await writeBundle(
        sourceDir: source,
        pair: const TranslationPair('ru', 'en'),
        out: bundle,
      );
      final work = _Work(), store = _Store(directory, false);
      final entered = Completer<void>(), release = Completer<Directory>();
      var holdNext = false;
      final app = ProviderContainer(
        overrides: [
          quickUnlockSecretStoreProvider.overrideWithValue(
            RetirementSecretStore(),
          ),
          appControllerProvider.overrideWith(_Idle.new),
          profileModelWorkProvider.overrideWithValue(work),
          singleSpaceStorageProvider.overrideWithValue(
            FakeHvContainer().storage(),
          ),
          notificationServiceProvider.overrideWithValue(_Notifications()),
          vpnBackendProvider.overrideWithValue(_Vpn()),
          whisperModelStoreProvider.overrideWithValue(store),
          translationModelsRootProvider.overrideWithValue(() {
            if (holdNext) {
              holdNext = false;
              entered.complete();
              return release.future;
            }
            return Future.value(root);
          }),
        ],
      );
      final controller = app.read(translationModelsControllerProvider.notifier);
      await controller.refresh();
      holdNext = true;
      final importing = controller.importBundle(bundle.path);
      await entered.future;
      Future<List<String>>? wiping;
      try {
        // State is still idle; an accepted writer must already own its lane.
        expect(await controller.importBundle(bundle.path), isFalse);
        wiping = app.read(appControllerProvider.notifier).wipeContainers();
        final oldDelete = await Future.any([
          work.retiring.future.then((_) => false),
          store.removed.future.then((_) => true),
        ]);
        if (oldDelete) await wiping;
        release.complete(root);
        await importing;
        expect(await wiping, isEmpty);
        expect(root.existsSync(), isFalse);
        expect(bundle.existsSync(), isTrue);
        expect(work.begin(), isNull);
      } finally {
        if (!release.isCompleted) release.complete(root);
        await importing;
        await wiping;
        app.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'background preflight cannot start a late download or restore consent after wipe',
    () async {
      SharedPreferences.setMockInitialValues({kWhisperAutoFetchPrefKey: true});
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'xveil-model-background-wipe-',
      );
      final work = _Work(), store = _Store(directory, false);
      final entered = Completer<void>(), probe = Completer<bool>();
      store.release.complete();
      final app = ProviderContainer(
        overrides: [
          quickUnlockSecretStoreProvider.overrideWithValue(
            RetirementSecretStore(),
          ),
          appControllerProvider.overrideWith(_Idle.new),
          profileModelWorkProvider.overrideWithValue(work),
          singleSpaceStorageProvider.overrideWithValue(
            FakeHvContainer().storage(),
          ),
          notificationServiceProvider.overrideWithValue(_Notifications()),
          vpnBackendProvider.overrideWithValue(_Vpn()),
          whisperModelStoreProvider.overrideWithValue(store),
          whisperNativeProbeProvider.overrideWithValue(() {
            entered.complete();
            return probe.future;
          }),
          translationModelsRootProvider.overrideWithValue(() async => null),
        ],
      );
      final background = app
          .read(whisperModelControllerProvider.notifier)
          .ensureDownloadedInBackground();
      await entered.future;
      final wiping = app.read(appControllerProvider.notifier).wipeContainers();
      try {
        final oldDelete = await Future.any([
          work.retiring.future.then((_) => false),
          store.removed.future.then((_) => true),
        ]);
        if (oldDelete) await wiping;
        probe.complete(true);
        await background;
        expect(await wiping, isEmpty);
        expect(store.downloads, 0);
        expect(
          (await SharedPreferences.getInstance()).containsKey(
            kWhisperAutoFetchPrefKey,
          ),
          isFalse,
        );
        final root = await store.modelDirectory();
        expect(
          File('${root.path}/${WhisperModelStore.fileName}').existsSync(),
          isFalse,
        );
      } finally {
        if (!probe.isCompleted) probe.complete(true);
        await background;
        await wiping;
        app.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'consent I/O is owned without blocking a completed download or retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final prefsReady = Completer<SharedPreferences>();
      final directory = Directory.systemTemp.createTempSync(
        'xveil-model-consent-work-',
      );
      final work = ProfileModelWork(), store = _Store(directory, false);
      store.release.complete();
      final app = ProviderContainer(
        overrides: [
          profileModelWorkProvider.overrideWithValue(work),
          whisperModelStoreProvider.overrideWithValue(store),
          prefsProvider.overrideWith((ref) => prefsReady.future),
        ],
      );
      try {
        final controller = app.read(whisperModelControllerProvider.notifier);
        expect(await controller.download(), isTrue);
        expect(await controller.download(), isTrue);
        var drained = false;
        final closing = work.retire().then((_) => drained = true);
        await Future<void>.value();
        expect(drained, isFalse);
        prefsReady.complete(preferences);
        await closing;
        expect(preferences.containsKey(kWhisperAutoFetchPrefKey), isFalse);
      } finally {
        if (!prefsReady.isCompleted) prefsReady.complete(preferences);
        await work.retire();
        app.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'controller rebuild cancels the old import without releasing its writer early',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'xveil-model-client-generation-',
      );
      final root = Directory('${directory.path}/translate');
      final source = Directory('${directory.path}/source')..createSync();
      for (final name in kPairFiles) {
        File('${source.path}/$name').writeAsStringSync('synthetic $name bytes');
      }
      final bundle = File('${directory.path}/model.veiltranslate');
      await writeBundle(
        sourceDir: source,
        pair: const TranslationPair('ru', 'en'),
        out: bundle,
      );
      final entered = Completer<void>(), release = Completer<Directory>();
      var holdNext = false;
      final app = ProviderContainer(
        overrides: [
          translationModelsRootProvider.overrideWithValue(() {
            if (holdNext) {
              holdNext = false;
              entered.complete();
              return release.future;
            }
            return Future.value(root);
          }),
        ],
      );
      final old = app.read(translationModelsControllerProvider.notifier);
      await old.refresh();
      holdNext = true;
      final pending = old.importBundle(bundle.path);
      try {
        await entered.future;
        app.invalidate(translationModelsControllerProvider);
        final fresh = app.read(translationModelsControllerProvider.notifier);
        expect(await fresh.importBundle(bundle.path), isFalse);
        release.complete(root);
        expect(await pending, isFalse);
        expect(root.existsSync(), isFalse);
        expect(await fresh.importBundle(bundle.path), isTrue);
        expect(
          Directory('${root.path}/ru-en').listSync(),
          hasLength(kPairFiles.length),
        );
      } finally {
        if (!release.isCompleted) release.complete(root);
        await pending;
        app.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
