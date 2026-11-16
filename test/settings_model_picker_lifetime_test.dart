import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/translation_model_store.dart';
import 'package:xveil/data/veil_bundle.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/features/common/translation_models_tile.dart';
import 'package:xveil/features/common/whisper_model_tile.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/startup_unlock.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';

import 'support/fake_hv_container.dart';
import 'support/retirement_secret_store.dart';

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

class _Fixture {
  final directory = Directory.systemTemp.createTempSync('xveil-picker-owner-');
  var chosen = Completer<String?>();
  var entered = Completer<void>();
  late final root = Directory('${directory.path}/translate');
  late final bundle = File('${directory.path}/model.veiltranslate');
  late final destination = File('${directory.path}/export.veiltranslate');
  late final app = ProviderContainer(
    overrides: [
      appControllerProvider.overrideWith(_Idle.new),
      quickUnlockSecretStoreProvider.overrideWithValue(RetirementSecretStore()),
      singleSpaceStorageProvider.overrideWithValue(FakeHvContainer().storage()),
      notificationServiceProvider.overrideWithValue(_Notifications()),
      vpnBackendProvider.overrideWithValue(_Vpn()),
      whisperModelStoreProvider.overrideWithValue(
        WhisperModelStore(supportDirectory: () async => directory),
      ),
      translationModelsRootProvider.overrideWithValue(() async => root),
      translationBundlePickerProvider.overrideWithValue(pick),
      translationBundleSaverProvider.overrideWithValue((_) => pick()),
    ],
  );

  void nextPicker() {
    chosen = Completer<String?>();
    entered = Completer<void>();
  }

  Future<String?> pick() {
    entered.complete();
    return chosen.future;
  }

  void putPair(String content) {
    for (final name in kPairFiles) {
      File('${root.path}/ru-en/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('$content $name');
    }
  }

  Future<void> prepare() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final source = Directory('${directory.path}/source')..createSync();
    for (final name in kPairFiles) {
      File('${source.path}/$name').writeAsStringSync('synthetic $name');
    }
    await writeBundle(
      sourceDir: source,
      pair: const TranslationPair('ru', 'en'),
      out: bundle,
    );
  }

  Future<void> wipe() async {
    expect(
      await app.read(appControllerProvider.notifier).wipeContainers(),
      isEmpty,
    );
    expect(root.existsSync(), isFalse);
    // Rebuild just as the watched settings providers do after erasure. Riverpod
    // may reuse their Notifier objects; an old callback must not adopt them.
    app.read(translationModelsControllerProvider);
    app.read(whisperModelControllerProvider);
  }

  Future<void> close() async {
    if (!chosen.isCompleted) chosen.complete(null);
    app.dispose();
    directory.deleteSync(recursive: true);
  }
}

Future<void> _pump(WidgetTester tester, _Fixture f, Widget tile) async {
  // Start controller probes in the real I/O zone before the widget watches.
  await tester.runAsync(() async {
    await f.app.read(translationModelsControllerProvider.notifier).refresh();
    await f.app.read(whisperModelControllerProvider.notifier).refresh();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: f.app,
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: tile)),
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(() async {
    await f.app.read(translationModelsControllerProvider.notifier).refresh();
    await f.app.read(whisperModelControllerProvider.notifier).refresh();
  });
  await tester.pump();
}

// Invoke the actual widget callback in runAsync's real I/O zone and retain its
// Future. A synthetic stream in fake-async would not qualify file publication.
Future<void> _invoke(dynamic callback) => callback() as Future<void>;

void main() {
  for (final speech in [false, true]) {
    for (final removeWidget in [false, true]) {
      testWidgets(
        'late model selection is refused; speech=$speech, removed=$removeWidget',
        (tester) async {
          late _Fixture f;
          await tester.runAsync(() async {
            f = _Fixture();
            await f.prepare();
          });
          Future<void>? pending;
          try {
            final widget = speech
                ? const WhisperModelTile()
                : const TranslationModelsTile();
            await _pump(tester, f, widget);
            final tile = tester.widget<ListTile>(
              find.ancestor(
                of: find.text('Install from a file…'),
                matching: find.byType(ListTile),
              ),
            );
            await tester.runAsync(() async {
              pending = _invoke(tile.onTap);
              await f.entered.future;
              if (!removeWidget) await f.wipe();
            });
            if (removeWidget) await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() async {
              f.chosen.complete(f.bundle.path);
              await pending;
              expect(
                f.root.existsSync(),
                isFalse,
                reason: 'the old file choice cannot recreate erased model data',
              );
              expect(
                f.app.read(translationModelsControllerProvider).hasAny,
                isFalse,
              );
              expect(
                f.app.read(whisperModelControllerProvider).phase,
                WhisperModelPhase.absent,
                reason: 'the old speech choice must not affect a new lifetime',
              );
              expect(
                f.bundle.existsSync(),
                isTrue,
                reason: 'a user-selected source is not owned erasure scratch',
              );
            });
            if (!speech && !removeWidget) {
              await tester.runAsync(() async => f.nextPicker());
              await _pump(tester, f, widget);
              final fresh = tester.widget<ListTile>(
                find.ancestor(
                  of: find.text('Install from a file…'),
                  matching: find.byType(ListTile),
                ),
              );
              await tester.runAsync(() async {
                final installing = _invoke(fresh.onTap);
                await f.entered.future;
                f.chosen.complete(f.bundle.path);
                await installing;
                expect(
                  f.app.read(translationModelsControllerProvider).hasAny,
                  isTrue,
                );
                for (final name in kPairFiles) {
                  expect(
                    File('${f.root.path}/ru-en/$name').readAsStringSync(),
                    'synthetic $name',
                  );
                }
              });
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(() async {
              if (!f.chosen.isCompleted) f.chosen.complete(null);
              await pending;
              await f.close();
            });
          }
        },
      );
    }
  }

  testWidgets(
    'a pending export dialog cannot export a post-wipe replacement pair',
    (tester) async {
      late _Fixture f;
      await tester.runAsync(() async {
        f = _Fixture();
        await f.prepare();
        f.putPair('original');
      });
      try {
        await _pump(tester, f, const TranslationModelsTile());
        final button = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.ios_share),
            matching: find.byType(IconButton),
          ),
        );
        await tester.runAsync(() async {
          final pending = _invoke(button.onPressed);
          await f.entered.future;
          await f.wipe();
          f.putPair('replacement');
          await f.app
              .read(translationModelsControllerProvider.notifier)
              .refresh();
          f.chosen.complete(f.destination.path);
          await pending;
          expect(
            f.destination.existsSync(),
            isFalse,
            reason:
                'old export consent does not cover a fresh lifetime\'s files',
          );
          expect(f.bundle.existsSync(), isTrue);
          for (final name in kPairFiles) {
            expect(
              File('${f.root.path}/ru-en/$name').readAsStringSync(),
              'replacement $name',
            );
          }
        });
        await tester.runAsync(() async => f.nextPicker());
        await _pump(tester, f, const TranslationModelsTile());
        final fresh = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.ios_share),
            matching: find.byType(IconButton),
          ),
        );
        await tester.runAsync(() async {
          final exporting = _invoke(fresh.onPressed);
          await f.entered.future;
          f.chosen.complete(f.destination.path);
          await exporting;
          final verified = Directory('${f.directory.path}/verify-export');
          final installed = await installBundle(
            f.destination,
            modelsRoot: verified,
          );
          expect(installed.succeeded, isTrue, reason: installed.error);
          for (final name in kPairFiles) {
            expect(
              File('${verified.path}/ru-en/$name').readAsStringSync(),
              'replacement $name',
            );
          }
        });
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(f.close);
      }
    },
  );
}
