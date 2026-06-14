import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chats_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

Conversation _conv(int seed, String name, ContactStatus status, {String? last}) =>
    Conversation(
      peer: Contact(nodeId: _id(seed), name: name, status: status),
      lastMessage: last == null
          ? null
          : Message(
              id: 'm',
              conversationId: _id(seed).hex,
              direction: MessageDirection.incoming,
              body: last,
              timestamp: DateTime(2026, 1, 1),
            ),
    );

Widget _host(List<Conversation> convos) => ProviderScope(
      overrides: [
        conversationsProvider.overrideWith((ref) => Stream.value(convos)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: const ChatsScreen(),
      ),
    );

void main() {
  testWidgets('renders conversations and the incoming-request indicator',
      (tester) async {
    await tester.pumpWidget(_host([
      _conv(1, 'Alice', ContactStatus.accepted, last: 'hey'),
      _conv(2, 'Bob', ContactStatus.pendingIncoming),
    ]));
    await tester.pump();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('hey'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    // Pending incoming contact is flagged.
    expect(find.textContaining('wants to connect'), findsOneWidget);
    expect(find.byIcon(Icons.fiber_new), findsOneWidget);
  });

  testWidgets('empty state prompts to start a chat', (tester) async {
    await tester.pumpWidget(_host(const []));
    await tester.pump();
    final l = AppL10n.of(tester.element(find.byType(ChatsScreen)));
    expect(find.text(l.chatsEmpty), findsOneWidget);
  });

  testWidgets('FAB opens the add-contact (invite) sheet', (tester) async {
    await tester.pumpWidget(_host(const []));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();
    expect(find.text('Add a contact'), findsOneWidget);
    expect(find.text('Paste their invite'), findsOneWidget);
  });
}
