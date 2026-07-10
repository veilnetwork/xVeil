// Composer keyboard convention (user remark #1, 2026-07-10): Enter SENDS,
// Shift+Enter inserts a NEWLINE. Hardware key events drive the real
// CallbackShortcuts bindings; a real (in-memory) storage + no-op transport
// let the Enter path complete an actual send, which clears the composer.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chat_screen.dart';
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
  testWidgets('Enter sends (composer clears); Shift+Enter inserts a newline',
      (tester) async {
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'p', createIfMissing: true);
    await s.upsertContact(Contact(nodeId: _peer));
    final t = _NoTransport();
    addTearDown(t.dispose);
    final m = MessagingService(t, s); // not started: no timers in this test

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

    final field = find.byType(TextField).first;
    await tester.enterText(field, 'line one');
    await tester.pump();

    // Shift+Enter → newline in the field, nothing sent.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    var text = tester.widget<TextField>(field).controller!.text;
    expect(text, contains('\n'),
        reason: 'Shift+Enter must insert a newline, got: '
            '${text.replaceAll('\n', r'\n')}');

    // Plain Enter → the send shortcut fires; the multi-line draft goes out
    // as ONE message and the composer clears.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    text = tester.widget<TextField>(field).controller!.text;
    expect(text, isEmpty,
        reason: 'plain Enter must send and clear the composer');
    final sent = await s.loadMessages(_peer.hex);
    expect(sent, hasLength(1));
    // The trailing newline sat at the end of the draft — send trims it.
    expect(sent.single.body, 'line one');
  });
}
