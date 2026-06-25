import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chat_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/messaging.dart';

final _hex = NodeId(Uint8List.fromList(List.filled(32, 2))).hex;

Widget _host(List<Message> messages) => ProviderScope(
      overrides: [
        contactProvider(_hex).overrideWith(
          (ref) => Stream.value(
            Contact(nodeId: NodeId.fromHex(_hex), status: ContactStatus.accepted),
          ),
        ),
        messagesProvider(_hex).overrideWith((ref) => Stream.value(messages)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: ChatScreen(peerHex: _hex),
      ),
    );

Message _msg(String body, MessageDirection dir) => Message(
      id: 'm-$body',
      conversationId: _hex,
      direction: dir,
      body: body,
      timestamp: DateTime(2024, 1, 1, 12, 0),
    );

void main() {
  testWidgets('right-click (secondary tap) opens the message actions sheet',
      (tester) async {
    await tester.pumpWidget(_host([_msg('hello world', MessageDirection.incoming)]));
    await tester.pump();

    // No menu until invoked.
    expect(find.text('Copy text'), findsNothing);

    // Desktop right-click — the only way to reach the menu without a long-press.
    await tester.tap(find.text('hello world'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Copy text'), findsOneWidget);
    // An incoming message can't be edited / deleted-for-everyone, but can be
    // copied and deleted-for-me.
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete for everyone'), findsNothing);
    expect(find.text('Delete for me'), findsOneWidget);
  });

  testWidgets('long-press still opens the sheet; outgoing message can be edited',
      (tester) async {
    await tester.pumpWidget(_host([_msg('mine', MessageDirection.outgoing)]));
    await tester.pump();

    await tester.longPress(find.text('mine'));
    await tester.pumpAndSettle();

    expect(find.text('Copy text'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete for everyone'), findsOneWidget);
  });

  testWidgets('Copy puts the body on the clipboard and confirms', (tester) async {
    // Capture what the app writes to the platform clipboard.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(_host([_msg('copy me', MessageDirection.incoming)]));
    await tester.pump();

    await tester.tap(find.text('copy me'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy text'));
    await tester.pump(); // run the async copy + show the snackbar

    expect(copied, 'copy me');
    expect(find.text('Copied'), findsOneWidget);
  });
}
