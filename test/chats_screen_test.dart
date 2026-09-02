import 'dart:io';
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
import 'package:xveil/domain/space_moderation.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/vnote_message.dart';
import 'package:xveil/state/voice_message.dart';

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
  SpaceModerationAppeal signModerationAppeal(SpaceModerationAppeal value) =>
      value.withSignature(Uint8List(64), value.appellant.bytes);
  @override
  SpaceModerationAppealDecision signModerationAppealDecision(
    SpaceModerationAppealDecision value,
  ) => value.withSignature(Uint8List(64), value.reviewer.bytes);

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
  bool verifyModerationAppeal(SpaceModerationAppeal value) => true;
  @override
  bool verifyModerationAppealDecision(SpaceModerationAppealDecision value) =>
      true;

  @override
  bool verifySpaceManifest(SpaceManifest value) => value.signature.length == 64;

  @override
  ({Uint8List signature, Uint8List publicKey}) signDetached(
    Uint8List message,
  ) => (signature: Uint8List(64), publicKey: selfPubKey);

  @override
  bool verifyDetached({
    required NodeId signer,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) =>
      signer == NodeId(Uint8List.fromList(publicKey)) &&
      publicKey.length == 32 &&
      signature.length == 64;

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
  int unread = 0,
  NotificationMuteMode notificationMode = NotificationMuteMode.none,
  DateTime? mutedUntil,
}) => Conversation(
  unread: unread,
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
  // A conversation's actions — rename, pin, mute, archive, block, delete —
  // are behind a long press and a right-click, with nothing on screen saying
  // so. For a screen-reader user the row announced itself as a plain tap
  // target, so those actions did not exist at all. `onLongPressHint` is the
  // string VoiceOver and TalkBack read out for that gesture; the one written
  // for it sat in both ARBs, attached to nothing.
  testWidgets('the row tells a screen reader what a long press does', (
    tester,
  ) async {
    // Disposed inside the body, not in a tearDown: Flutter checks for live
    // handles BEFORE tearDowns run, so the check fails even when the test
    // itself passed.
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _host([_conv(1, 'Alice', ContactStatus.accepted, last: 'hey')]),
    );
    await tester.pump();
    final l = AppL10n.of(tester.element(find.text('Alice')));

    expect(
      tester.getSemantics(find.text('Alice')),
      isSemantics(onLongPressHint: l.chatMoreActions),
      reason:
          'the long press is the only way to those actions and nothing '
          'announces it',
    );
    semantics.dispose();
  });

  testWidgets('the main screen names its icon-only controls and its counters', (
    tester,
  ) async {
    // Three things on the app's primary screen announced nothing usable. The
    // add-contact button is the largest control on it and carried no tooltip
    // at all — which is where an icon button's accessibility label comes from,
    // so it read as an unlabelled button. The peer badge on the shield and the
    // unread badge on a row each announced a bare digit: sighted readers get
    // the meaning from POSITION, and a screen reader has no position, so "2"
    // arrived with nothing saying two of what.
    //
    // Asserted on the SEMANTICS, not on the widgets: a Tooltip that exists and
    // a label that reaches the accessibility tree are different claims, and it
    // is the second one a screen-reader user depends on.
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host([_conv(1, 'Alice', ContactStatus.accepted, last: 'hey', unread: 3)]),
    );
    await tester.pump();
    final l = AppL10n.of(tester.element(find.text('Alice')));

    expect(
      find.bySemanticsLabel(l.inviteAddContact),
      findsWidgets,
      reason: 'the biggest button on the main screen had no name',
    );
    expect(
      find.bySemanticsLabel(l.networkPeers(4)),
      findsOneWidget,
      reason: 'a bare "4" says nothing about what four there are',
    );
    // A RegExp, not the whole string: the row is one tappable target, so its
    // title, its preview and this counter are merged into a single announced
    // label. What matters is that the counter arrives inside it saying what it
    // counts, rather than as a lone digit at the end.
    expect(
      find.bySemanticsLabel(RegExp(RegExp.escape(l.trayUnread('3')))),
      findsOneWidget,
      reason: 'a bare "3" beside a name is not an unread count to a listener',
    );
    semantics.dispose();
  });

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

  testWidgets('attachment previews show kind labels, never uuid names', (
    tester,
  ) async {
    const uuid = '3f2b8a54-9c1d-4e7f-8a2b-6d5c4e3f2a1b';
    Conversation fileConv(int seed, String name, Message message) =>
        Conversation(
          peer: Contact(nodeId: _id(seed), name: name),
          lastMessage: message,
        );
    Message fileMsg(int seed, String fileName, {String? thumb}) => Message(
      id: 'f$seed',
      conversationId: _id(seed).hex,
      direction: MessageDirection.incoming,
      body: '📎 $fileName',
      timestamp: DateTime(2026, 1, 1),
      fileId: 'cid$seed',
      fileName: fileName,
      thumb: thumb,
    );
    await tester.pumpWidget(
      _host([
        fileConv(
          1,
          'Alice',
          fileMsg(
            1,
            '$uuid.opus',
            thumb: encodeVoiceSidecar(7000, List.filled(48, 0.5)),
          ),
        ),
        fileConv(
          2,
          'Bob',
          fileMsg(2, '$uuid.vnote', thumb: encodeVnoteSidecar(5000, null)),
        ),
        fileConv(3, 'Carol', fileMsg(3, 'report.pdf')),
      ]),
    );
    await tester.pump();

    final l = AppL10n.of(tester.element(find.byType(ChatsScreen)));
    // Voice/video notes travel under opaque uuid container names — the list
    // shows the human kind label (with the clip length), never the uuid.
    expect(find.text('🎤 ${l.chatVoiceTooltip} (0:07)'), findsOneWidget);
    expect(find.text('📹 ${l.chatVnoteTooltip} (0:05)'), findsOneWidget);
    // A human-named file keeps its name.
    expect(find.text('📎 report.pdf'), findsOneWidget);
    expect(find.textContaining(uuid), findsNothing);
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
            notificationUntil: DateTime(2099),
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
            notificationUntil: null,
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
                notificationUntil: null,
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

  test('the add-contact sheet does not outlive the identity that opened it',
      () {
    // report21 X21-M2. The invite on screen is one identity's, and every
    // callback waits on something slow — a redeem, a DHT resolve, the user
    // reading a QR code off another phone. In all-online mode the identity can
    // change in any of those windows: every node stays running, so the
    // captured stack keeps working, and what followed went to whoever was
    // active by then. A nickname was written into the other identity's store,
    // and `/chat/<peer>` opened one identity's contact inside the other's
    // view — the two of them linked, on screen, by us.
    //
    // Driving a modal sheet across a real identity switch needs a live
    // container and a master roster; the switch itself is pinned behaviourally
    // in app_controller_test. What is asserted here is that this sheet asks.
    final src = File('lib/features/chat/chats_screen.dart').readAsStringSync();
    final sheet = src.substring(src.indexOf('Future<void> showAddContactSheet'));

    final lease = sheet.indexOf('final lease = app.leaseIdentity();');
    final shown = sheet.indexOf('showModalBottomSheet<void>(');
    expect(lease, greaterThan(-1), reason: 'the sheet takes no identity lease');
    expect(
      lease,
      lessThan(shown),
      reason: 'the lease is taken after the sheet is up, which is after the '
          'switch it exists to notice',
    );

    // Every service the callbacks use is captured before the sheet, not read
    // out of a provider once the user has already moved on.
    for (final read in [
      'final stack = ref.read(realStackProvider);',
      'final storage = ref.read(storageProvider);',
      'final messaging = ref.read(messagingServiceProvider);',
    ]) {
      final at = sheet.indexOf(read);
      expect(at, greaterThan(-1), reason: 'the sheet no longer captures $read');
      expect(
        at,
        lessThan(shown),
        reason: '$read happens after the sheet is up, so it names whoever is '
            'active when the callback runs rather than who opened it',
      );
    }

    // And each of the three callbacks asks before it acts.
    for (final callback in ['onAddContact:', 'onImportPeers:', 'onAddNickname:']) {
      final at = sheet.indexOf(callback);
      expect(at, greaterThan(-1), reason: '$callback is gone');
      final body = sheet.substring(at, sheet.indexOf('},', at));
      expect(
        body.contains('abandonedIfSwitched()'),
        isTrue,
        reason: '$callback acts without checking whether the identity it was '
            'opened under is still the active one',
      );
    }

    // The nickname path waits on the network, so it checks again after.
    final nick = sheet.substring(sheet.indexOf('onAddNickname:'));
    expect(
      nick.indexOf('app.holdsIdentity(lease)'),
      greaterThan(nick.indexOf('resolveNicknameAsync')),
      reason: 'the nickname resolve is the longest wait in this sheet and its '
          'result is written without asking again',
    );
  });
}
