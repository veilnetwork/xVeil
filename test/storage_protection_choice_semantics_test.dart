import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/features/onboarding/storage_protection_choice.dart';
import 'package:xveil/l10n/app_localizations.dart';

void main() {
  testWidgets('the selected protection mode is announced and follows taps', (
    tester,
  ) async {
    var selected = StorageProtection.defaultForNewIdentity;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => StorageProtectionChoice(
              selected: selected,
              onChanged: (value) => update(() => selected = value),
              onNext: () {},
            ),
          ),
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    const order = [
      StorageProtection.encrypted,
      StorageProtection.hidden,
      StorageProtection.unencrypted,
    ];
    try {
      for (var choice = 0; choice < order.length; choice++) {
        if (choice != 0) {
          await tester.tap(find.byType(ListTile).at(choice));
          await tester.pump();
        }
        expect(selected, order[choice]);
        for (var row = 0; row < order.length; row++) {
          expect(
            tester
                .getSemantics(find.byType(ListTile).at(row))
                .flagsCollection
                .isSelected,
            row == choice ? Tristate.isTrue : Tristate.isFalse,
            reason: 'exactly the chosen protection must be marked selected',
          );
        }
      }
    } finally {
      semantics.dispose();
    }
  });
}
