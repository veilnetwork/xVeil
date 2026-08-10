// What the card shows about a model that arrived in a chat.
//
// Rendering and the download tap only. The INSTALL path is covered by
// model_import_test.dart, and deliberately not exercised through a widget: a
// real file read inside testWidgets never completes — the fake-async zone does
// not deliver stream events — so it does not fail, it hangs for ten minutes
// and then reports a timeout that says nothing about the widget.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/chat/model_bundle_card.dart';
import 'package:xveil/l10n/app_localizations.dart';

Future<void> pumpCard(
  WidgetTester tester, {
  required String fileName,
  required bool downloaded,
  int? sizeBytes,
  double? progress,
  VoidCallback? onDownload,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: ModelBundleCard(
            fileKey: 'key',
            fileName: fileName,
            downloaded: downloaded,
            sizeBytes: sizeBytes,
            progress: progress,
            onDownload: onDownload,
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('before the bytes are here it offers only to fetch them', (
    tester,
  ) async {
    var asked = 0;
    await pumpCard(
      tester,
      fileName: 'ru-en.veiltranslate',
      downloaded: false,
      onDownload: () => asked++,
    );

    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Install'), findsNothing);
    await tester.tap(find.text('Download'));
    expect(asked, 1);
  });

  testWidgets('with the bytes here it offers to install', (tester) async {
    await pumpCard(
      tester,
      fileName: 'ru-en.veiltranslate',
      downloaded: true,
    );
    expect(find.text('Install'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('the trust line is always there', (tester) async {
    // Not a one-off warning behind a menu: a model decides what this app says
    // another person wrote, and the hashes prove integrity, not provenance.
    for (final downloaded in [false, true]) {
      await pumpCard(
        tester,
        fileName: 'ru-en.veiltranslate',
        downloaded: downloaded,
      );
      expect(
        find.textContaining('only from someone you trust'),
        findsOneWidget,
        reason: 'downloaded=$downloaded',
      );
    }
  });

  testWidgets('a translation bundle names its direction and size', (
    tester,
  ) async {
    await pumpCard(
      tester,
      fileName: 'ru-en.veiltranslate',
      downloaded: true,
      sizeBytes: 79 * 1024 * 1024,
    );
    expect(find.text('Translation model'), findsOneWidget);
    expect(find.text('ru → en, 79 MB'), findsOneWidget);
  });

  testWidgets('a speech bundle is named as one, with no direction', (
    tester,
  ) async {
    await pumpCard(
      tester,
      fileName: 'speech.veilaudio',
      downloaded: true,
      sizeBytes: 57 * 1024 * 1024,
    );
    expect(find.text('Speech model'), findsOneWidget);
    expect(find.text('57 MB'), findsOneWidget);
    expect(find.textContaining('→'), findsNothing);
  });

  testWidgets('a name that is not a pair claims no direction', (tester) async {
    // Silence rather than a guess: a card inventing "xx → yy" from a filename
    // would state something about a model it has not read.
    await pumpCard(
      tester,
      fileName: 'model.veiltranslate',
      downloaded: true,
      sizeBytes: 1024 * 1024,
    );
    expect(find.text('Translation model'), findsOneWidget);
    expect(find.text('1 MB'), findsOneWidget);
    expect(find.textContaining('→'), findsNothing);
  });

  testWidgets('the Russian card fits a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpCard(
      tester,
      fileName: 'ru-en.veiltranslate',
      downloaded: true,
      sizeBytes: 79 * 1024 * 1024,
      locale: const Locale('ru'),
    );

    expect(find.text('Модель перевода'), findsOneWidget);
    expect(find.text('Установить'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
