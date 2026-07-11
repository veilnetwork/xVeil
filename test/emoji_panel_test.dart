// Emoji picker (user remark #2): dataset sanity, search, and the
// pick-inserts-into-composer round trip on the real ChatScreen composer.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chat_screen.dart';
import 'package:xveil/features/chat/emoji_data.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

class _NoTransport implements VeilTransport {
  final _in = StreamController<InboundMessage>.broadcast();
  @override
  Future<NodeId> nodeId() async =>
      NodeId(Uint8List.fromList(List.filled(32, 1)));
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> send(NodeId dst, Uint8List payload,
      {bool anonymous = false}) async {}
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async {}
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

final _peer = NodeId(Uint8List.fromList(List.filled(32, 2)));

void main() {
  test('dataset is well-formed and search finds by name', () {
    expect(emojiGroups, isNotEmpty);
    for (final g in emojiGroups) {
      expect(g.entries, isNotEmpty, reason: g.name);
      for (final e in g.entries) {
        expect(e.char, isNotEmpty, reason: '${g.name}:${e.name}');
        expect(e.name, isNotEmpty, reason: '${g.name}:${e.char}');
      }
    }
    expect(searchEmoji('heart'), isNotEmpty);
    expect(searchEmoji('HEART'), isNotEmpty); // case-insensitive
    expect(searchEmoji(''), isEmpty);
    expect(searchEmoji('zzznotanemoji'), isEmpty);
  });

  testWidgets('emoji button opens the panel; search + tap insert into field',
      (tester) async {
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'p', createIfMissing: true);
    await s.upsertContact(Contact(nodeId: _peer));
    final t = _NoTransport();
    addTearDown(t.dispose);
    final m = MessagingService(t, s);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(s),
        messagingServiceProvider.overrideWithValue(m),
        messagesProvider(_peer.hex)
            .overrideWith((ref) => Stream.value(const <Message>[])),
      ],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: ChatScreen(peerHex: _peer.hex),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // Minimal composer: field in the middle, one extras menu + formatting to
    // its right, and the voice/send control at the far right. Sticker/video
    // are not permanent buttons anymore.
    final composerField = find.byType(TextField).first;
    final extras = find.byIcon(Icons.add_circle_outline);
    final format = find.byIcon(Icons.text_format);
    final mic = find.byIcon(Icons.mic);
    expect(extras, findsOneWidget);
    expect(format, findsOneWidget);
    expect(mic, findsOneWidget);
    expect(find.byIcon(Icons.sticky_note_2_outlined), findsNothing);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);
    expect(tester.getCenter(extras).dx,
        greaterThan(tester.getCenter(composerField).dx));
    expect(tester.getCenter(format).dx, greaterThan(tester.getCenter(extras).dx));
    expect(tester.getCenter(mic).dx, greaterThan(tester.getCenter(format).dx));

    await tester.tap(extras);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.emoji_emotions_outlined), findsNWidgets(2));
    expect(find.byIcon(Icons.sticky_note_2_outlined), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pumpAndSettle();

    // Search narrows the grid; tapping the hit inserts it and closes.
    await tester.enterText(
        find.widgetWithIcon(TextField, Icons.search), 'rocket');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('emoji:🚀')));
    await tester.pumpAndSettle();

    final composer = find.byType(TextField).first;
    expect(tester.widget<TextField>(composer).controller!.text, '🚀');
  });
}
