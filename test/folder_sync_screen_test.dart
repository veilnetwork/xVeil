@TestOn('!windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/posix_file_facts.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/features/storage/folder_sync_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/providers.dart';

/// A Storage that only remembers files — everything else a caller reaches for
/// hits noSuchMethod and fails loudly rather than returning a quiet default.
/// Same fake as the root-gate test, for the same reason.
class _FileOnlyStorage implements Storage {
  final files = <String, Uint8List>{};

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    files[fileId] = bytes;
  }

  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) async =>
      files[fileId];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _mode0777 = 0x1FF;
const _mode0755 = 0x1ED;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory tempRoot(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  /// Mounts the screen with the picker answering [path].
  ///
  /// Everything the add path touches from here is SYNCHRONOUS — the store is
  /// in memory and `folderSyncRootRefusal` stats with `lstat` — which is what
  /// makes this drivable in a widget test at all. Real async file work inside
  /// `testWidgets` does not complete under the fake clock: it does not fail
  /// either, it just never lands, and the assertion then measures nothing.
  Future<AppL10n> pumpScreen(WidgetTester tester, String path) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storageProvider.overrideWith((ref) => _FileOnlyStorage())],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: FolderSyncScreen(pickDirectory: () async => path),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppL10n.of(tester.element(find.byType(FolderSyncScreen)));
  }

  // A refused folder used to look exactly like a tap that did nothing: the
  // reason came back from `addPair` and was dropped on the floor. What people
  // learn from a button that does nothing is that the app is broken — so they
  // stop trusting the mirror, or they go looking for a folder that "works",
  // which here means one they were being protected from.
  testWidgets('a folder another account can write to says WHY it was refused',
      (tester) async {
    final tmp = tempRoot('xveil_sync_screen_open');
    final parent = Directory('${tmp.path}/open')..createSync();
    final root = Directory('${parent.path}/mirror')..createSync();
    expect(posixChmod(root.path, _mode0755), 0);
    expect(posixChmod(parent.path, _mode0777), 0);

    final l = await pumpScreen(tester, root.path);
    await tester.tap(find.widgetWithText(FloatingActionButton, l.folderSyncAdd));
    await tester.pumpAndSettle();

    expect(
      find.text(l.folderSyncNotAddedTitle),
      findsOneWidget,
      reason: 'a refusal nobody is told about is indistinguishable from a bug',
    );
    // The reason itself, on screen — not a paraphrase. It names the step in
    // the chain that is actually open, which is the one part a person cannot
    // guess, and it says what the danger is rather than "refused".
    final shown = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data ?? '')
        .join('\n');
    expect(
      shown,
      contains(parent.path),
      reason: 'the message must name the folder that is actually open',
    );
    expect(
      shown,
      contains('could be redirected somewhere else'),
      reason: 'a person cannot act on the word "refused"',
    );
    // GUARD — stays green with the fix removed. Here to pin that showing the
    // reason did not also quietly configure the pair.
    expect(find.text(root.path), findsNothing);
  });

  testWidgets('an overlapping folder is refused through the SAME path',
      (tester) async {
    // The second reason `addPair` can give. It travels the same way and must
    // arrive the same way — a screen that surfaces one refusal and swallows
    // the other is only half-wired.
    final tmp = tempRoot('xveil_sync_screen_overlap');
    final root = Directory('${tmp.path}/mirror')..createSync();
    expect(posixChmod(root.path, _mode0755), 0);
    final nested = Directory('${root.path}/inside')..createSync();
    expect(posixChmod(nested.path, _mode0755), 0);

    // First add succeeds and closes nothing; the second overlaps it.
    late String picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storageProvider.overrideWith((ref) => _FileOnlyStorage())],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: FolderSyncScreen(pickDirectory: () async => picked),
        ),
      ),
    );
    picked = root.path;
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(FolderSyncScreen)));

    await tester.tap(find.widgetWithText(FloatingActionButton, l.folderSyncAdd));
    await tester.pumpAndSettle();
    expect(
      find.text(l.folderSyncNotAddedTitle),
      findsNothing,
      reason: 'a folder that IS accepted must not be reported as refused',
    );
    expect(find.text(root.path), findsOneWidget, reason: 'it was configured');

    picked = nested.path;
    await tester.tap(find.widgetWithText(FloatingActionButton, l.folderSyncAdd));
    await tester.pumpAndSettle();

    expect(find.text(l.folderSyncNotAddedTitle), findsOneWidget);
    final shown = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data ?? '')
        .join('\n');
    expect(shown, contains('overlaps a folder that is already synced'));

    // Dismissing leaves the one good pair and nothing else.
    await tester.tap(find.widgetWithText(TextButton, l.actionDone));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(nested.path), findsNothing);
  });
}
