import 'dart:async';
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

/// The read-after window is measured from the moment this device first SHOWED
/// a message, and the only thing that records a showing is `markRead`. It ran
/// once, from `initState`, so a message arriving while the chat was ON SCREEN
/// was displayed and never recorded — its window did not start until the user
/// left the conversation and came back.
///
/// That is the ordinary way the feature is used: reading a conversation as it
/// happens. "Hide 30 minutes after reading" did not apply to the messages
/// actually being read.
final _hex = NodeId(Uint8List.fromList(List.filled(32, 2))).hex;

class _MarkCountingStorage extends HiddenVolumeStorage {
  _MarkCountingStorage(FakeKvLogStore backing)
    : super(({required password, required bool create}) => backing);

  int marks = 0;

  @override
  Future<void> markRead(String conversationId) {
    marks++;
    return super.markRead(conversationId);
  }
}

Message _msg(String id, DateTime at) => Message(
  id: id,
  conversationId: _hex,
  direction: MessageDirection.incoming,
  body: id,
  status: MessageStatus.delivered,
  timestamp: at,
);

void main() {
  setUp(() => VeilMediaNative.debugForceAvailable = true);
  tearDown(() {
    VeilMediaNative.debugForceAvailable = null;
    VeilMediaNative.forgetProbe();
  });

  testWidgets(
    'a message arriving while the chat is open is recorded as shown',
    (tester) async {
      final backing = FakeKvLogStore();
      final storage = _MarkCountingStorage(backing);
      await storage.open(password: 'pw', createIfMissing: true);

      final base = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final controller = StreamController<List<Message>>();
      addTearDown(controller.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            contactProvider(_hex).overrideWith(
              (ref) => Stream.value(
                Contact(
                  nodeId: NodeId.fromHex(_hex),
                  status: ContactStatus.accepted,
                ),
              ),
            ),
            messagesProvider(_hex).overrideWith((ref) => controller.stream),
            singleSpaceStorageProvider.overrideWithValue(storage),
          ],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: ChatScreen(peerHex: _hex),
          ),
        ),
      );

      controller.add([_msg('first', base)]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final afterOpen = storage.marks;

      // A new message lands while the screen stays on it. Nothing about the
      // conversation was re-entered.
      controller.add([
        _msg('first', base),
        _msg('second', base.add(const Duration(minutes: 1))),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        storage.marks,
        greaterThan(afterOpen),
        reason:
            'a message shown while the chat is open must be recorded as shown, '
            'or its read-after window never starts',
      );
    },
  );

  testWidgets('a provider tick that adds nothing records nothing', (
    tester,
  ) async {
    final backing = FakeKvLogStore();
    final storage = _MarkCountingStorage(backing);
    await storage.open(password: 'pw', createIfMissing: true);

    final base = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final controller = StreamController<List<Message>>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contactProvider(_hex).overrideWith(
            (ref) => Stream.value(
              Contact(
                nodeId: NodeId.fromHex(_hex),
                status: ContactStatus.accepted,
              ),
            ),
          ),
          messagesProvider(_hex).overrideWith((ref) => controller.stream),
          singleSpaceStorageProvider.overrideWithValue(storage),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: ChatScreen(peerHex: _hex),
        ),
      ),
    );

    controller.add([_msg('first', base)]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final settled = storage.marks;

    // The same list again, twice: `markRead` moves a durable marker and
    // notifies the device mirror, so re-reporting an unchanged conversation
    // would be a write and a mirror frame for nothing — and, since `markRead`
    // itself makes the provider re-yield, a loop.
    controller.add([_msg('first', base)]);
    await tester.pump();
    controller.add([_msg('first', base)]);
    await tester.pump(const Duration(milliseconds: 50));

    expect(storage.marks, settled, reason: 'no advance, no write');
  });
}
