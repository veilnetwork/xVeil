import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/cloud.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/features/chat/message_markdown.dart';
import 'package:xveil/features/storage/cloud_attachment.dart';
import 'package:xveil/features/storage/cloud_note_editor.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/cloud_service.dart';

import 'support/fake_hv_container.dart';

class _Sync implements CloudSyncPort {
  final _changes = StreamController<void>.broadcast();
  final rows = <DeviceSyncRecord>[];

  @override
  NodeId get selfId => NodeId(Uint8List(32)..[0] = 3);

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
  Future<bool> postFolder(CloudFolder folder) async {
    rows.add((event: folder.toEvent(), author: selfId));
    return true;
  }

  @override
  Future<bool> postClaim(CloudReplicaClaim claim) async {
    rows.add((event: claim.toEvent(), author: selfId));
    return true;
  }

  @override
  void vouchForContent(Future<Set<String>> Function() ids) {}

  @override
  Future<bool> fetch(String contentId, NodeId holder) async => false;

  @override
  Future<void> close() async => unawaited(_changes.close());
}

CloudService _service(dynamic storage, {Iterable<String> ids = const []}) {
  final queue = ids.iterator;
  var clock = 30000;
  return CloudService(
    storage,
    _Sync(),
    contentReceived: const Stream.empty(),
    now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
    newId: () => queue.moveNext() ? queue.current : 'generated',
    integrityChecks: false,
  );
}

Widget _host(CloudService service, Widget child) => ProviderScope(
  overrides: [cloudServiceProvider.overrideWithValue(service)],
  child: MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(body: child),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('reference parsing', () {
    test('a veil-cloud reference is its own token carrying the bare id', () {
      expect(parseFormatted('see veil-cloud:abc now'), const [
        FmtToken(FmtKind.plain, 'see '),
        FmtToken(FmtKind.cloudAttachment, 'abc'),
        FmtToken(FmtKind.plain, ' now'),
      ]);
    });

    test('an id full of underscores survives the italic marker', () {
      // The whole reason the attachment scan runs BEFORE the markers: `_` is an
      // italic delimiter and item ids are allowed to contain it.
      expect(parseFormatted('veil-cloud:note_1_beta'), const [
        FmtToken(FmtKind.cloudAttachment, 'note_1_beta'),
      ]);
    });

    test('a reference ending a sentence gives the punctuation back', () {
      expect(parseFormatted('open veil-cloud:x-9.'), const [
        FmtToken(FmtKind.plain, 'open '),
        FmtToken(FmtKind.cloudAttachment, 'x-9'),
        FmtToken(FmtKind.plain, '.'),
      ]);
    });

    test('a reference inside inline code stays literal', () {
      expect(parseFormatted('`veil-cloud:abc`'), const [
        FmtToken(FmtKind.code, 'veil-cloud:abc'),
      ]);
    });

    test('the scheme without an id is ordinary text', () {
      expect(parseFormatted('veil-cloud: nothing'), const [
        FmtToken(FmtKind.plain, 'veil-cloud: nothing'),
      ]);
    });
  });

  group('reference insertion', () {
    test('insertion at a caret pads the reference away from its neighbours', () {
      final edit = insertCloudAttachment(
        'before after',
        const TextSelection.collapsed(offset: 6),
        'i1',
      );
      expect(edit.text, 'before veil-cloud:i1 after');
      expect(edit.selection.baseOffset, 20);
      expect(edit.selection.isCollapsed, isTrue);
    });

    test('insertion into empty text adds no leading space', () {
      final edit = insertCloudAttachment(
        '',
        const TextSelection.collapsed(offset: 0),
        'i1',
      );
      expect(edit.text, 'veil-cloud:i1 ');
    });

    test('insertion replaces a selection', () {
      final edit = insertCloudAttachment(
        'keep DROP keep',
        const TextSelection(baseOffset: 5, extentOffset: 9),
        'i1',
      );
      expect(edit.text, 'keep veil-cloud:i1 keep');
    });

    test('a round trip through the parser recovers the item id', () {
      final edit = insertCloudAttachment(
        'note body',
        const TextSelection.collapsed(offset: 9),
        'round_trip_1',
      );
      expect(
        parseFormatted(edit.text).where(
          (token) => token.kind == FmtKind.cloudAttachment,
        ),
        const [FmtToken(FmtKind.cloudAttachment, 'round_trip_1')],
      );
    });
  });

  testWidgets('a live reference renders as a named attachment, not as text', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = _service(storage, ids: ['att_1']);
    addTearDown(() {
      unawaited(service.close());
      unawaited(storage.close());
    });
    final bytes = Uint8List.fromList(List.filled(2048, 5));
    final item = await service.importContent(
      name: 'report.pdf',
      size: bytes.length,
      readRange: (offset, length) async =>
          Uint8List.sublistView(bytes, offset, offset + length),
    );

    await tester.pumpWidget(
      _host(service, const FormattedText('read veil-cloud:att_1 please')),
    );
    await _settle(tester);

    expect(find.byKey(const ValueKey('cloud-attachment-att_1')), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('2.0 KiB'), findsOneWidget);
    expect(
      find.textContaining('veil-cloud:'),
      findsNothing,
      reason: 'a resolved reference is an attachment, never its own markup',
    );
    expect(item.id, 'att_1');
  });

  testWidgets('a reference to a deleted item renders as visibly unavailable', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = _service(storage, ids: ['gone_1']);
    addTearDown(() {
      unawaited(service.close());
      unawaited(storage.close());
    });
    final bytes = Uint8List.fromList(List.filled(64, 1));
    await service.importContent(
      name: 'doomed.bin',
      size: bytes.length,
      readRange: (offset, length) async =>
          Uint8List.sublistView(bytes, offset, offset + length),
    );

    await tester.pumpWidget(
      _host(service, const FormattedText('here veil-cloud:gone_1 end')),
    );
    await _settle(tester);
    expect(find.text('doomed.bin'), findsOneWidget);

    await service.deleteItem('gone_1');
    await _settle(tester);

    // The whole justification for keeping attachments in the body: the dangling
    // reference must be SEEN. Not raw markup, not silence.
    expect(
      find.text('Attachment unavailable'),
      findsOneWidget,
      reason: 'a dead reference must name itself as unavailable',
    );
    expect(find.text('doomed.bin'), findsNothing);
    expect(
      find.textContaining('veil-cloud:'),
      findsNothing,
      reason: 'an unavailable attachment is still an attachment, not markup',
    );
    expect(find.byIcon(Icons.link_off), findsOneWidget);
    final chip = find.byKey(const ValueKey('cloud-attachment-gone_1'));
    expect(chip, findsOneWidget);
    expect(
      tester.getSize(chip).width,
      greaterThan(0),
      reason: 'an invisible unavailable state would break the whole design',
    );
  });

  testWidgets('a reference no index ever knew still renders as unavailable', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = _service(storage);
    addTearDown(() {
      unawaited(service.close());
      unawaited(storage.close());
    });

    await tester.pumpWidget(
      _host(service, const FormattedText('veil-cloud:never_existed')),
    );
    await _settle(tester);

    expect(find.text('Attachment unavailable'), findsOneWidget);
    expect(find.textContaining('veil-cloud:'), findsNothing);
    expect(
      find.byKey(const ValueKey('cloud-attachment-never_existed')),
      findsOneWidget,
    );
  });

  testWidgets('an index that has not answered yet is not a missing item', (
    tester,
  ) async {
    // A cloud whose index never resolves — the state a device is in while it
    // opens its volume. Calling every attachment dead in that window would
    // teach the reader to ignore the one state that matters.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cloudItemsProvider.overrideWith(
            (ref) => Stream<List<CloudItem>>.fromFuture(
              Completer<List<CloudItem>>().future,
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          locale: Locale('en'),
          home: Scaffold(body: FormattedText('veil-cloud:pending_1')),
        ),
      ),
    );
    await _settle(tester);

    expect(
      find.text('Attachment unavailable'),
      findsNothing,
      reason: 'an unanswered index must not be reported as a missing item',
    );
    expect(
      find.byKey(const ValueKey('cloud-attachment-pending_1')),
      findsOneWidget,
      reason: 'the attachment is still shown, just not yet named',
    );
    expect(find.text('Attachment'), findsOneWidget);
  });

  testWidgets('tapping a dead attachment says what happened to it', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = _service(storage);
    addTearDown(() {
      unawaited(service.close());
      unawaited(storage.close());
    });

    await tester.pumpWidget(
      _host(service, const FormattedText('veil-cloud:vanished')),
    );
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('cloud-attachment-vanished')));
    await tester.pump();
    expect(
      find.text('This attachment is no longer in your cloud'),
      findsOneWidget,
    );
  });

  testWidgets('the note editor attaches an existing item by reference', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = _service(storage, ids: ['pick_1', 'note_1']);
    addTearDown(() {
      unawaited(service.close());
      unawaited(storage.close());
    });
    final bytes = Uint8List.fromList(List.filled(128, 9));
    await service.importContent(
      name: 'invoice.pdf',
      size: bytes.length,
      readRange: (offset, length) async =>
          Uint8List.sublistView(bytes, offset, offset + length),
    );

    await tester.pumpWidget(
      _host(service, CloudNoteEditorScreen(service: service)),
    );
    await _settle(tester);

    await tester.enterText(find.byType(TextField).at(0), 'With an attachment');
    await tester.enterText(find.byType(TextField).at(1), 'see this');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('cloud-note-attach')));
    await tester.pumpAndSettle();
    expect(find.text('Attach from your cloud'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cloud-attachment-pick-pick_1')));
    await tester.pumpAndSettle();

    final body = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(body.controller!.text, 'see this veil-cloud:pick_1 ');

    // Saved, reread, and shown in preview: the reference is ordinary note text
    // that renders as the file it names.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = (await service.listItems())
        .where((item) => item.kind == CloudItemKind.note)
        .single;
    expect(
      await service.loadTextNote(saved),
      'see this veil-cloud:pick_1 ',
      reason: 'the attachment travels inside the note body and nowhere else',
    );
    expect(
      saved.parentContentIds,
      isEmpty,
      reason: 'attaching must not touch the item row or its DAG',
    );
  });

  testWidgets('the note preview renders an attached reference as a chip', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = _service(storage, ids: ['prev_1', 'prev_note']);
    addTearDown(() {
      unawaited(service.close());
      unawaited(storage.close());
    });
    final bytes = Uint8List.fromList(List.filled(64, 4));
    await service.importContent(
      name: 'slides.key',
      size: bytes.length,
      readRange: (offset, length) async =>
          Uint8List.sublistView(bytes, offset, offset + length),
    );
    final note = await service.saveTextNote(
      title: 'Preview',
      body: 'attached veil-cloud:prev_1 here',
    );

    await tester.pumpWidget(
      _host(service, CloudNoteEditorScreen(service: service, item: note)),
    );
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('cloud-note-attach')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cloud-attachment-pick-prev_1')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('cloud-attachment-pick-${note.id}')),
      findsNothing,
      reason: 'a note attaching itself renders a chip that reopens itself',
    );
    Navigator.of(tester.element(find.byType(ListView).last)).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('cloud-note-preview')));
    await _settle(tester);

    expect(
      find.byKey(const ValueKey('cloud-attachment-prev_1')),
      findsOneWidget,
    );
    expect(find.text('slides.key'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('cloud-note-attach')))
          .onPressed,
      isNull,
      reason: 'read mode has no caret, so there is nowhere to insert',
    );
  });
}
