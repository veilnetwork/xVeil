import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/features/common/whisper_model_tile.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/whisper_model_controller.dart';

/// Whether the tile renders and whether tapping it starts a download.
///
/// Written after trying to check this on a live macOS build and failing: the
/// window stops producing frames, so a screenshot proves nothing about what is
/// on screen, and a blind tap proves nothing about what was hit. This is the
/// deterministic version of the same question.
class _ScriptedStore implements WhisperModelStore {
  bool installedNow = false;
  int downloads = 0;
  int removals = 0;
  Completer<WhisperModelDownload>? pending;

  @override
  Future<bool> isInstalled() async => installedNow;

  @override
  Future<File?> installed() async => null;

  @override
  Future<void> remove() async {
    removals++;
    installedNow = false;
  }

  @override
  Future<WhisperModelDownload> download({
    void Function(double progress)? onProgress,
    Uri? from,
  }) {
    downloads++;
    return (pending = Completer<WhisperModelDownload>()).future;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _ScriptedStore store;

  Future<void> pump(WidgetTester tester) async {
    store = _ScriptedStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [whisperModelStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(body: WhisperModelTile()),
        ),
      ),
    );
    await tester.pump();
  }

  AppL10n l(WidgetTester tester) =>
      AppL10n.of(tester.element(find.byType(WhisperModelTile)));

  testWidgets('with no model it offers the download and says the size', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text(l(tester).voiceModelDownload), findsOneWidget);
    expect(
      find.text(l(tester).voiceModelSize),
      findsOneWidget,
      reason: '57 MB is the thing a person needs to know before tapping',
    );
  });

  testWidgets('tapping it actually starts the download', (tester) async {
    // The part a screenshot could never settle.
    await pump(tester);
    await tester.tap(find.byType(ListTile));
    await tester.pump();
    expect(store.downloads, 1);
  });

  testWidgets('while downloading it shows progress, not the offer', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(ListTile));
    await tester.pump();
    expect(find.text(l(tester).voiceModelDownloading), findsOneWidget);
    expect(find.text(l(tester).voiceModelDownload), findsNothing);
  });

  testWidgets('once installed it offers to remove, not to download again', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(ListTile));
    store.pending!.complete(const WhisperModelDownload.ok('/tmp/m'));
    await tester.pump();
    await tester.pump();

    expect(find.text(l(tester).voiceModelInstalled), findsOneWidget);
    expect(find.text(l(tester).voiceModelRemove), findsOneWidget);
    expect(find.text(l(tester).voiceModelDownload), findsNothing);
  });

  testWidgets('remove asks the store and returns to the offer', (tester) async {
    await pump(tester);
    store.installedNow = true;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WhisperModelTile)),
    );
    await container.read(whisperModelControllerProvider.notifier).refresh();
    await tester.pump();
    expect(find.text(l(tester).voiceModelInstalled), findsOneWidget);

    await tester.tap(find.text(l(tester).voiceModelRemove));
    await tester.pump();
    await tester.pump();
    expect(store.removals, 1);
    expect(find.text(l(tester).voiceModelDownload), findsOneWidget);
  });

  testWidgets('a failed download says so and stays tappable', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(ListTile));
    store.pending!.complete(
      const WhisperModelDownload.failed('server said 503'),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text(l(tester).voiceModelFailed), findsOneWidget);
    await tester.tap(find.byType(ListTile));
    await tester.pump();
    expect(store.downloads, 2, reason: 'a retry is one tap away');
  });
}
