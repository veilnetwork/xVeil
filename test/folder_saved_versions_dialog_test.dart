import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/document_export.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/folder_publication.dart';
import 'package:xveil/data/folder_saved_versions.dart';
import 'package:xveil/domain/folder_sync.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/range_source.dart';
import 'package:xveil/features/storage/folder_saved_versions_dialog.dart';
import 'package:xveil/features/storage/folder_sync_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/folder_sync_controller.dart';

const _first = FolderSavedVersion(
  relativePath: '.xveil-0123456789abcdef0123456789abcdef.previous',
  version: LocalFile(path: 'saved', size: 4, modifiedAtMs: 1000),
  originalPath: 'first.txt',
);
const _second = FolderSavedVersion(
  relativePath: '.xveil-1123456789abcdef0123456789abcdef.incoming',
  version: LocalFile(path: 'saved', size: 4, modifiedAtMs: 2000),
  originalPath: 'second.txt',
);

class _App extends AppController {
  bool ours = true;
  @override
  AppState build() => AppState(
    AppPhase.ready,
    identity: Identity(nodeId: NodeId(Uint8List(32))),
  );
  @override
  bool holdsIdentity(IdentityLease lease) => ours && super.holdsIdentity(lease);
  void replaceIdentity() {
    ours = false;
    state = AppState(
      AppPhase.ready,
      identity: Identity(
        nodeId: NodeId(Uint8List.fromList(List.filled(32, 2))),
      ),
    );
  }
}

class _Pairs extends FolderSyncController {
  @override
  List<FolderSyncPairView> build() => const [
    FolderSyncPairView(
      pair: FolderSyncPair(id: 'pair', localPath: 'fixture-root'),
      conflicts: {},
      lastPassAtMs: null,
      lastRefusal: null,
      busy: false,
    ),
  ];
}

class _Source implements SavedFolderFile {
  bool closed = false;
  @override
  LocalFile get version => _first.version!;
  @override
  RangeSource get source => RangeSource(
    size: 4,
    read: (offset, length) async => Uint8List.fromList([1, 2, 3, 4]),
    close: () async {
      closed = true;
    },
  );
  @override
  bool Function() get unchanged =>
      () => !closed;
  @override
  bool Function(NativeFolderSession, String, String) get discard =>
      (_, _, _) => throw StateError('Unexpected direct native discard');
}

class _Access implements FolderSavedVersionAccess {
  final source = _Source();
  final cursors = <String?>[];
  Completer<FolderSavedVersionPage>? pending;
  bool fail = false;
  bool failDiscard = false;
  int removals = 0;
  @override
  Future<FolderSavedVersionPage> list(
    String root, {
    String? after,
    bool Function()? stillCurrent,
  }) async {
    cursors.add(after);
    if (fail) throw StateError('PRIVATE_CANARY');
    if (pending != null) return pending!.future;
    return after == null
        ? const FolderSavedVersionPage([_first], nextAfter: 'cursor')
        : const FolderSavedVersionPage([_second]);
  }

  @override
  Future<SavedFolderFile> open(String root, FolderSavedVersion version) async =>
      source;
  @override
  Future<bool> discard(
    String root,
    FolderSavedVersion version, {
    required Future<bool> Function() confirm,
    required bool Function() stillCurrent,
  }) async {
    try {
      if (!stillCurrent()) throw const FolderSavedOperationCancelled();
      if (!await confirm()) return false;
      if (!stillCurrent()) throw const FolderSavedOperationCancelled();
      if (failDiscard) throw const FolderFsFailure(FolderFsFailureKind.cleanup);
      removals++;
      return true;
    } finally {
      await source.source.dispose();
    }
  }
}

class _Document implements ExportDocument {
  final finishing = Completer<void>(), release = Completer<void>();
  int writes = 0, aborts = 0;
  bool denied = false;
  @override
  Future<void> write(List<int> bytes) async {
    if (denied) {
      throw const DocumentExportException('write', permissionDenied: true);
    }
    writes++;
  }

  @override
  Future<void> finish() async {
    finishing.complete();
    await release.future;
  }

  @override
  Future<void> abort() async {
    aborts++;
  }
}

void main() {
  final l = AppL10nEn();
  late _App app;
  late _Access access;
  late _Document document;
  late ProviderContainer container;
  setUp(() {
    diagnosticJournal.clear();
    app = _App();
    access = _Access();
    document = _Document();
  });
  tearDown(() => container.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Widget? child,
    ExportDocumentPicker? pick,
  }) async {
    container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(() => app),
        folderSavedVersionAccessProvider.overrideWithValue(access),
        folderSavedExportPickerProvider.overrideWithValue(
          pick ?? (_) async => document,
        ),
        folderSyncControllerProvider.overrideWith(() => _Pairs()),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(
            body:
                child ?? const FolderSavedVersionsDialog(root: 'fixture-root'),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the folder card exposes saved copies on a narrow screen', (
    tester,
  ) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, child: const FolderSyncScreen());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, l.folderSyncSavedTitle));
    await tester.pumpAndSettle();
    expect(find.byType(FolderSavedVersionsDialog), findsOneWidget);
    expect(find.text('first.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'help is shown on demand and pagination replaces the bounded page',
    (tester) async {
      await mount(tester);
      await tester.pumpAndSettle();
      expect(find.text(l.folderSyncSavedHint), findsNothing);
      await tester.tap(find.text(l.folderSyncSavedNext));
      await tester.pumpAndSettle();
      expect(access.cursors, [null, 'cursor']);
      expect(find.text('first.txt'), findsNothing);
      expect(find.text('second.txt'), findsOneWidget);
      await tester.tap(find.byTooltip(l.folderSyncSavedRefresh));
      await tester.pumpAndSettle();
      expect(access.cursors, [null, 'cursor', null]);
      await tester.tap(find.byIcon(Icons.help_outline));
      await tester.pumpAndSettle();
      expect(find.text(l.folderSyncSavedHint), findsOneWidget);
    },
  );

  testWidgets('save success appears only after destination finish', (
    tester,
  ) async {
    await mount(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l.chatFileSaveAs));
    await tester.pump();
    expect(document.finishing.isCompleted, isTrue);
    expect(find.text(l.chatFileSavedToChosenFolder), findsNothing);
    document.release.complete();
    await tester.runAsync(() => pumpEventQueue());
    expect(access.source.closed, isTrue);
    await tester.pumpAndSettle();
    expect(find.text(l.chatFileSavedToChosenFolder), findsOneWidget);
    expect(document.writes, 1);
    expect(access.source.closed, isTrue);
  });

  testWidgets('removal is cancelled without touching the selected copy', (
    tester,
  ) async {
    await mount(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l.folderSyncSavedRemove));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l.folderSyncSavedRemoveConfirm), findsOneWidget);
    expect(access.removals, 0);
    await tester.tap(find.text(l.actionCancel));
    await tester.pumpAndSettle();
    expect(access.removals, 0);
    expect(access.source.closed, isTrue);
    expect(find.text(l.folderSyncSavedRemoved), findsNothing);
  });

  testWidgets('confirmed removal refreshes inventory and reports success', (
    tester,
  ) async {
    await mount(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l.folderSyncSavedRemove));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(access.removals, 0);
    await tester.tap(find.text(l.actionRemove));
    await tester.pumpAndSettle();
    expect(access.removals, 1);
    expect(access.source.closed, isTrue);
    expect(access.cursors, [null, null]);
    expect(find.text(l.folderSyncSavedRemoved), findsOneWidget);
  });

  testWidgets('identity switch during confirmation never authorizes deletion', (
    tester,
  ) async {
    await mount(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l.folderSyncSavedRemove));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    app.replaceIdentity();
    await tester.pump();
    await tester.tap(find.text(l.actionRemove));
    await tester.pumpAndSettle();
    expect(access.removals, 0);
    expect(access.source.closed, isTrue);
    expect(find.text(l.folderSyncSavedRemoved), findsNothing);
    expect(find.text('first.txt'), findsNothing);
  });

  testWidgets(
    'recovery refusal refreshes retained copies and emits only a category',
    (tester) async {
      access.failDiscard = true;
      await mount(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l.folderSyncSavedRemove));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(l.actionRemove));
      await tester.pumpAndSettle();
      expect(access.removals, 0);
      expect(access.source.closed, isTrue);
      expect(access.cursors, [null, null]);
      expect(find.text(l.folderSyncSavedRemoveFailed), findsOneWidget);
      expect(find.text(l.folderSyncSavedRemoved), findsNothing);
      if (kDiagnosticReportEnabled) {
        final evidence =
            (diagnosticJournal.toJson()['last_evidence']
                    as Map)['folderSavedFailure']
                as Map;
        expect(evidence['values'], {
          'origin': 2,
          'code': FolderSavedDiagnosticFailure.cleanup.index,
          'success': 0,
        });
      }
    },
  );

  testWidgets(
    'permission failure reports access refusal and closes the source',
    (tester) async {
      document.denied = true;
      await mount(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l.chatFileSaveAs));
      await tester.pumpAndSettle();
      expect(find.text(l.chatFileSavePermissionDenied), findsOneWidget);
      expect(find.text(l.chatFileSavedToChosenFolder), findsNothing);
      expect(document.aborts, 1);
      expect(access.source.closed, isTrue);
      if (kDiagnosticReportEnabled) {
        final evidence =
            (diagnosticJournal.toJson()['last_evidence']
                    as Map)['folderSavedFailure']
                as Map;
        expect(evidence['values'], {
          'origin': 1,
          'code': FolderSavedDiagnosticFailure.destinationPermission.index,
          'success': 0,
        });
      }
    },
  );

  testWidgets(
    'identity switch clears visible names and aborts a delayed picker result',
    (tester) async {
      final picker = Completer<ExportDocument?>();
      await mount(tester, pick: (_) => picker.future);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l.chatFileSaveAs));
      await tester.pump();
      app.replaceIdentity();
      await tester.pump();
      expect(find.text('first.txt'), findsNothing);
      expect(find.text(l.folderSyncSavedSessionChanged), findsOneWidget);
      picker.complete(document);
      await tester.pumpAndSettle();
      expect(document.writes, 0);
      expect(document.aborts, 1);
      expect(access.source.closed, isTrue);
      expect(find.text(l.chatFileSavedToChosenFolder), findsNothing);
    },
  );

  testWidgets('late inventory cannot repopulate a switched identity', (
    tester,
  ) async {
    access.pending = Completer<FolderSavedVersionPage>();
    await mount(tester);
    app.replaceIdentity();
    await tester.pump();
    access.pending!.complete(const FolderSavedVersionPage([_first]));
    await tester.pumpAndSettle();
    expect(find.text('first.txt'), findsNothing);
    expect(find.text(l.folderSyncSavedSessionChanged), findsOneWidget);
  });

  testWidgets(
    'changing the granted root invalidates an existing view and pending picker',
    (tester) async {
      final root = ValueNotifier('first-root');
      addTearDown(root.dispose);
      final picker = Completer<ExportDocument?>();
      await mount(
        tester,
        pick: (_) => picker.future,
        child: ValueListenableBuilder<String>(
          valueListenable: root,
          builder: (_, value, _) => FolderSavedVersionsDialog(
            key: const ValueKey('saved'),
            root: value,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l.chatFileSaveAs));
      await tester.pump();
      root.value = 'replacement-root';
      await tester.pump();
      expect(find.text('first.txt'), findsNothing);
      picker.complete(document);
      await tester.pumpAndSettle();
      expect(document.writes, 0);
      expect(document.aborts, 1);
      expect(access.source.closed, isTrue);
    },
  );

  testWidgets(
    'closing a saved-copy view cancels an export awaiting its chooser',
    (tester) async {
      final picker = Completer<ExportDocument?>();
      await mount(tester, pick: (_) => picker.future);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l.chatFileSaveAs));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      picker.complete(document);
      await tester.pumpAndSettle();
      expect(document.writes, 0);
      expect(document.aborts, 1);
      expect(access.source.closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read failure is not presented as an empty history or raw error',
    (tester) async {
      access.fail = true;
      await mount(tester);
      await tester.pumpAndSettle();
      expect(find.text(l.folderSyncSavedLoadFailed), findsOneWidget);
      expect(find.text(l.folderSyncSavedEmpty), findsNothing);
      expect(find.textContaining('PRIVATE_CANARY'), findsNothing);
    },
  );
}
