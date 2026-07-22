import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_lifecycle.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/features/chat/chats_screen.dart';
import 'package:xveil/features/spaces/space_list_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

class _Signer implements GroupSigner {
  const _Signer(this.selfId);

  @override
  final NodeId selfId;

  @override
  Uint8List get selfPubKey => selfId.bytes;

  @override
  SpaceManifest signSpaceManifest(SpaceManifest value) =>
      value.withSignature(Uint8List(64));

  @override
  ControlEntry signControl(ControlEntry value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  GroupMessage signMessage(GroupMessage value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  GroupReaction signReaction(GroupReaction value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  SpacePost signPost(SpacePost value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  GroupContentRequest signContentRequest(GroupContentRequest value) =>
      value.withSignature(Uint8List(64), value.requester.bytes);

  @override
  GroupCallSignal signCallSignal(GroupCallSignal value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  bool verifyControl(ControlEntry value) => true;

  @override
  bool verifyMessage(GroupMessage value) => true;

  @override
  bool verifyReaction(GroupReaction value) => true;

  @override
  bool verifyPost(SpacePost value) => true;

  @override
  bool verifyContentRequest(GroupContentRequest value) => true;

  @override
  bool verifyCallSignal(GroupCallSignal value) => true;

  @override
  bool verifySpaceManifest(SpaceManifest value) => value.signature.length == 64;

  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => true;
}

Conversation _conv(
  int seed,
  String name,
  ContactStatus status, {
  String? last,
  NotificationMuteMode notificationMode = NotificationMuteMode.none,
  DateTime? mutedUntil,
}) => Conversation(
  peer: Contact(
    nodeId: _id(seed),
    name: name,
    status: status,
    notificationMuteMode: notificationMode,
    mutedUntil: mutedUntil,
  ),
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

  testWidgets('mentions-only has a distinct chat-list indicator', (
    tester,
  ) async {
    final conversation = _conv(
      1,
      'Alice',
      ContactStatus.accepted,
      last: 'hey',
      notificationMode: NotificationMuteMode.mentionsOnly,
      mutedUntil: DateTime(2099),
    );
    await tester.pumpWidget(_host([conversation]));
    await tester.pump();

    expect(
      find.byKey(ValueKey('chat-notification-mentionsOnly-${conversation.id}')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Mentions only',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.notifications_off_outlined), findsNothing);
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
            lifecycleState: SpaceLifecycleState.active,
            discoverable: false,
            unread: 2,
            postUnread: 1,
            muted: true,
            notificationMode: NotificationMuteMode.mentionsOnly,
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
            lifecycleState: SpaceLifecycleState.active,
            discoverable: false,
            unread: 3,
            postUnread: 2,
            muted: false,
            notificationMode: NotificationMuteMode.all,
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
    expect(
      find.byKey(ValueKey('group-notification-mentionsOnly-${_id(7).hex}')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Mentions only',
      ),
      findsOneWidget,
    );
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Veil Community'), findsNothing);
    expect(find.text('community channel message'), findsNothing);
  });

  testWidgets('drawer creates a group through the mounted Chats owner', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(_id(9)));
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const ChatsScreen()),
        GoRoute(
          path: '/group/:id',
          builder: (_, state) => Text('opened:${state.pathParameters['id']}'),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          groupServiceProvider.overrideWithValue(service),
          conversationsProvider.overrideWith((ref) => Stream.value(const [])),
          nodeStatusProvider.overrideWith(
            (ref) => Stream.value(
              const NodeStatus(phase: NodePhase.starting, peerCount: 0),
            ),
          ),
          sessionCountProvider.overrideWith((ref) => Stream.value(0)),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final l = AppL10n.of(tester.element(find.byType(ChatsScreen)));

    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(l.groupCreateTitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'test');
    await tester.tap(find.text(l.groupCreateAction));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('opened:').evaluate().isNotEmpty) break;
    }

    final groups = await service.listGroups();
    expect(groups, hasLength(1));
    expect(groups.single.name, 'test');
    expect(find.text('opened:${groups.single.groupId.hex}'), findsOneWidget);
    router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('test'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    router.dispose();
    await service.dispose();
    await storage.close();
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
                lifecycleState: SpaceLifecycleState.active,
                discoverable: false,
                unread: 2,
                postUnread: 1,
                muted: false,
                notificationMode: NotificationMuteMode.all,
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
