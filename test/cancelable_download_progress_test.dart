import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/chat/cancelable_download_progress.dart';
import 'package:xveil/l10n/app_localizations.dart';

void main() {
  testWidgets('progress ring exposes and invokes the centre cancel action', (
    tester,
  ) async {
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: Center(
            child: CancelableDownloadProgress(
              progress: 0.42,
              onCancel: () => cancelled = true,
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(cancelled, isTrue);
  });
}
