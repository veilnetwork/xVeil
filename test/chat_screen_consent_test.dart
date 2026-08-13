import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chat_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/media_ffi.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

final _hex = NodeId(Uint8List.fromList(List.filled(32, 2))).hex;

Widget _host(
  Contact? contact, {
  List<Message> messages = const [],
  Stream<List<Message>>? messagesStream,
  HiddenVolumeStorage? storage,
}) => ProviderScope(
  overrides: [
    contactProvider(_hex).overrideWith((ref) => Stream.value(contact)),
    messagesProvider(
      _hex,
    ).overrideWith((ref) => messagesStream ?? Stream.value(messages)),
    if (storage != null) singleSpaceStorageProvider.overrideWithValue(storage),
  ],
  child: MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: ChatScreen(peerHex: _hex),
  ),
);

Contact _c(ContactStatus s) => Contact(nodeId: NodeId.fromHex(_hex), status: s);

class _CountingStorage extends HiddenVolumeStorage {
  _CountingStorage(FakeKvLogStore backing)
    : super(({required password, required bool create}) => backing);

  final Map<String, int> fileLoads = {};

  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) {
    fileLoads.update(fileId, (count) => count + 1, ifAbsent: () => 1);
    return super.loadFile(fileId, maxBytes: maxBytes);
  }
}

void main() {
  // These describe a build that HAS a call media engine. The mic, video-note
  // and call affordances are wired to `callMediaAvailableProvider`, and a test
  // binary carries no libveil_media, so saying so is the difference between
  // asserting the shipped shape and asserting an accident of the test host.
  // The last test asserts the other shape.
  setUp(() => VeilMediaNative.debugForceAvailable = true);
  tearDown(() {
    VeilMediaNative.debugForceAvailable = null;
    VeilMediaNative.forgetProbe();
  });

  testWidgets('incoming request shows Accept / Block, no composer', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_c(ContactStatus.pendingIncoming)));
    await tester.pump();
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing);
  });

  testWidgets('pending outgoing shows the waiting banner', (tester) async {
    await tester.pumpWidget(_host(_c(ContactStatus.pendingOutgoing)));
    await tester.pump();
    expect(find.textContaining('waiting for approval'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing);
  });

  testWidgets(
    'accepted shows the normal composer (mic on empty, send on text)',
    (tester) async {
      await tester.pumpWidget(_host(_c(ContactStatus.accepted)));
      await tester.pump();
      // Empty field → hold-to-record mic (Telegram convention); send appears
      // once there is text to send.
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.send), findsNothing);
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);
      // With an engine an accepted contact can be dialled.
      expect(find.byIcon(Icons.call), findsOneWidget);
    },
  );

  // The build the desktop plugin CMake now allows on purpose: assembled with
  // no libveil_media. Recording and dialling are not offered, rather than
  // offered and broken. Typing still works, so the chat is not crippled —
  // only the parts that need the engine are gone.
  testWidgets('with no media engine an accepted chat offers no mic and no call',
      (tester) async {
    VeilMediaNative.debugForceAvailable = false;
    await tester.pumpWidget(_host(_c(ContactStatus.accepted)));
    await tester.pump();
    expect(find.byIcon(Icons.mic), findsNothing);
    expect(find.byIcon(Icons.call), findsNothing);
    expect(find.byKey(const ValueKey('composer-video-note')), findsNothing);
    // The composer is otherwise intact.
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('no contact yet shows a connection-request composer', (
    tester,
  ) async {
    await tester.pumpWidget(_host(null));
    await tester.pump();
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.text('Write a connection request…'), findsOneWidget);
  });

  testWidgets('accepted contact can attach a file', (tester) async {
    await tester.pumpWidget(_host(_c(ContactStatus.accepted)));
    await tester.pump();
    expect(find.byIcon(Icons.attach_file), findsOneWidget);
  });

  Message txt(
    String body, {
    required MessageDirection dir,
    bool edited = false,
  }) => Message(
    id: 'm-$body',
    conversationId: _hex,
    direction: dir,
    body: body,
    timestamp: DateTime(2026, 1, 1),
    edited: edited,
  );

  testWidgets('long-press on own message offers edit + both deletes', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _c(ContactStatus.accepted),
        messages: [txt('hi', dir: MessageDirection.outgoing)],
      ),
    );
    await tester.pump();
    await tester.longPress(find.text('hi'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete for everyone'), findsOneWidget);
    expect(find.text('Delete for me'), findsOneWidget);
  });

  testWidgets('long-press on a received message offers only "delete for me"', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _c(ContactStatus.accepted),
        messages: [txt('hello', dir: MessageDirection.incoming)],
      ),
    );
    await tester.pump();
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete for everyone'), findsNothing);
    expect(find.text('Delete for me'), findsOneWidget);
  });

  testWidgets('an edited message renders the "edited" marker', (tester) async {
    await tester.pumpWidget(
      _host(
        _c(ContactStatus.accepted),
        messages: [txt('fixed', dir: MessageDirection.outgoing, edited: true)],
      ),
    );
    await tester.pump();
    expect(find.text('edited'), findsOneWidget);
  });

  testWidgets('a file message renders with its name + a save affordance', (
    tester,
  ) async {
    // A NON-image: images render as inline previews (the _ImagePreview
    // branch) since the media epic — the classic file row + save affordance
    // is the document path.
    final fileMsg = Message(
      id: 'f1',
      conversationId: _hex,
      direction: MessageDirection.incoming,
      body: '📎 report.pdf',
      timestamp: DateTime(2026, 1, 1),
      fileId: 'fid',
      fileName: 'report.pdf',
    );
    await tester.pumpWidget(
      _host(_c(ContactStatus.accepted), messages: [fileMsg]),
    );
    await tester.pump();
    expect(find.text('report.pdf'), findsOneWidget);
    // Type-specific document icon (media epic): .pdf renders the PDF glyph.
    expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
    // A held file (fileId set / hasFile) shows the "downloaded ✓" affordance —
    // unmistakable from the plain down-arrow of an un-fetched OFFER
    // (Icons.download_outlined). tap still exports/saves it.
    expect(find.byIcon(Icons.download_done_outlined), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsNothing);
  });

  testWidgets('a sticker blob is not re-read on every messages rebuild', (
    tester,
  ) async {
    final storage = _CountingStorage(FakeKvLogStore());
    await storage.open(password: 'test', createIfMissing: true);
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL7WQAAAABJRU5ErkJggg==',
    );
    await storage.storeFile('sticker-1', png, name: 'one.stkr');
    final sticker = Message(
      id: 's1',
      conversationId: _hex,
      direction: MessageDirection.incoming,
      body: '📎 one.stkr',
      timestamp: DateTime(2026, 1, 1),
      fileId: 'sticker-1',
      fileName: 'one.stkr',
    );
    final updates = StreamController<List<Message>>.broadcast();

    await tester.pumpWidget(
      _host(
        _c(ContactStatus.accepted),
        messagesStream: updates.stream,
        storage: storage,
      ),
    );
    updates.add([sticker]);
    await tester.pump();
    await tester.pump();
    expect(storage.fileLoads['sticker-1'], 1);

    for (var i = 0; i < 5; i++) {
      updates.add([sticker]);
      await tester.pump();
    }
    expect(storage.fileLoads['sticker-1'], 1);
    // Dispose the StreamProvider subscriber before awaiting controller close.
    await tester.pumpWidget(const SizedBox.shrink());
    await updates.close();
    await storage.close();
  });
}
