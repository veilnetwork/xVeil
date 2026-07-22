import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chats_screen.dart';
import 'package:xveil/features/spaces/space_list_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

Conversation _conv(
  int seed,
  String name,
  ContactStatus status, {
  String? last,
}) => Conversation(
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

Widget _host(
  List<Conversation> convos, {
  List<GroupListEntry> groups = const [],
  List<GroupListEntry> spaces = const [],
}) => ProviderScope(
  overrides: [
    conversationsProvider.overrideWith((ref) => Stream.value(convos)),
    groupListProvider.overrideWith((ref) => Stream.value(groups)),
    spaceListProvider.overrideWith((ref) => Stream.value(spaces)),
    nodeStatusProvider.overrideWith(
      (ref) => Stream.value(
        const NodeStatus(phase: NodePhase.starting, peerCount: 4),
      ),
    ),
    sessionCountProvider.overrideWith((ref) => Stream.value(4)),
  ],
  child: MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: const ChatsScreen(),
  ),
);

void main() {
  testWidgets('renders conversations and the incoming-request indicator', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _conv(1, 'Alice', ContactStatus.accepted, last: 'hey'),
        _conv(2, 'Bob', ContactStatus.pendingIncoming),
      ]),
    );
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

  testWidgets('group chats remain in Chats beside personal chats', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        [_conv(1, 'Alice', ContactStatus.accepted, last: 'hey')],
        groups: [
          (
            groupId: _id(7),
            name: 'Дача',
            description: '',
            visibility: null,
            discoverable: false,
            unread: 2,
            postUnread: 1,
            muted: false,
            preview: 'шашлыки в субботу',
            // Newer than Alice's 2026-01-01 message → the group sorts on top.
            lastTs: DateTime(2026, 6, 1).millisecondsSinceEpoch,
          ),
        ],
        spaces: [
          (
            groupId: _id(8),
            name: 'Veil Community',
            description: 'Should stay in Communities',
            visibility: null,
            discoverable: false,
            unread: 3,
            postUnread: 2,
            muted: false,
            preview: 'community channel message',
            lastTs: DateTime(2026, 7, 1).millisecondsSinceEpoch,
          ),
        ],
      ),
    );
    // Two provider streams (conversations + groups) each need an emit tick.
    await tester.pump();
    await tester.pump();

    expect(find.text('Дача'), findsOneWidget);
    expect(find.text('шашлыки в субботу'), findsOneWidget);
    expect(find.byIcon(Icons.group_outlined), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Veil Community'), findsNothing);
    expect(find.text('community channel message'), findsNothing);
  });

  testWidgets('communities replace the old empty channels surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          groupServiceProvider.overrideWithValue(null),
          spaceListProvider.overrideWith(
            (ref) => Stream.value([
              (
                groupId: _id(7),
                name: 'Дача',
                description: '',
                visibility: null,
                discoverable: false,
                unread: 2,
                postUnread: 1,
                muted: false,
                preview: 'шашлыки в субботу',
                lastTs: DateTime(2026, 6, 1).millisecondsSinceEpoch,
              ),
            ]),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: const SpaceListScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final l = AppL10n.of(tester.element(find.byType(SpaceListScreen)));
    expect(find.text(l.navCommunities), findsOneWidget);
    expect(find.text('Дача'), findsOneWidget);
    expect(find.text('шашлыки в субботу'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('FAB opens the add-contact (invite) sheet', (tester) async {
    await tester.pumpWidget(_host(const []));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();
    expect(find.text('Add a contact'), findsOneWidget);
    expect(find.text('Paste their invite'), findsOneWidget);
  });

  testWidgets('security shield replaces the debug demo-chat action', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const []));
    await tester.pump();
    final l = AppL10n.of(tester.element(find.byType(ChatsScreen)));

    expect(find.byIcon(Icons.science_outlined), findsNothing);
    expect(find.byIcon(Icons.shield_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.shield_outlined));
    await tester.pumpAndSettle();

    expect(find.text(l.securityCenterTitle), findsOneWidget);
    expect(find.text(l.networkPeers(4)), findsOneWidget);
    final vpnY = tester.getTopLeft(find.text(l.vpnTitle)).dy;
    final socksY = tester.getTopLeft(find.text(l.routeSocks5Title)).dy;
    final onionY = tester.getTopLeft(find.text(l.settingsAnonymousRouting)).dy;
    expect(vpnY, lessThan(socksY));
    expect(socksY, lessThan(onionY));
  });
}
