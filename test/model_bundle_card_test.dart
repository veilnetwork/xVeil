// What the card shows about a model that arrived in a chat.
//
// Rendering and the download tap only. The INSTALL path is covered by
// model_import_test.dart, and deliberately not exercised through a widget: a
// real file read inside testWidgets never completes — the fake-async zone does
// not deliver stream events — so it does not fail, it hangs for ten minutes
// and then reports a timeout that says nothing about the widget.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/veil_bundle.dart';
import 'package:xveil/features/chat/model_bundle_card.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/providers.dart';

/// Reports whatever size the test asks for, and records whether the whole blob
/// was ever pulled into memory.
class _SizeReportingStorage extends HiddenVolumeStorage {
  _SizeReportingStorage(super.opener);

  int? reportedSize;

  /// Bytes this fake would have allocated: null when the ceiling refused the
  /// read, which is the whole property under test.
  int? allocated;

  @override
  Future<int?> fileSize(String fileId) async => reportedSize;

  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) async {
    // What the real store does: the ceiling is checked against the STORED
    // size, before anything is reassembled.
    final size = reportedSize;
    if (size == null) return null;
    if (maxBytes != null && size > maxBytes) return null;
    allocated = size;
    return Uint8List(0);
  }
}

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
    await pumpCard(tester, fileName: 'ru-en.veiltranslate', downloaded: true);
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

  /// The bundle's own 2 GiB ceiling is checked by the reader that runs AFTER
  /// the blob has been pulled into memory, so the allocation the ceiling
  /// exists to prevent had already happened by the time anyone looked. A
  /// received file is whatever the other side sent.
  ///
  /// Safe to drive through the widget precisely because the guard returns
  /// before any real file work — see this file's header for why the rest of
  /// the install path is not tested here.
  testWidgets('a blob past the bundle ceiling is refused before it is read', (
    tester,
  ) async {
    final storage = _SizeReportingStorage(
      ({required Uint8List password, required bool create}) => FakeKvLogStore(),
    )..reportedSize = kMaxBundleBytes + 1;
    await storage.open(password: 'pw', createIfMissing: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [storageProvider.overrideWithValue(storage)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(
            body: ModelBundleCard(
              fileKey: 'key',
              fileName: 'en-ru.veiltranslate',
              downloaded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Install'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      storage.allocated,
      isNull,
      reason:
          'the ceiling has to be consulted before the allocation, not '
          'after it',
    );
    expect(find.textContaining('too large'), findsOneWidget);
  });

  testWidgets('a blob within the ceiling is still read', (tester) async {
    final storage = _SizeReportingStorage(
      ({required Uint8List password, required bool create}) => FakeKvLogStore(),
    )..reportedSize = 64 * 1024;
    await storage.open(password: 'pw', createIfMissing: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [storageProvider.overrideWithValue(storage)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(
            body: ModelBundleCard(
              fileKey: 'key',
              fileName: 'en-ru.veiltranslate',
              downloaded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Install'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      storage.allocated,
      64 * 1024,
      reason: 'a guard that refuses everything is not a guard',
    );
  });
}
