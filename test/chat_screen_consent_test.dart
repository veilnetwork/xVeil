import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chat_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/messaging.dart';

final _hex = NodeId(Uint8List.fromList(List.filled(32, 2))).hex;

Widget _host(Contact? contact, {List<Message> messages = const []}) =>
    ProviderScope(
      overrides: [
        contactProvider(_hex).overrideWith((ref) => Stream.value(contact)),
        messagesProvider(_hex).overrideWith((ref) => Stream.value(messages)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: ChatScreen(peerHex: _hex),
      ),
    );

Contact _c(ContactStatus s) =>
    Contact(nodeId: NodeId.fromHex(_hex), status: s);

void main() {
  testWidgets('incoming request shows Accept / Block, no composer',
      (tester) async {
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

  testWidgets('accepted shows the normal composer', (tester) async {
    await tester.pumpWidget(_host(_c(ContactStatus.accepted)));
    await tester.pump();
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('no contact yet shows a connection-request composer',
      (tester) async {
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

  Message txt(String body,
          {required MessageDirection dir, bool edited = false}) =>
      Message(
        id: 'm-$body',
        conversationId: _hex,
        direction: dir,
        body: body,
        timestamp: DateTime(2026, 1, 1),
        edited: edited,
      );

  testWidgets('long-press on own message offers edit + both deletes',
      (tester) async {
    await tester.pumpWidget(_host(_c(ContactStatus.accepted),
        messages: [txt('hi', dir: MessageDirection.outgoing)]));
    await tester.pump();
    await tester.longPress(find.text('hi'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete for everyone'), findsOneWidget);
    expect(find.text('Delete for me'), findsOneWidget);
  });

  testWidgets('long-press on a received message offers only "delete for me"',
      (tester) async {
    await tester.pumpWidget(_host(_c(ContactStatus.accepted),
        messages: [txt('hello', dir: MessageDirection.incoming)]));
    await tester.pump();
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete for everyone'), findsNothing);
    expect(find.text('Delete for me'), findsOneWidget);
  });

  testWidgets('an edited message renders the "edited" marker', (tester) async {
    await tester.pumpWidget(_host(_c(ContactStatus.accepted),
        messages: [txt('fixed', dir: MessageDirection.outgoing, edited: true)]));
    await tester.pump();
    expect(find.text('edited'), findsOneWidget);
  });

  testWidgets('a file message renders with its name + a save affordance',
      (tester) async {
    final fileMsg = Message(
      id: 'f1',
      conversationId: _hex,
      direction: MessageDirection.incoming,
      body: '📎 photo.png',
      timestamp: DateTime(2026, 1, 1),
      fileId: 'fid',
      fileName: 'photo.png',
    );
    await tester
        .pumpWidget(_host(_c(ContactStatus.accepted), messages: [fileMsg]));
    await tester.pump();
    expect(find.text('photo.png'), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
  });
}
