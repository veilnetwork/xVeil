// The switch that decides whether this device tells contacts what models it
// holds. No file I/O: a real read inside testWidgets hangs rather than fails.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/common/model_sharing_tile.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/model_exchange_service.dart';

class _ScriptedSetting extends AnswerModelInventoryController {
  _ScriptedSetting(this._initial);
  final bool _initial;
  final written = <bool>[];

  @override
  Future<bool> build() async => _initial;

  @override
  Future<void> set(bool enabled) async {
    written.add(enabled);
    state = AsyncData(enabled);
  }
}

Future<_ScriptedSetting> _pump(WidgetTester tester, bool initial) async {
  final controller = _ScriptedSetting(initial);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        answerModelInventoryProvider.overrideWith(() => controller),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: const Scaffold(body: ModelSharingTile()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('on, it says what contacts can see', (tester) async {
    await _pump(tester, true);
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(find.textContaining('can see which language'), findsOneWidget);
  });

  testWidgets('off, it says silence is indistinguishable from having none', (
    tester,
  ) async {
    await _pump(tester, false);
    // The part a person cannot work out for themselves, and the reason the
    // setting is worth having: a contact who could tell "declined" from "has
    // none" would learn the very thing turning it off was meant to withhold.
    expect(find.textContaining('cannot tell this'), findsOneWidget);
    expect(find.textContaining('can see which language'), findsNothing);
  });

  testWidgets('flipping it writes the choice', (tester) async {
    final controller = await _pump(tester, true);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    // Counted at the WRITE, not on the widget's own value: a switch can move
    // on screen while nothing is stored, and that is exactly the failure a
    // person would never notice.
    expect(controller.written, [false]);
  });
}
