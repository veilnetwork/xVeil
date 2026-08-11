// The speech and translation models belong to a PROFILE, not to the install.
//
// They did not, and it cost data. Both stores resolved from the bare
// application-support directory, so on a machine with a second profile:
//
//   * a brand-new throwaway profile reported "speech model installed" because
//     it was reading the DEFAULT profile's file, and
//   * a wipe performed inside that throwaway profile DELETED the default
//     profile's 57 MiB model. Twice, on a real macOS install.
//
// One identity destroying another identity's data is the worst thing in this
// list, but it is not the only one: a translation pair is a directory named
// `ru-en`, so the shared location also handed every profile the list of
// languages the person reads — the very fact commit 289512c wipes them for.
//
// Every test here drives the PRODUCTION derivation. The injected callback says
// where the app-support directory is, exactly as `path_provider` would; the
// profile scoping happens inside the code under test. A test that computed the
// profile path itself and compared it to the store's would pass just as
// happily with the bug back in place.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/log.dart';
import 'package:xveil/data/storage/app_profile.dart';
import 'package:xveil/data/translation_model_store.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/translation_engines.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';

import 'support/fake_hv_container.dart';

Future<void> _settle(ProviderContainer c) async {
  for (
    var i = 0;
    i < 20 && c.read(appControllerProvider).phase == AppPhase.bootstrapping;
    i++
  ) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory support;
  late String originalProfile;

  setUp(() {
    support = Directory.systemTemp.createTempSync('xveil-profile-models');
    originalProfile = activeProfile;
    debugResetProfileDirNotes();
    SharedPreferences.setMockInitialValues(<String, Object>{'onboarded': true});
  });

  tearDown(() {
    activeProfile = originalProfile;
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  /// The store as production builds it: only the app-support lookup replaced.
  WhisperModelStore speechStore() =>
      WhisperModelStore(supportDirectory: () async => support);

  /// The translation root as production resolves it — the same call the
  /// settings list, the export, the model exchange and the WIPE all make.
  Future<Directory?> translateRoot() => TranslationEngines.defaultModelsRoot(
    supportDirectory: () async => support,
  );

  File speechFileIn(String profile) => File(
    '${AppProfiles.directory(support.path, profile)}/${WhisperModelStore.fileName}',
  );

  Directory pairDirIn(String profile, String pair) => Directory(
    '${AppProfiles.directory(support.path, profile)}/'
    '${TranslationModelStore.dirName}/$pair',
  );

  setUpAll(() {
    // The environment override wins over every path below by design, so a
    // machine that has it set is not exercising what this file is about. Loud
    // rather than silently green.
    expect(
      Platform.environment[TranslationEngines.rootEnv] ?? '',
      isEmpty,
      reason:
          'unset ${TranslationEngines.rootEnv} — with it set these tests would '
          'pass without ever touching the profile scoping',
    );
  });

  group('one profile cannot see another profile\'s models', () {
    test('a speech model installed in A is absent in B', () async {
      activeProfile = 'alpha';
      final store = speechStore();
      final installed = await store.modelDirectory();
      installed.createSync(recursive: true);
      File('${installed.path}/${WhisperModelStore.fileName}').writeAsBytesSync(
        Uint8List(WhisperModelStore.expectedBytes),
        flush: true,
      );
      expect(
        await store.isInstalled(),
        isTrue,
        reason: 'the profile that installed it must see it',
      );

      activeProfile = 'bravo';
      expect(
        await speechStore().isInstalled(),
        isFalse,
        reason:
            'a brand-new profile reported "speech model installed" on the '
            'strength of another profile\'s file',
      );
      expect(
        speechFileIn('bravo').existsSync(),
        isFalse,
        reason: 'nothing was copied into the second profile either',
      );
    });

    test('a translation pair installed in A is absent in B', () async {
      activeProfile = 'alpha';
      final store = TranslationModelStore(
        supportDirectory: () async => support,
      );
      final pair = const TranslationPair('ru', 'en');
      final dir = await store.directoryFor(pair);
      dir.createSync(recursive: true);
      File('${dir.path}/model.bin').writeAsStringSync('weights');
      expect(dir.path, pairDirIn('alpha', 'ru-en').path);

      activeProfile = 'bravo';
      expect(
        (await translateRoot())!.existsSync(),
        isFalse,
        reason:
            'the directory NAMES are the list of languages the other identity '
            'reads — the second profile must not be able to enumerate them',
      );
      expect(
        (await TranslationModelStore(
          supportDirectory: () async => support,
        ).directoryFor(pair)).existsSync(),
        isFalse,
      );
    });

    test('the store and the engine root cannot disagree about where', () async {
      // A wipe that deletes a different tree than the store writes into is a
      // wipe that destroys somebody else's models and leaves this profile's
      // standing. Two answers to one question is how that happens.
      for (final profile in [AppProfiles.defaultName, 'alpha', 'bravo']) {
        activeProfile = profile;
        final fromStore = await TranslationModelStore(
          supportDirectory: () async => support,
        ).root();
        final fromEngine = await translateRoot();
        expect(fromStore.path, fromEngine!.path, reason: 'profile $profile');
      }
    });
  });

  group('what an existing install keeps', () {
    test('the default profile keeps the HISTORICAL locations', () async {
      // The whole migration story, and the reason no model has to move: for
      // the default profile the profile directory IS the support directory,
      // exactly as AppProfiles.storePath keeps the historical container path.
      activeProfile = AppProfiles.defaultName;
      expect((await speechStore().modelDirectory()).path, support.path);
      expect(
        (await translateRoot())!.path,
        '${support.path}/${TranslationModelStore.dirName}',
      );
    });

    test('an already-downloaded model stays reachable to the profile that '
        'downloaded it', () async {
      // The person this could have cost 57 MiB: they have a model, they
      // upgrade, they never opened the switcher. Nothing is moved, copied or
      // re-fetched — the same file, the same path, still installed.
      final existing = File('${support.path}/${WhisperModelStore.fileName}')
        ..writeAsBytesSync(
          Uint8List(WhisperModelStore.expectedBytes),
          flush: true,
        );
      activeProfile = AppProfiles.defaultName;
      expect(await speechStore().isInstalled(), isTrue);
      expect((await speechStore().installed())!.path, existing.path);
    });

    test('a second profile does NOT adopt the shared copy, does NOT delete it, '
        'and says so', () async {
      // The documented choice: leave it and re-download. Adopting is the leak
      // itself — a throwaway profile would start out holding the list of
      // languages the real identity reads.
      final shared = File('${support.path}/${WhisperModelStore.fileName}')
        ..writeAsStringSync('the default profile\'s 57 MiB');
      final sharedPair = Directory(
        '${support.path}/${TranslationModelStore.dirName}/ru-en',
      )..createSync(recursive: true);

      activeProfile = 'throwaway';
      debugResetProfileDirNotes();
      final store = speechStore();
      expect(await store.isInstalled(), isFalse, reason: 'not adopted');

      // `remove()` is what a wipe calls. It must reach into this profile only.
      await store.remove();
      final root = await translateRoot();
      if (root!.existsSync()) root.deleteSync(recursive: true);

      expect(
        shared.existsSync(),
        isTrue,
        reason: 'the wipe in a throwaway profile deleted the real model twice',
      );
      expect(shared.readAsStringSync(), 'the default profile\'s 57 MiB');
      expect(sharedPair.existsSync(), isTrue);

      expect(
        devLogSnapshot(limit: 4000).lines.where(
          (line) =>
              line.contains('LEFT WHERE THEY ARE') &&
              line.contains(WhisperModelStore.fileName),
        ),
        isNotEmpty,
        reason:
            'the choice not to adopt must be observable, not silent — someone '
            'wondering where their model went has to be able to find out',
      );
    });
  });

  test(
    'a WIPE in one profile leaves the other profile\'s model file alone',
    () async {
      // The defect, end to end, through the real AppController.wipeContainers.
      // Asserted on the FILE — that it is there, and that it is byte for byte
      // what it was — because "the store reports installed" is a claim about a
      // size check, and what was lost was the bytes.
      //
      // Both profiles' paths are resolved by the code under test, never restated
      // here. Restating them would quietly hide the defect: with the roots
      // unscoped the two profiles are ONE file, and a test that wrote to two
      // computed paths would be testing a layout the app does not use.
      const keep = 'the default profile\'s speech model, byte for byte';
      activeProfile = AppProfiles.defaultName;
      final defaultModel = File(
        '${(await speechStore().modelDirectory()).path}/${WhisperModelStore.fileName}',
      );
      defaultModel.parent.createSync(recursive: true);
      defaultModel.writeAsStringSync(keep);
      final defaultPair = File(
        '${(await translateRoot())!.path}/ru-en/model.bin',
      );
      defaultPair.parent.createSync(recursive: true);
      defaultPair.writeAsStringSync('ru-en weights');

      activeProfile = 'throwaway';
      final throwawayModel = File(
        '${(await speechStore().modelDirectory()).path}/${WhisperModelStore.fileName}',
      );
      throwawayModel.parent.createSync(recursive: true);
      throwawayModel.writeAsStringSync('the throwaway profile\'s own');
      final throwawayPair = Directory('${(await translateRoot())!.path}/de-en')
        ..createSync(recursive: true);

      final storeFile = File(AppProfiles.storePath(support.path, 'throwaway'));
      // Created explicitly: boot creates a non-default profile's directory, and
      // without this the container write is what fails when the model roots are
      // wrong — an exception instead of the assertion that names the defect.
      storeFile.parent.createSync(recursive: true);
      storeFile.writeAsStringSync('container');
      final container = FakeHvContainer();
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWith((ref) => container.storage()),
          whisperModelStoreProvider.overrideWithValue(speechStore()),
          translationModelsRootProvider.overrideWithValue(translateRoot),
          deniableBootProvider.overrideWithValue(
            DeniableBootConfig(
              runtimeDir: '${support.path}/rt',
              listenPort: 9002,
              storePath: storeFile.path,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      await _settle(c);

      await ctrl.wipeContainers();

      // The data loss FIRST. An earlier assertion that fails takes the rest of
      // the test with it, and the one that matters here is the survival of the
      // other identity's file, not the completeness of this profile's wipe.
      expect(
        defaultModel.existsSync(),
        isTrue,
        reason:
            'a wipe in a throwaway profile destroyed another identity\'s 57 MiB',
      );
      expect(
        defaultModel.readAsStringSync(),
        keep,
        reason: 'present is not enough — the bytes have to be the same bytes',
      );
      expect(
        defaultPair.existsSync(),
        isTrue,
        reason: 'and the other identity\'s language list survives too',
      );
      expect(defaultPair.readAsStringSync(), 'ru-en weights');

      // And the wipe still does its own job, or the fix would be "stop wiping".
      expect(
        throwawayModel.existsSync(),
        isFalse,
        reason: 'the wipe must still take THIS profile\'s model',
      );
      expect(throwawayPair.existsSync(), isFalse);
    },
  );
}
