import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/cloud.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/cloud_collection_crdt.dart';
import 'package:xveil/domain/cloud_document.dart';
import 'package:xveil/domain/cloud_document_replication.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/features/storage/cloud_storage_screen.dart';
import 'package:xveil/features/storage/cloud_collection_editor.dart';
import 'package:xveil/features/storage/cloud_shared_document_editor.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/cloud_service.dart';
import 'package:xveil/state/cloud_document_envelope_service.dart';
import 'package:xveil/state/cloud_document_crypto.dart';
import 'package:xveil/state/cloud_document_providers.dart';
import 'package:xveil/state/cloud_document_replication_service.dart';
import 'package:xveil/state/cloud_document_store.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';

import 'support/fake_hv_container.dart';

class _Sync implements CloudSyncPort {
  final _changes = StreamController<void>.broadcast();
  final rows = <DeviceSyncRecord>[];

  @override
  NodeId get selfId => NodeId(Uint8List(32)..[0] = 7);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<NodeId>> members() async => [selfId];

  @override
  Future<List<DeviceSyncRecord>> records() async => [...rows];

  @override
  Future<bool> postItem(CloudItem item) async {
    rows.add((event: item.toEvent(), author: selfId));
    return true;
  }

  @override
  Future<bool> postClaim(CloudReplicaClaim claim) async {
    rows.add((event: claim.toEvent(), author: selfId));
    return true;
  }

  @override
  Future<bool> fetch(String contentId, NodeId holder) async => false;

  @override
  Future<void> close() async => unawaited(_changes.close());

  void inject(CloudItem item, NodeId author) {
    rows.add((event: item.toEvent(), author: author));
    _changes.add(null);
  }
}

class _DocumentSigner implements CloudDocumentSigner {
  _DocumentSigner(this.selfId);

  @override
  final NodeId selfId;

  @override
  CloudDocumentRoot signRoot(CloudDocumentRoot unsigned) =>
      unsigned.withSignature(
        Uint8List(64)..fillRange(0, 64, 7),
        Uint8List(32)..fillRange(0, 32, 7),
      );

  @override
  CloudDocumentControlEntry signControl(CloudDocumentControlEntry unsigned) =>
      unsigned.withSignature(
        Uint8List(64)..fillRange(0, 64, 7),
        Uint8List(32)..fillRange(0, 32, 7),
      );

  @override
  CloudDocumentOperation signOperation(CloudDocumentOperation unsigned) =>
      unsigned.withSignature(
        Uint8List(64)..fillRange(0, 64, 7),
        Uint8List(32)..fillRange(0, 32, 7),
      );

  @override
  CloudDocumentQuiescenceAck signQuiescenceAck(
    CloudDocumentQuiescenceAck unsigned,
  ) => unsigned.withSignature(
    Uint8List(64)..fillRange(0, 64, 7),
    Uint8List(32)..fillRange(0, 32, 7),
  );
}

Future<void> _pumpTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
}

String _hexFill(int byte) => List.filled(
  32,
  byte,
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

void main() {
  testWidgets('shared-document invite stays explicit and can be rejected', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final cloud = CloudService(
      storage,
      _Sync(),
      contentReceived: const Stream.empty(),
      integrityChecks: false,
    );
    final documentStore = CloudDocumentStore(storage);
    final owner = NodeId(Uint8List(32)..[0] = 9);
    final documentId = NodeId(Uint8List(32)..[0] = 10);
    final root = CloudDocumentRoot(
      documentId: documentId,
      owner: owner,
      ownerPubKey: Uint8List(32),
      kind: CloudDocumentKind.note,
      codec: 'xveil.note.rga.v1',
      epochKeyCommitment: _hexFill(0x11),
      epochEnvelopeHash: _hexFill(0x22),
      controlLogRoot: _hexFill(0x33),
      createdAtMs: 1,
      signature: Uint8List(64),
    );
    await documentStore.savePendingInvite(
      CloudDocumentPendingInvite(
        sender: owner,
        receivedAtMs: 2,
        frame: CloudDocumentFrame(
          kind: CloudDocumentFrameKind.invite,
          root: root,
          controls: const [],
          operations: const [],
          envelopes: const [],
        ),
      ),
    );
    final documents = CloudDocumentReplicationService(
      localNodeId: _Sync().selfId,
      ourCertVersion: 0,
      store: documentStore,
      envelopes: CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
      sendFrame: (_, _, _) async {},
      verifyRoot: (_) => true,
      verifyControl: (_) => true,
      verifyOperation: (_) => true,
    );
    addTearDown(() {
      unawaited(documents.close());
      unawaited(cloud.close());
      unawaited(storage.close());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cloudServiceProvider.overrideWithValue(cloud),
          cloudDocumentReplicationServiceProvider.overrideWithValue(documents),
        ],
        child: const MaterialApp(
          locale: Locale('ru'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: CloudStorageScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Приглашения в общие документы (1)'), findsOneWidget);
    expect(find.textContaining('Приглашение от 09000000'), findsOneWidget);
    expect(await documentStore.load(documentId.hex), isNull);

    await tester.tap(find.text('Отклонить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Приглашения в общие документы (1)'), findsNothing);
    expect(await documentStore.listPendingInviteIds(), isEmpty);
  });

  testWidgets('owner creates a shared document and manages ACL through UI', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final sync = _Sync();
    final peer = NodeId(Uint8List(32)..[0] = 8);
    await storage.upsertContact(
      Contact(nodeId: peer, name: 'Alice', status: ContactStatus.accepted),
    );
    final cloud = CloudService(
      storage,
      sync,
      contentReceived: const Stream.empty(),
      integrityChecks: false,
    );
    final sent = <String>[];
    final documents = CloudDocumentReplicationService(
      localNodeId: sync.selfId,
      ourCertVersion: 0,
      store: CloudDocumentStore(storage),
      envelopes: CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: sync.selfId),
      ),
      sendFrame: (_, _, frame) async => sent.add(frame),
      signer: _DocumentSigner(sync.selfId),
      acceptedContact: (candidate) async => candidate == peer,
      verifyRoot: (_) => true,
      verifyControl: (_) => true,
      verifyOperation: (_) => true,
    );
    addTearDown(() {
      unawaited(documents.close());
      unawaited(cloud.close());
      unawaited(storage.close());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cloudServiceProvider.overrideWithValue(cloud),
          cloudDocumentReplicationServiceProvider.overrideWithValue(documents),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: CloudStorageScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Add to cloud'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New shared document'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Editor'));
    await tester.pumpAndSettle();

    expect(sent, hasLength(1));
    expect(find.text('Shared documents (1)'), findsOneWidget);
    await tester.tap(find.text('Shared documents (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Shared Note').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cloud-rich-editor')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-rich-close')), findsOneWidget);
    expect(
      find.byType(BottomSheet),
      findsNothing,
      reason: 'a collaborative editor is a full screen, not a modal sheet',
    );
    final richField = find.byKey(const ValueKey('cloud-rich-editor'));
    final richController = tester.widget<TextField>(richField).controller!;
    expect(
      richController
          .buildTextSpan(
            context: tester.element(richField),
            style: null,
            withComposing: false,
          )
          .style
          ?.color,
      isNotNull,
      reason: 'custom rich spans must inherit a visible theme color',
    );
    await tester.enterText(richField, 'Shared text');
    await tester.pump();
    expect(tester.widget<TextField>(richField).controller!.text, 'Shared text');
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('cloud-rich-save')))
          .onPressed,
      isNotNull,
    );
    tester
        .widget<TextField>(find.byKey(const ValueKey('cloud-rich-editor')))
        .controller!
        .selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 6,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cloud-rich-bold')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cloud-rich-save')));
    await tester.pumpAndSettle();
    final rich = (await documents.loadRichText(
      (await documents.listDocuments()).single.root.documentId.hex,
    ))!.snapshot;
    expect(rich.text, 'Shared text');
    expect(rich.atoms.take(6).every((atom) => atom.style.bold), isTrue);
    expect(rich.atoms.skip(6).every((atom) => !atom.style.bold), isTrue);
    sent.clear();
    await tester.tap(find.byKey(const ValueKey('cloud-rich-manage')));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Editor'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resend invitation'));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Viewer'));
    await tester.pumpAndSettle();
    var view = (await documents.listDocuments()).single;
    expect(view.currentEpoch, 2);
    expect(view.members[peer.hex], CloudDocumentRole.viewer);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke access'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke access'));
    await tester.pumpAndSettle();
    view = (await documents.listDocuments()).single;
    expect(view.currentEpoch, 3);
    expect(view.members.containsKey(peer.hex), isFalse);

    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Rotate encryption key'),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, 'Rotate encryption key'),
    );
    await tester.pumpAndSettle();
    expect((await documents.listDocuments()).single.currentEpoch, 4);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Compact history'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Ask current editors to confirm'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Compact history'));
    await tester.pumpAndSettle();
    expect((await documents.listDocuments()).single.root.generation, 1);
    semantics.dispose();
  });

  testWidgets('shared editor header stays readable in narrow Russian layout', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final self = NodeId(Uint8List(32)..[0] = 4);
    final documents = CloudDocumentReplicationService(
      localNodeId: self,
      ourCertVersion: 0,
      store: CloudDocumentStore(storage),
      envelopes: CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: self),
      ),
      sendFrame: (_, _, _) async {},
      signer: _DocumentSigner(self),
      verifyRoot: (_) => true,
      verifyControl: (_) => true,
      verifyOperation: (_) => true,
    );
    final documentId = (await documents.createDocument())!.documentId;
    addTearDown(() {
      unawaited(documents.close());
      unawaited(storage.close());
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: CloudSharedDocumentEditor(
            service: documents,
            documentId: documentId,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Общая заметка'), findsOneWidget);
    expect(
      find.text('Совместное редактирование с шифрованием'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('cloud-rich-block')), findsOneWidget);
    expect(
      tester
          .getBottomLeft(find.text('Совместное редактирование с шифрованием'))
          .dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('cloud-rich-bold'))).dy,
      ),
      reason: 'the wrapped Russian subtitle must end above the toolbar',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared collection editors create tasks and calendar events', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final self = NodeId(Uint8List(32)..[0] = 5);
    final documents = CloudDocumentReplicationService(
      localNodeId: self,
      ourCertVersion: 0,
      store: CloudDocumentStore(storage),
      envelopes: CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: self),
      ),
      sendFrame: (_, _, _) async {},
      signer: _DocumentSigner(self),
      verifyRoot: (_) => true,
      verifyControl: (_) => true,
      verifyOperation: (_) => true,
    );
    final documentId = (await documents.createDocument(
      kind: CloudDocumentKind.taskList,
      codec: cloudTaskListCodecV1,
    ))!.documentId;
    addTearDown(() {
      unawaited(documents.close());
      unawaited(storage.close());
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: CloudCollectionEditor(
            service: documents,
            documentId: documentId,
          ),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('Общие задачи'));
    expect(find.text('Общие задачи'), findsOneWidget);
    expect(find.text('Задач пока нет'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cloud-task-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('cloud-task-title')),
      'Проверить CRDT',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Проверить CRDT'), findsOneWidget);
    var state = (await documents.loadCollection(documentId))!;
    expect(state.tasks.single.completed, isFalse);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    state = (await documents.loadCollection(documentId))!;
    expect(state.tasks.single.completed, isTrue);
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pumpAndSettle();

    final calendarId = (await documents.createDocument(
      kind: CloudDocumentKind.calendar,
      codec: cloudCalendarCodecV1,
    ))!.documentId;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: CloudCollectionEditor(
            service: documents,
            documentId: calendarId,
          ),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('Общий календарь'));
    expect(find.text('Общий календарь'), findsOneWidget);
    final addEvent = find.byKey(const ValueKey('cloud-event-add'));
    await tester.ensureVisible(addEvent);
    await tester.tap(addEvent);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('cloud-event-title')),
      'Встреча',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Встреча'), findsOneWidget);
    final calendar = (await documents.loadCollection(calendarId))!;
    expect(calendar.events.single.title, 'Встреча');
    expect(
      calendar.events.single.endAtMs,
      greaterThan(calendar.events.single.startAtMs),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('personal cloud note opens, edits, and saves through the UI', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = CloudService(
      storage,
      _Sync(),
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      newId: () => 'note_1',
      integrityChecks: false,
    );
    addTearDown(() {
      unawaited(service.close());
      unawaited(storage.close());
    });
    await service.saveTextNote(title: 'Private note', body: 'first body');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: CloudStorageScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Private note'), findsOneWidget);
    expect(find.byIcon(Icons.note_outlined), findsOneWidget);

    await tester.tap(find.text('Private note'));
    await _pumpTransition(tester);
    expect(find.text('Edit note'), findsOneWidget);
    expect(find.text('first body'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'Updated note');
    await tester.enterText(find.byType(TextField).at(1), 'second body');
    await tester.tap(find.text('Save'));
    await _pumpTransition(tester);

    expect(find.text('Updated note'), findsOneWidget);
    final updated = (await service.listItems()).single;
    expect(updated.revision, 2);
    expect(await service.loadTextNote(updated), 'second body');
  });

  testWidgets('note editor exposes a merge choice on a stale revision', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    var clock = 2000;
    final service = CloudService(
      storage,
      _Sync(),
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
      newId: () => 'note_conflict',
      integrityChecks: false,
    );
    addTearDown(() {
      unawaited(service.close());
      unawaited(storage.close());
    });
    final original = await service.saveTextNote(
      title: 'Conflict note',
      body: 'v1',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: CloudStorageScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Conflict note'));
    await _pumpTransition(tester);

    await service.saveTextNote(
      itemId: original.id,
      expectedRevision: original.revision,
      expectedContentId: original.contentId,
      title: 'Conflict note',
      body: 'remote v2',
    );
    await tester.enterText(find.byType(TextField).at(1), 'local draft');
    await tester.tap(find.text('Save'));
    await _pumpTransition(tester);

    expect(find.text('This note changed on another device'), findsOneWidget);
    expect(find.textContaining('remote v2'), findsOneWidget);
    expect(find.text('local draft'), findsWidgets);
    await tester.tap(find.text('Save merged version'));
    await _pumpTransition(tester);

    final merged = (await service.listItems()).single;
    expect(merged.revision, 3);
    expect(await service.loadTextNote(merged), 'local draft');
  });

  testWidgets('offline note branches are visible, reviewable, and mergeable', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final sync = _Sync();
    var clock = 5000;
    final service = CloudService(
      storage,
      sync,
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
      newId: () => 'branch_ui',
      integrityChecks: false,
    );
    addTearDown(() {
      unawaited(service.close());
      unawaited(storage.close());
    });
    final root = await service.saveTextNote(title: 'Branch UI', body: 'root');
    final left = await service.saveTextNote(
      itemId: root.id,
      expectedRevision: root.revision,
      expectedContentId: root.contentId,
      title: 'Branch UI',
      body: 'left branch',
    );
    final rightBytes = Uint8List.fromList(utf8.encode('right branch'));
    final rightManifest = ContentManifest.fromBytes('Branch UI', rightBytes);
    await storage.storeFile(rightManifest.contentId, rightBytes);
    await storage.storeFile(
      'mf:${rightManifest.contentId}',
      Uint8List.fromList(utf8.encode(jsonEncode(rightManifest.toJson()))),
    );
    sync.inject(
      CloudItem(
        id: root.id,
        kind: CloudItemKind.note,
        name: 'Branch UI',
        contentId: rightManifest.contentId,
        size: rightBytes.length,
        mime: 'text/plain; charset=utf-8',
        createdAtMs: root.createdAtMs,
        modifiedAtMs: left.modifiedAtMs + 100,
        revision: 2,
        deleted: false,
        parentContentIds: [root.contentId!],
      ),
      NodeId(Uint8List(32)..[0] = 8),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: CloudStorageScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('2 offline versions'), findsOneWidget);

    await tester.tap(find.text('Branch UI'));
    await _pumpTransition(tester);
    expect(find.text('Review versions'), findsOneWidget);
    await tester.tap(find.text('Review versions'));
    await _pumpTransition(tester);
    expect(find.textContaining('left branch'), findsOneWidget);
    expect(find.textContaining('right branch'), findsWidgets);
    await tester.enterText(find.byType(TextField).last, 'merged in UI');
    await tester.tap(find.text('Save merged version'));
    await _pumpTransition(tester);
    expect(find.textContaining('Merge prepared'), findsWidgets);
    await tester.tap(find.text('Save'));
    await _pumpTransition(tester);

    final merged = (await service.listItems()).single;
    expect(merged.revision, 3);
    expect(service.noteHeads(merged), hasLength(1));
    expect(await service.loadTextNote(merged), 'merged in UI');
  });

  testWidgets('personal cloud renders imported file and replication controls', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = CloudService(
      storage,
      _Sync(),
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      newId: () => 'file_1',
      integrityChecks: false,
    );
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    await service.importContent(
      name: 'proof.bin',
      size: bytes.length,
      readRange: (offset, length) async =>
          Uint8List.fromList(bytes.sublist(offset, offset + length)),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: CloudStorageScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Personal cloud'), findsOneWidget);
    expect(find.text('proof.bin'), findsOneWidget);
    expect(find.text('4 B · on this device · 1 verified copy'), findsOneWidget);
    expect(find.textContaining('1 verified copy'), findsOneWidget);
    expect(find.text('Index only'), findsOneWidget);
    expect(find.byIcon(Icons.health_and_safety_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Share with contact'), findsOneWidget);
    await tester.tap(find.text('Share with contact'));
    await tester.pumpAndSettle();
    expect(find.text('No accepted contacts to share with'), findsOneWidget);
  });
}
