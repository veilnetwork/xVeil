// A chat belongs to one identity's conversation with one contact.
//
// `AppController._activateOnline` re-points the storage and the messaging
// pipeline without changing `AppPhase`, so the router keeps `/chat/:peerHex`
// and this screen's State alive across a switch. Everything in it used to
// resolve the providers at the moment it needed them: a draft typed as A was
// sent by B, a file or sticker read from A's store was written into B's, and
// the forward sheet held real messages of A's to send as B (report17
// XV17-H6).
import 'dart:io';
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
import 'package:xveil/state/messaging_providers.dart';
import 'package:xveil/state/providers.dart';

final _hex = NodeId(Uint8List.fromList(List.filled(32, 2))).hex;

Message _msg(String text) => Message(
  id: 'm1',
  conversationId: _hex,
  direction: MessageDirection.incoming,
  body: text,
  status: MessageStatus.delivered,
  timestamp: DateTime.utc(2026, 8, 27),
);

Future<HiddenVolumeStorage> _opened(String password) async {
  final backing = FakeKvLogStore();
  final storage = HiddenVolumeStorage(
    ({required Uint8List password, required bool create}) => backing,
  );
  await storage.open(password: password, createIfMissing: true);
  return storage;
}

void main() {
  testWidgets('a switch takes the screen off A\'s conversation', (
    tester,
  ) async {
    final a = await _opened('a');
    final b = await _opened('b');
    var active = a;

    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => active),
        contactProvider(_hex).overrideWith(
          (ref) => Stream.value(
            Contact(
              nodeId: NodeId.fromHex(_hex),
              status: ContactStatus.accepted,
            ),
          ),
        ),
        messagesProvider(
          _hex,
        ).overrideWith((ref) => Stream.value([_msg('written to A')])),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: ChatScreen(peerHex: _hex),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text('written to A'),
      findsOneWidget,
      reason: "premise: A's message is on screen",
    );
    await tester.enterText(find.byType(TextField).first, 'draft as A');
    await tester.pump();
    expect(find.text('draft as A'), findsOneWidget);

    active = b;
    container.invalidate(storageProvider);
    await tester.pump();

    expect(
      find.text('written to A'),
      findsNothing,
      reason: "A's conversation stayed on screen under B",
    );
    expect(
      find.text('draft as A'),
      findsNothing,
      reason: 'the draft typed as A was left in the composer for B to send',
    );
    // Nothing of A's is still ticking either: the screen goes, and with it
    // the messaging pipeline the container was holding open.
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  test('nothing in the screen resolves the identity after it opened', () {
    // The behaviour above is one frame. This is the property that makes every
    // path in a 2500-line screen safe: the storage and the messaging pipeline
    // are taken ONCE, in initState, and every send, file read and forward uses
    // what it took. A new `ref.read(storageProvider)` added later would resolve
    // to whichever identity is active by then — which is the defect.
    final source = File(
      'lib/features/chat/chat_screen.dart',
    ).readAsStringSync();
    final start = source.indexOf('class _ChatScreenState');
    expect(start, isNot(-1), reason: 'the screen was renamed');
    // Bounded at the class's closing brace at column 0, not a fixed window.
    final end = source.indexOf('\n}\n', start);
    expect(end, isNot(-1));
    final body = source.substring(start, end);

    expect(
      body,
      contains('_storage = ref.read(storageProvider)'),
      reason: 'the capture itself is gone',
    );
    expect(
      body,
      contains('_messaging = ref.read(messagingServiceProvider)'),
      reason: 'the capture itself is gone',
    );
    // Exactly the two captures above, and nothing else.
    for (final dynamicRead in const {
      'ref.read(storageProvider)': 1,
      'ref.read(messagingServiceProvider)': 1,
      'ref.watch(messagingServiceProvider)': 0,
      'ref.watch(storageProvider)': 1, // the switch check in `build`
    }.entries) {
      expect(
        body.split(dynamicRead.key).length - 1,
        dynamicRead.value,
        reason: '${dynamicRead.key} resolves whoever is active at the time',
      );
    }
  });

  test('and the group chat holds the same property', () {
    // The same screen for a group conversation, and the same cost: a message
    // meant for A's group, sent by B. Fixing one and not the other is how
    // this class of defect survives a fix.
    final source = File(
      'lib/features/groups/group_chat_screen.dart',
    ).readAsStringSync();
    final start = source.indexOf('class _GroupChatScreenState');
    expect(start, isNot(-1), reason: 'the screen was renamed');
    final end = source.indexOf('\n}\n', start);
    expect(end, isNot(-1));
    final body = source.substring(start, end);

    expect(body, contains('_storage = ref.read(storageProvider)'));
    expect(body, contains('_messaging = ref.read(messagingServiceProvider)'));
    expect(
      body,
      contains('if (!identical(ref.watch(storageProvider), _storage))'),
      reason: "the screen repaints A's group under B",
    );
    for (final dynamicRead in const {
      'ref.read(storageProvider)': 1,
      'ref.read(messagingServiceProvider)': 1,
      'ref.watch(messagingServiceProvider)': 0,
      'ref.watch(storageProvider)': 1,
    }.entries) {
      expect(
        body.split(dynamicRead.key).length - 1,
        dynamicRead.value,
        reason: '${dynamicRead.key} resolves whoever is active at the time',
      );
    }
  });
}
