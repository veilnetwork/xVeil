// Emoji picker (user remark #2): dataset sanity, search, and the
// pick-inserts-into-composer round trip on the real ChatScreen composer.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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
import 'package:xveil/features/chat/composer_expression_panel.dart';
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
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
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

  testWidgets('emoji button opens the panel; search + tap insert into field', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'p', createIfMissing: true);
    await s.upsertContact(Contact(nodeId: _peer));
    final t = _NoTransport();
    addTearDown(t.dispose);
    final m = MessagingService(t, s);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(s),
          messagingServiceProvider.overrideWithValue(m),
          messagesProvider(
            _peer.hex,
          ).overrideWith((ref) => Stream.value(const <Message>[])),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: ChatScreen(peerHex: _peer.hex),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Unified composer: paperclip; field with formatting+expression controls;
    // then separate video-note+voice controls while the draft is empty.
    final composerField = find.byType(TextField).first;
    final attach = find.byKey(const ValueKey('composer-attachment-button'));
    final expressions = find.byKey(
      const ValueKey('composer-expression-button'),
    );
    final format = find.byIcon(Icons.text_format);
    final mic = find.byIcon(Icons.mic);
    final vnote = find.byKey(const ValueKey('composer-video-note'));
    expect(attach, findsOneWidget);
    expect(expressions, findsOneWidget);
    expect(format, findsOneWidget);
    expect(mic, findsOneWidget);
    expect(vnote, findsOneWidget);
    expect(
      tester.getCenter(attach).dx,
      lessThan(tester.getCenter(composerField).dx),
    );
    expect(
      tester.getCenter(format).dx,
      greaterThan(tester.getCenter(composerField).dx),
    );
    expect(
      tester.getCenter(expressions).dx,
      greaterThan(tester.getCenter(format).dx),
    );
    expect(
      tester.getCenter(vnote).dx,
      greaterThan(tester.getCenter(expressions).dx),
    );
    expect(tester.getCenter(mic).dx, greaterThan(tester.getCenter(vnote).dx));

    await tester.tap(attach);
    await tester.pumpAndSettle();
    expect(find.text('Upload photo'), findsOneWidget);
    expect(find.text('Upload video'), findsOneWidget);
    expect(find.text('Upload file'), findsOneWidget);
    expect(find.text('Poll'), findsOneWidget);
    expect(find.text('Planned'), findsNWidgets(2));
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(expressions));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('Emoji'), findsOneWidget);
    expect(find.text('Stickers'), findsOneWidget);
    expect(find.text('GIF'), findsOneWidget);
    final panel = find.byKey(const ValueKey('composer-expression-panel'));
    expect(panel, findsOneWidget);
    expect(
      tester.getBottomLeft(panel).dy,
      lessThanOrEqualTo(
        tester.getTopLeft(composerField).dy - (kExpressionPanelBottomGap - 80),
      ),
      reason: 'expression hub must float above the composer',
    );

    // Search narrows the grid; tapping the hit inserts it and closes.
    await tester.enterText(
      find.widgetWithIcon(TextField, Icons.search),
      'rocket',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('emoji:🚀')));
    await tester.pumpAndSettle();

    final composer = find.byType(TextField).first;
    expect(tester.widget<TextField>(composer).controller!.text, '🚀');
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-video-note')), findsNothing);
    expect(find.byKey(const ValueKey('composer-voice-note')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android expression panel also floats above the composer', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(407, 904));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox()),
                SizedBox(
                  key: const ValueKey('mobile-composer'),
                  height: 64,
                  child: Center(
                    child: FilledButton(
                      onPressed: () => showComposerExpressionPanel(context),
                      child: const Text('Open'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('composer-expression-panel'));
    final composer = find.byKey(const ValueKey('mobile-composer'));
    expect(panel, findsOneWidget);
    expect(
      tester.getBottomLeft(panel).dy,
      lessThan(tester.getTopLeft(composer).dy),
      reason: 'Android hub must not grow below or cover the composer',
    );
    expect(tester.getTopLeft(panel).dx, greaterThan(0));
    expect(tester.getTopRight(panel).dx, lessThan(407));
    debugDefaultTargetPlatformOverride = null;
  });
}
