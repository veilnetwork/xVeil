// Whether the tile shows what is installed and whether tapping it installs.
//
// Deterministic for the reason the speech model tile's test is: a live build
// stops producing frames while a system file dialog is open, so a screenshot
// proves nothing and a blind tap proves less.
//
// The controller is SCRIPTED here, the same way the speech model tile's test
// scripts its store. Two reasons, one of them learned the hard way.
//
// The clean one: what this file is asking is whether the tile renders the
// state it is given and calls the right thing when tapped. Whether an import
// actually verifies and unpacks a bundle is asked — thoroughly, adversarially
// — by translation_bundle_test.dart and translation_model_controller_test.dart.
//
// The hard-won one: a real import inside testWidgets HANGS. It streams a file
// with `await for (... openRead())`, and inside the fake-async zone those
// events are never delivered, so the await never returns. It does not fail; it
// sits there, and pumpAndSettle's default patience is ten minutes, so the
// runner eventually reports a timeout that says nothing about the widget.
// Wrapping the tap in tester.runAsync() does not rescue it either.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/translation_model_store.dart';
import 'package:xveil/features/common/translation_models_tile.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/translation_model_controller.dart';

/// Bounded frames. Never pumpAndSettle — see the note at the top.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> tapAndSettle(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await settle(tester);
}

/// A controller that answers instantly and records what it was asked to do.
class ScriptedController extends TranslationModelsController {
  final imports = <String>[];
  final removals = <String>[];

  /// What the next import pretends to be: a pair to install, or an error.
  TranslationPair? installs = const TranslationPair('ru', 'en');
  String? failsWith;

  @override
  TranslationModelsState build() => const TranslationModelsState();

  @override
  Future<void> refresh() async {}

  @override
  Future<bool> importBundle(String path) async {
    imports.add(path);
    if (failsWith != null) {
      state = state.copyWith(
        phase: TranslationImportPhase.failed,
        error: failsWith,
      );
      return false;
    }
    state = state.copyWith(
      installed: [...state.installed, installs!],
      phase: TranslationImportPhase.idle,
      lastInstalled: installs,
      clearError: true,
    );
    return true;
  }

  @override
  Future<void> remove(TranslationPair pair) async {
    removals.add(pair.id);
    state = state.copyWith(
      installed: state.installed.where((p) => p.id != pair.id).toList(),
    );
  }
}

void main() {
  late ScriptedController controller;

  setUp(() => controller = ScriptedController());

  Future<void> pump(
    WidgetTester tester, {
    required Future<String?> Function() picker,
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          translationBundlePickerProvider.overrideWithValue(picker),
          translationModelsControllerProvider.overrideWith(() => controller),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          locale: locale,
          home: const Scaffold(body: TranslationModelsTile()),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('with nothing installed it says so and offers the file', (
    tester,
  ) async {
    await pump(tester, picker: () async => null);
    expect(find.text('No languages installed'), findsOneWidget);
    expect(find.text('Install from a file…'), findsOneWidget);
  });

  testWidgets('dismissing the picker installs nothing', (tester) async {
    var asked = 0;
    await pump(tester, picker: () async {
      asked++;
      return null;
    });
    await tapAndSettle(tester, find.text('Install from a file…'));

    expect(asked, 1, reason: 'the picker was opened');
    // Closing a dialog is not a failure and must not be reported as one, nor
    // may it reach the controller.
    expect(controller.imports, isEmpty);
    expect(find.textContaining('could not be installed'), findsNothing);
    expect(find.text('No languages installed'), findsOneWidget);
  });

  testWidgets('a picked file is handed to the controller and then listed', (
    tester,
  ) async {
    await pump(tester, picker: () async => '/tmp/ru-en.veiltranslate');
    await tapAndSettle(tester, find.text('Install from a file…'));

    expect(controller.imports, equals(['/tmp/ru-en.veiltranslate']));
    expect(find.text('ru → en'), findsWidgets);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.text('No languages installed'), findsNothing);
  });

  testWidgets('a refusal shows the verdict AND the reason', (tester) async {
    controller.failsWith = 'not a .veiltranslate file (bad header)';
    await pump(tester, picker: () async => '/tmp/holiday.jpg');
    await tapAndSettle(tester, find.text('Install from a file…'));

    // Without the reason nobody can tell a truncated transfer from a file that
    // was never a bundle.
    expect(find.textContaining('could not be installed'), findsOneWidget);
    expect(find.textContaining('bad header'), findsOneWidget);
  });

  testWidgets('removing asks the controller and drops the row', (tester) async {
    await pump(tester, picker: () async => '/tmp/ru-en.veiltranslate');
    await tapAndSettle(tester, find.text('Install from a file…'));
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await tapAndSettle(tester, find.byIcon(Icons.delete_outline));

    expect(controller.removals, equals(['ru-en']));
    expect(find.text('No languages installed'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('two directions each get their own row', (tester) async {
    await pump(tester, picker: () async => '/tmp/a.veiltranslate');
    await tapAndSettle(tester, find.text('Install from a file…'));
    controller.installs = const TranslationPair('en', 'ru');
    await tapAndSettle(tester, find.text('Install from a file…'));

    expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    expect(find.text('en → ru'), findsWidgets);
  });

  testWidgets('the Russian layout keeps the action beside the title', (
    tester,
  ) async {
    // The speech model tile paid for this: a Russian action label crushed its
    // title into a one-word-per-line column on a 360px screen, so the action
    // here is an icon. This asserts the icon is there and nothing overflowed.
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pump(
      tester,
      picker: () async => '/tmp/ru-en.veiltranslate',
      locale: const Locale('ru'),
    );
    await tapAndSettle(tester, find.text('Установить из файла…'));

    expect(find.text('Языки перевода'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
