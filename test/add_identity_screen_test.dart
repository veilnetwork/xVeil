import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/identity/add_identity_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

Widget _host() => const ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: AddIdentityScreen(),
      ),
    );

void main() {
  testWidgets('converting (single mode) asks for a name for the current '
      'identity + a master password', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    // Default app state is bootstrapping → isMaster false → converting form.
    expect(find.text('Name for your current identity'), findsOneWidget);
    expect(find.text('New identity name'), findsOneWidget);
    expect(find.text('New identity password'), findsOneWidget);
    expect(find.text('Master password'), findsOneWidget);
    expect(find.text('Create'), findsOneWidget);
  });

  testWidgets('submitting an incomplete form shows a validation message',
      (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    await tester.tap(find.text('Create'));
    await tester.pump();
    expect(find.text('Fill in every field.'), findsOneWidget);
  });
}
