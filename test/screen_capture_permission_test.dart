import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/calls/screen_capture_permission.dart';
import 'package:xveil/l10n/app_localizations.dart';

void main() {
  testWidgets('screen capture denial offers a direct System Settings action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showScreenCapturePermissionSnackBar(context),
              child: const Text('Show'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show'));
    await tester.pump();

    expect(
      find.text(
        'Allow Screen Recording for xveil in System Settings, then try again',
      ),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SnackBarAction, 'Open Settings'),
      findsOneWidget,
    );
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(seconds: 12),
    );
  });
}
