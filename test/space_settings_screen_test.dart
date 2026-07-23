import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_moderation.dart';
import 'package:xveil/domain/space_join_request.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/domain/space_channel.dart';
import 'package:xveil/domain/space_retention.dart';
import 'package:xveil/features/chat/chat_actions.dart';
import 'package:xveil/features/spaces/space_list_screen.dart';
import 'package:xveil/features/spaces/space_moderation_screen.dart';
import 'package:xveil/features/spaces/space_rules_screen.dart';
import 'package:xveil/features/spaces/space_screen.dart';
import 'package:xveil/features/spaces/space_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/group_epoch_service.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int value) =>
    NodeId(Uint8List.fromList(List<int>.filled(32, value)));

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
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => true;
}

class _DelayedSettingsStorage extends HiddenVolumeStorage {
  _DelayedSettingsStorage()
    : super(({required password, required create}) => FakeKvLogStore());

  bool delayReads = false;

  @override
  Future<String?> getSetting(String key) async {
    if (delayReads) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    return super.getSetting(key);
  }
}

void main() {
  testWidgets('Space settings retain an asynchronous snapshot', (tester) async {
    final storage = _DelayedSettingsStorage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(_id(10)));
    addTearDown(service.dispose);
    final spaceId = await service.createSpace('Async community');
    storage.delayReads = true;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: SpaceSettingsScreen(spaceIdHex: spaceId.hex),
        ),
      ),
    );

    final l = AppL10n.of(tester.element(find.byType(SpaceSettingsScreen)));
    expect(find.text(l.spaceSettingsTitle), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    service.changes.value++;
    await tester.pumpAndSettle();

    expect(find.text('Async community'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('Space creation captures description and honest visibility', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(_id(11)));
    addTearDown(service.dispose);
    final router = GoRouter(
      initialLocation: '/spaces',
      routes: [
        GoRoute(path: '/spaces', builder: (_, _) => const SpaceListScreen()),
        GoRoute(
          path: '/space/:id',
          builder: (_, state) =>
              Scaffold(body: Text(state.pathParameters['id']!)),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupServiceProvider.overrideWithValue(service)],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpaceListScreen)));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-create-name')),
      'Field lab',
    );
    await tester.enterText(
      find.byKey(const ValueKey('space-create-description')),
      'Offline protocol builders',
    );
    await tester.tap(find.byKey(const ValueKey('space-create-visibility')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spaceVisibilitySecret).last);
    await tester.pumpAndSettle();
    expect(find.text(l.spaceVisibilitySecretHint), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, l.spaceCreateAction),
      ),
    );
    await tester.pumpAndSettle();

    final created = (await service.listSpaces()).single;
    expect(created.name, 'Field lab');
    expect(created.description, 'Offline protocol builders');
    expect(created.visibility, SpaceVisibility.secret);
    expect(created.discoverable, isFalse);
  });

  testWidgets(
    'Communities renders signed suspended and left membership states',
    (tester) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(storage, _Signer(_id(112)));
      final memberService = GroupService(storage, _Signer(_id(113)));
      addTearDown(ownerService.dispose);
      addTearDown(memberService.dispose);
      final spaceId = await ownerService.createSpace(
        'Membership UI',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: memberService.selfId,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final actionId = await ownerService.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.timeout,
        target: memberService.selfId,
        scope: SpaceModerationScope.space,
        reason: 'Take a break',
        expiresAtMs:
            DateTime.now().millisecondsSinceEpoch +
            const Duration(hours: 1).inMilliseconds,
      );
      expect(actionId, isNotNull);

      final router = GoRouter(
        initialLocation: '/spaces',
        routes: [
          GoRoute(path: '/spaces', builder: (_, _) => const SpaceListScreen()),
          GoRoute(
            path: '/space/:id',
            builder: (_, state) =>
                Scaffold(body: Text(state.pathParameters['id']!)),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [groupServiceProvider.overrideWithValue(memberService)],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(SpaceListScreen)));
      expect(find.text('Membership UI'), findsWidgets);
      expect(find.textContaining(l.spaceMembershipSuspended), findsWidgets);
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);

      expect(
        await ownerService.revokeSpaceModeration(
          spaceId,
          actionId!,
          reason: 'Restored',
        ),
        isTrue,
      );
      memberService.changes.value++;
      await tester.pumpAndSettle();
      expect(find.textContaining(l.spaceMembershipSuspended), findsNothing);

      expect(await memberService.leaveGroup(spaceId), isTrue);
      expect(await memberService.listSpaces(), isEmpty);
      expect(
        (await memberService.spaceMemberships())
            .singleWhere((entry) => entry.spaceId == spaceId)
            .status
            .name,
        'left',
      );
      expect(await memberService.appealableSpaceModerationActions(), isEmpty);
      expect(await memberService.outgoingSpaceModerationAppeals(), isEmpty);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.text(l.spaceMembershipStatusTitle), findsOneWidget);
      expect(find.text(l.spaceMembershipLeft), findsOneWidget);
      expect(
        find.byKey(ValueKey('space-membership-rejoin-${spaceId.hex}')),
        findsOneWidget,
      );
    },
  );

  testWidgets('Space list exposes and edits the exact notification policy', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(_id(12)));
    addTearDown(service.dispose);
    final spaceId = await service.createSpace('Quick policy');
    final until = DateTime(2099, 1, 2, 3, 4);
    await service.setGroupNotificationPolicy(
      spaceId,
      NotificationMuteMode.mentionsOnly,
      until,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: const SpaceListScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(SpaceListScreen));
    final l = AppL10n.of(context);

    expect(find.byKey(const ValueKey('space-mentions-open')), findsOneWidget);
    expect(
      find.byKey(ValueKey('space-notification-mentionsOnly-${spaceId.hex}')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(l.notificationMuteMentionsOnly)),
      findsOneWidget,
    );

    await tester.longPress(find.text('Quick policy'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        notificationMutePolicyLabel(
          context,
          NotificationMutePolicy(
            mode: NotificationMuteMode.mentionsOnly,
            until: until,
          ),
        ),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('notification-policy-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notification-mute-none')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.mute30m).last);
    await tester.pumpAndSettle();

    var policy = await service.groupNotificationPolicy(spaceId);
    expect(policy.effectiveAt(DateTime.now()), NotificationMuteMode.none);
    expect(
      find.byKey(ValueKey('space-notification-none-${spaceId.hex}')),
      findsOneWidget,
    );

    await tester.longPress(find.text('Quick policy'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notification-policy-unmute')));
    await tester.pumpAndSettle();

    policy = await service.groupNotificationPolicy(spaceId);
    expect(policy.effectiveAt(DateTime.now()), NotificationMuteMode.all);
    expect(
      find.byKey(ValueKey('space-notification-none-${spaceId.hex}')),
      findsNothing,
    );
  });

  testWidgets('Space list sends a join request from a strict link', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final requester = _id(61);
    final approver = _id(62);
    final sent = <String>[];
    final service = GroupService(
      storage,
      _Signer(requester),
      sendSpaceJoinRequest: (peer, requestId, json) async {
        expect(peer, approver);
        sent.add(json);
      },
    );
    addTearDown(service.dispose);
    final now = DateTime.now().millisecondsSinceEpoch;
    final link = SpaceJoinCode.encode(
      SpaceJoinTicket(
        ticketId: 'a1' * 32,
        spaceId: _id(63),
        approver: approver,
        spaceName: 'Linked community',
        createdAtMs: now,
        expiresAtMs: now + kSpaceJoinTicketLifetime.inMilliseconds,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: const SpaceListScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpaceListScreen)));
    await tester.tap(find.byKey(const ValueKey('space-join-link-action')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('space-join-code')), link);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('space-join-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(sent, hasLength(1));
    expect(find.text(l.spaceJoinRequestSent), findsOneWidget);
    expect(await service.outgoingSpaceJoinRequests(), hasLength(1));
  });

  testWidgets(
    'banned member can appeal from Communities after Space is hidden',
    (tester) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(64);
      final member = _id(65);
      final ownerService = GroupService(storage, _Signer(owner));
      final sent = <String>[];
      final memberService = GroupService(
        storage,
        _Signer(member),
        sendSpaceModerationAppeal: (peer, appealId, appealJson) async {
          expect(peer, owner);
          expect(appealId, hasLength(64));
          sent.add(appealJson);
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(memberService.dispose);
      final spaceId = await ownerService.createSpace('Hidden after ban');
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: member,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final actionId = await ownerService.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.permanentBan,
        target: member,
        scope: SpaceModerationScope.space,
        reason: 'reviewable incident',
      );
      expect(actionId, isNotNull);
      expect(await memberService.listSpaces(), isEmpty);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [groupServiceProvider.overrideWithValue(memberService)],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: const SpaceListScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final appealButton = find.byKey(
        ValueKey('space-moderation-appeal-$actionId'),
      );
      expect(find.text('Hidden after ban'), findsOneWidget);
      expect(appealButton, findsOneWidget);
      await tester.tap(appealButton);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('space-moderation-appeal-text')),
        'Please review the complete context.',
      );
      await tester.tap(
        find.byKey(const ValueKey('space-moderation-appeal-submit')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(sent, hasLength(1));
      final outgoing =
          (await memberService.outgoingSpaceModerationAppeals()).single;
      expect(outgoing.appeal.actionId, actionId);
      expect(
        find.byKey(
          ValueKey(
            'space-moderation-appeal-outgoing-${outgoing.appeal.appealId}',
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('Space channels support categories, history and restore', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(_id(71)));
    addTearDown(service.dispose);
    final spaceId = await service.createSpace('Channel lab');
    final categoryId = await service.createChannel(
      spaceId,
      name: 'Projects',
      kind: SpaceChannelKind.category,
      position: 100,
    );
    expect(categoryId, isNotNull);

    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: SpaceScreen(spaceIdHex: spaceId.hex),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpaceScreen)));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-channel-name')),
      'Design',
    );
    await tester.enterText(
      find.byKey(const ValueKey('space-channel-description')),
      'Shared decisions',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('space-channel-category')),
    );
    await tester.tap(find.byKey(const ValueKey('space-channel-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projects').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('space-channel-history')),
    );
    await tester.tap(find.byKey(const ValueKey('space-channel-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spaceChannelHistoryFull).last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('space-channel-save')),
    );
    await tester.tap(find.byKey(const ValueKey('space-channel-save')));
    await tester.pumpAndSettle();

    final created = (await service.channelsOf(
      spaceId,
    )).singleWhere((channel) => channel.name == 'Design');
    expect(created.description, 'Shared decisions');
    expect(created.categoryId, categoryId);
    expect(created.history, SpaceChannelHistory.full);
    expect(find.text('Design'), findsOneWidget);

    final manage = find.byKey(
      ValueKey('space-channel-manage-${created.channelId.hex}'),
    );
    await tester.tap(manage);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spaceChannelArchive).last);
    await tester.pumpAndSettle();
    expect(
      (await service.channelsOf(spaceId, includeArchived: true))
          .singleWhere((channel) => channel.channelId == created.channelId)
          .archived,
      isTrue,
    );
    expect(find.textContaining(l.spaceChannelArchived), findsOneWidget);

    await tester.tap(manage);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spaceChannelRestore).last);
    await tester.pumpAndSettle();
    expect(
      (await service.channelsOf(spaceId, includeArchived: true))
          .singleWhere((channel) => channel.channelId == created.channelId)
          .archived,
      isFalse,
    );
  });

  testWidgets(
    'restricted text channel exposes encrypted retention with fixed presets',
    (tester) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(75);
      final service = GroupService(
        storage,
        _Signer(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      addTearDown(service.dispose);
      final spaceId = await service.createSpace('Retention UI');
      final channelId = await service.createChannel(
        spaceId,
        name: 'Private history',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
      );
      expect(channelId, isNotNull);

      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [groupServiceProvider.overrideWithValue(service)],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: SpaceScreen(spaceIdHex: spaceId.hex),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(SpaceScreen)));
      await tester.tap(
        find.byKey(ValueKey('space-channel-manage-${channelId!.hex}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('space-channel-retention-action')),
      );
      await tester.pumpAndSettle();

      expect(find.text(l.spaceRetentionGlobal), findsOneWidget);
      expect(find.text(l.retentionUnlimited), findsOneWidget);
      expect(find.text(l.retention7), findsOneWidget);
      expect(find.text(l.retention30), findsOneWidget);
      expect(find.text(l.retention90), findsOneWidget);
      expect(find.text(l.retention365), findsOneWidget);
      await tester.tap(find.text(l.retention7));
      await tester.pumpAndSettle();
      expect(find.text(l.spaceRetentionMediaOnly), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('space-channel-retention-media-only')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('space-channel-retention-save')),
      );
      await tester.pumpAndSettle();

      final policy = await service.spaceRetentionPolicyOf(
        spaceId,
        channelId: channelId,
      );
      expect(policy?.mode, SpaceRetentionMode.deleteAfter);
      expect(policy?.retentionMs, const Duration(days: 7).inMilliseconds);
      expect(policy?.mediaOnly, isTrue);
      final row = (await service.load(spaceId))!.control.last;
      expect(row.version, 15);
      expect(row.retentionPolicy, isNull);
      expect(row.channelRetention?.channelId, channelId);
    },
  );

  testWidgets('category steward creates only inside the granted category', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(76);
    final member = _id(77);
    final ownerService = GroupService(storage, _Signer(owner));
    final memberService = GroupService(storage, _Signer(member));
    addTearDown(ownerService.dispose);
    addTearDown(memberService.dispose);
    final spaceId = await ownerService.createSpace('Scoped channel UI');
    final categoryId = await ownerService.createChannel(
      spaceId,
      name: 'Operations',
      kind: SpaceChannelKind.category,
    );
    expect(categoryId, isNotNull);
    expect(
      await ownerService.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: member,
        role: GroupRole.member,
      ),
      isTrue,
    );
    final roleId = ownerService.newSpaceAccessObjectId();
    expect(
      await ownerService.replaceSpaceAccessPolicy(
        spaceId,
        expectedRevision: 0,
        roles: [
          SpaceRoleDefinition(
            roleId: roleId,
            name: 'Operations steward',
            grants: [
              SpacePermissionGrant(
                permission: SpacePermission.manageChannels,
                scope: SpacePermissionScope(
                  kind: SpacePermissionScopeKind.category,
                  targetId: categoryId,
                ),
              ),
            ],
          ),
        ],
        groups: const <SpaceMemberGroup>[],
        directAssignments: [
          SpaceMemberRoleAssignment(member: member, roleIds: [roleId]),
        ],
      ),
      isNotNull,
    );

    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupServiceProvider.overrideWithValue(memberService)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: SpaceScreen(spaceIdHex: spaceId.hex),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    final kind = tester.widget<DropdownButton<SpaceChannelKind>>(
      find.descendant(
        of: find.byKey(const ValueKey('space-channel-kind')),
        matching: find.byType(DropdownButton<SpaceChannelKind>),
      ),
    );
    expect(
      kind.items!.map((item) => item.value),
      isNot(contains(SpaceChannelKind.category)),
    );
    final access = tester.widget<DropdownButton<SpaceChannelAccess>>(
      find.descendant(
        of: find.byKey(const ValueKey('space-channel-access')),
        matching: find.byType(DropdownButton<SpaceChannelAccess>),
      ),
    );
    expect(access.items!.map((item) => item.value), [SpaceChannelAccess.space]);
    final category = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('space-channel-category')),
    );
    expect(category.initialValue, categoryId!.hex);
    final categoryButton = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('space-channel-category')),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    expect(categoryButton.items!.map((item) => item.value), [categoryId.hex]);

    await tester.enterText(
      find.byKey(const ValueKey('space-channel-name')),
      'Runbooks',
    );
    await tester.tap(find.byKey(const ValueKey('space-channel-save')));
    await tester.pumpAndSettle();

    final created = (await ownerService.channelsOf(
      spaceId,
    )).singleWhere((channel) => channel.name == 'Runbooks');
    expect(created.categoryId, categoryId);
  });

  testWidgets(
    'restricted voice channel keeps its kind and manages recipients',
    (tester) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(81);
      final bob = _id(82);
      final service = GroupService(
        storage,
        _Signer(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      addTearDown(service.dispose);
      final spaceId = await service.createSpace('Private stage');
      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [groupServiceProvider.overrideWithValue(service)],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: SpaceScreen(spaceIdHex: spaceId.hex),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(SpaceScreen)));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('space-channel-name')),
        'Stewards',
      );
      await tester.tap(find.byKey(const ValueKey('space-channel-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.spaceChannelVoice).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('space-channel-access')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.spaceChannelAccessRestricted).last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<SpaceChannelKind>>(
              find.byKey(const ValueKey('space-channel-kind')),
            )
            .initialValue,
        SpaceChannelKind.voice,
      );
      await tester.ensureVisible(
        find.byKey(ValueKey('space-channel-create-member-${bob.hex}')),
      );
      await tester.tap(
        find.byKey(ValueKey('space-channel-create-member-${bob.hex}')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('space-channel-save')),
      );
      await tester.tap(find.byKey(const ValueKey('space-channel-save')));
      await tester.pumpAndSettle();

      final channel = (await service.channelsOf(
        spaceId,
      )).singleWhere((entry) => entry.name == 'Stewards');
      expect(channel.kind, SpaceChannelKind.voice);
      expect(channel.access, SpaceChannelAccess.restricted);
      expect(await service.channelMembersOf(spaceId, channel.channelId), [
        owner,
        bob,
      ]);
      expect(find.text(l.spaceChannelAccessRestricted), findsOneWidget);

      await tester.tap(
        find.byKey(ValueKey('space-channel-manage-${channel.channelId.hex}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('space-channel-members-action')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('space-channel-member-${bob.hex}')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('space-channel-members-save')),
      );
      await tester.pumpAndSettle();

      expect(await service.channelMembersOf(spaceId, channel.channelId), [
        owner,
      ]);
    },
  );

  testWidgets('Space settings manage signed roster, name and P2P redundancy', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(1);
    final alice = _id(2);
    final invitations = <String>[];
    final service = GroupService(
      storage,
      _Signer(owner),
      sendSpaceInvite: (peer, inviteId, json) async => invitations.add(json),
    );
    final spaceId = await service.createSpace('Protocol lab');
    final conversations = [
      Conversation(
        peer: Contact(
          nodeId: alice,
          name: 'Alice',
          status: ContactStatus.accepted,
        ),
      ),
    ];
    await storage.upsertContact(conversations.single.peer);

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          groupServiceProvider.overrideWithValue(service),
          conversationsProvider.overrideWith(
            (ref) => Stream.value(conversations),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: SpaceSettingsScreen(spaceIdHex: spaceId.hex),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpaceSettingsScreen)));

    expect(find.text(l.spaceSettingsTitle), findsOneWidget);
    expect(find.text('Protocol lab'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('space-subscription-settings')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('space-feed-setting')),
    );
    await tester.tap(find.byKey(const ValueKey('space-feed-setting')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('space-comment-notifications-setting')),
    );
    await tester.tap(
      find.byKey(const ValueKey('space-comment-notifications-setting')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spaceCommentNotificationsAll).last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('space-notifications-setting')),
    );
    await tester.tap(find.byKey(const ValueKey('space-notifications-setting')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('space-hide-recommendations-setting')),
    );
    await tester.tap(
      find.byKey(const ValueKey('space-hide-recommendations-setting')),
    );
    await tester.pumpAndSettle();
    final subscription = await service.spaceSubscription(spaceId);
    expect(subscription.feedEnabled, isFalse);
    expect(subscription.notificationsEnabled, isFalse);
    expect(subscription.commentNotifications, SpaceCommentNotificationMode.all);
    expect(subscription.hiddenFromRecommendations, isTrue);

    await tester.ensureVisible(find.byKey(const ValueKey('space-add-member')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('space-add-member')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Alice'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, l.spaceMemberAdd),
      ),
    );
    await tester.pumpAndSettle();
    expect(invitations, hasLength(1));
    expect((await service.stateOf(spaceId))!.roleOf(alice), isNull);
    expect(find.text(l.spaceInviteSent), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(find.byType(SpaceSettingsScreen)),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    // The recipient-side consent handshake is covered by GroupService tests.
    // Materialize the accepted grant so this widget test can continue through
    // the existing-member moderation controls.
    expect(
      await service.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: alice,
        role: GroupRole.member,
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect((await service.stateOf(spaceId))!.roleOf(alice), GroupRole.member);
    await tester.ensureVisible(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spaceMemberPromote));
    await tester.pumpAndSettle();
    expect((await service.stateOf(spaceId))!.roleOf(alice), GroupRole.admin);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('space-rename-button')),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('space-rename-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Renamed lab');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, l.spaceRenameAction),
      ),
    );
    await tester.pumpAndSettle();
    expect((await service.stateOf(spaceId))!.name, 'Renamed lab');
    expect(find.text('Renamed lab'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('space-description-edit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('space-description-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-description-field')),
      'Distributed protocol research',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, l.spaceDescriptionSave),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      (await service.stateOf(spaceId))!.description,
      'Distributed protocol research',
    );
    expect(find.text('Distributed protocol research'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('space-replication-slider')),
    );
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('space-replication-slider')),
    );
    slider.onChanged!(8);
    slider.onChangeEnd!(8);
    await tester.pumpAndSettle();
    expect(await service.groupSyncNeighborCount(spaceId), 8);

    await tester.ensureVisible(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spaceMemberRemove));
    await tester.pumpAndSettle();
    expect(find.text(l.spaceMemberRemoveConfirm('Alice')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, l.spaceMemberRemove),
      ),
    );
    await tester.pumpAndSettle();
    expect((await service.stateOf(spaceId))!.isMember(alice), isFalse);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('space-add-member')),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('space-add-member')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, l.spaceMemberAdd),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      await service.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: alice,
        role: GroupRole.member,
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byIcon(Icons.more_vert),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spaceMemberTransferOwnership));
    await tester.pumpAndSettle();
    expect(
      find.text(l.spaceMemberTransferOwnershipConfirm('Alice')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(
          FilledButton,
          l.spaceMemberTransferOwnership,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final transferred = (await service.stateOf(spaceId))!;
    expect(transferred.roleOf(owner), GroupRole.admin);
    expect(transferred.roleOf(alice), GroupRole.owner);
  });

  testWidgets('public Space join link and approval are available in UI', (
    tester,
  ) async {
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
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(51);
    final requester = _id(52);
    final service = GroupService(
      storage,
      _Signer(owner),
      sendSpaceJoinDecision: (peer, requestId, json) async {},
    );
    addTearDown(service.dispose);
    final spaceId = await service.createSpace(
      'Open lab',
      visibility: SpaceVisibility.public,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          groupServiceProvider.overrideWithValue(service),
          conversationsProvider.overrideWith((ref) => Stream.value(const [])),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: SpaceSettingsScreen(spaceIdHex: spaceId.hex),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpaceSettingsScreen)));

    expect(find.byKey(const ValueKey('space-join-link-tile')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('space-join-link-create')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    final firstCode = (await service.currentSpaceJoinCode(spaceId))!;
    expect(firstCode, startsWith('xveil://space/v1#'));
    expect(copied, firstCode);
    expect(find.text(l.spaceJoinLinkCopied), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(find.byType(SpaceSettingsScreen)),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('space-join-link-revoke')));
    await tester.pumpAndSettle();
    expect(await service.currentSpaceJoinCode(spaceId), isNull);
    await tester.tap(find.byKey(const ValueKey('space-join-link-create')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    final code = (await service.currentSpaceJoinCode(spaceId))!;
    expect(code, isNot(firstCode));
    expect(copied, code);
    ScaffoldMessenger.of(
      tester.element(find.byType(SpaceSettingsScreen)),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    final ticket = SpaceJoinCode.parse(code);
    final now = DateTime.now().millisecondsSinceEpoch;
    final request = SpaceJoinRequest(
      requestId: 'ef' * 32,
      ticketId: ticket.ticketId,
      ticketHash: spaceJoinTicketHash(ticket),
      spaceId: spaceId,
      requester: requester,
      approver: owner,
      createdAtMs: now,
    );
    expect(
      await service.receiveSpaceJoinRequest(
        requester,
        jsonEncode(request.toJson()),
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('space-join-request-${request.requestId}')),
      findsOneWidget,
    );
    final approve = find.widgetWithText(FilledButton, l.spaceJoinApprove);
    await tester.ensureVisible(approve);
    await tester.pumpAndSettle();
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect((await service.stateOf(spaceId))!.isMember(requester), isTrue);
  });

  testWidgets('Space owner archives and restores from settings', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(19);
    final service = GroupService(storage, _Signer(owner));
    addTearDown(service.dispose);
    final spaceId = await service.createSpace('Lifecycle lab');

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: SpaceSettingsScreen(spaceIdHex: spaceId.hex),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpaceSettingsScreen)));
    final lifecycleAction = find.byKey(
      const ValueKey('space-lifecycle-action'),
    );
    await tester.scrollUntilVisible(
      lifecycleAction,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(lifecycleAction);
    await tester.pumpAndSettle();
    await tester.tap(lifecycleAction);
    await tester.pumpAndSettle();
    expect(find.text(l.spaceArchiveConfirm), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('space-lifecycle-confirm')));
    await tester.pumpAndSettle();
    expect((await service.stateOf(spaceId))!.isArchived, isTrue);
    expect(find.text(l.spaceArchivedTitle), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('space-lifecycle-action')));
    await tester.pumpAndSettle();
    expect(find.text(l.spaceRestoreConfirm), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('space-lifecycle-confirm')));
    await tester.pumpAndSettle();
    expect((await service.stateOf(spaceId))!.isArchived, isFalse);
    expect(find.text(l.spaceActiveTitle), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('space-delete-action')));
    await tester.pumpAndSettle();
    expect(find.text(l.spaceDeleteConfirm), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('space-delete-confirm')));
    await tester.pumpAndSettle();
    final deleted = (await service.stateOf(spaceId))!;
    expect(deleted.isDeleted, isTrue);
    expect(deleted.lifecycleTransition?.recoveryDeadlineMs, isNotNull);
    expect(find.text(l.spaceDeletedTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('space-delete-action')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('space-lifecycle-action')));
    await tester.pumpAndSettle();
    expect(find.text(l.spaceRestoreConfirm), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('space-lifecycle-confirm')));
    await tester.pumpAndSettle();
    expect((await service.stateOf(spaceId))!.isActive, isTrue);
    expect(find.text(l.spaceActiveTitle), findsOneWidget);
  });

  testWidgets('owner creates a signed recommendation campaign in settings', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(29);
    final service = GroupService(storage, _Signer(owner));
    addTearDown(service.dispose);
    final spaceId = await service.createSpace(
      'Public lab',
      visibility: SpaceVisibility.public,
    );

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: SpaceSettingsScreen(spaceIdHex: spaceId.hex),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final create = find.byKey(const ValueKey('space-recommendation-create'));
    for (var i = 0; i < 6 && create.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -500));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-recommendation-text')),
      'Расскажите тем, кому это действительно полезно',
    );
    await tester.tap(
      find.byKey(const ValueKey('space-recommendation-create-confirm')),
    );
    await tester.pumpAndSettle();

    final campaigns = await service.spaceRecommendationCampaigns(spaceId);
    expect(campaigns, hasLength(1));
    expect(
      campaigns.single.text,
      'Расскажите тем, кому это действительно полезно',
    );
    final row = find.byKey(
      ValueKey('space-recommendation-${campaigns.single.campaignId}'),
    );
    for (var i = 0; i < 4 && row.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(row, findsOneWidget);
  });

  testWidgets('Space rules publish, display history and require acceptance', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(21);
    final service = GroupService(storage, _Signer(owner));
    addTearDown(service.dispose);
    final spaceId = await service.createSpace('Rules lab');

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: SpaceRulesScreen(spaceIdHex: spaceId.hex),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpaceRulesScreen)));

    expect(find.text(l.spaceRulesEmpty), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('space-rules-publish')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-rules-summary-field')),
      'Respect privacy.',
    );
    await tester.enterText(
      find.byKey(const ValueKey('space-rules-full-text-field')),
      'Do not publish private information without consent.',
    );
    await tester.tap(find.byKey(const ValueKey('space-rules-save')));
    await tester.pumpAndSettle();

    expect(
      find.text('Do not publish private information without consent.'),
      findsOneWidget,
    );
    expect(find.text(l.spaceRulesAcceptanceRequired), findsOneWidget);
    expect((await service.stateOf(spaceId))!.currentRules?.version, 1);

    await tester.tap(find.byKey(const ValueKey('space-rules-accept')));
    await tester.pumpAndSettle();
    expect(
      (await service.stateOf(spaceId))!.requiresRulesAcceptance(owner),
      isFalse,
    );
    expect(find.text(l.spaceRulesAccepted), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('space-rules-publish')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-rules-full-text-field')),
      'Respect privacy and verify sources before redistribution.',
    );
    await tester.tap(find.byKey(const ValueKey('space-rules-save')));
    await tester.pumpAndSettle();
    final state = (await service.stateOf(spaceId))!;
    expect(state.currentRules?.version, 2);
    expect(state.rulesHistory, hasLength(2));
    expect(state.requiresRulesAcceptance(owner), isTrue);
    expect(find.text(l.spaceRulesHistory), findsOneWidget);
  });

  testWidgets('Space moderation screen writes and revokes signed actions', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(21);
    final member = _id(22);
    final service = GroupService(storage, _Signer(owner));
    addTearDown(service.dispose);
    final spaceId = await service.createSpace(
      'Moderated lab',
      visibility: SpaceVisibility.public,
    );
    expect(
      await service.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: member,
        role: GroupRole.member,
      ),
      isTrue,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: SpaceModerationScreen(spaceIdHex: spaceId.hex),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpaceModerationScreen)));
    expect(find.text(l.spaceModerationEmpty), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('space-moderation-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-moderation-reason')),
      'Verified warning',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, l.spaceModerationAdd),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Verified warning'), findsOneWidget);
    final record = (await service.spaceModerationAudit(spaceId)).single;
    expect(record.action.kind, SpaceModerationKind.warning);
    expect(record.revokedAtMs, isNull);

    await tester.tap(find.byIcon(Icons.undo_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-moderation-revoke-reason')),
      'Warning reviewed',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, l.spaceModerationRevoke),
      ),
    );
    await tester.pumpAndSettle();
    final revoked = (await service.spaceModerationAudit(spaceId)).single;
    expect(revoked.revocationReason, 'Warning reviewed');
    expect(find.textContaining(l.spaceModerationRevoked), findsOneWidget);
  });

  testWidgets('Space owner creates roles, groups and direct assignments', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(75);
    final service = GroupService(storage, _Signer(owner));
    addTearDown(service.dispose);
    final spaceId = await service.createSpace('Access settings');
    final categoryId = await service.createChannel(
      spaceId,
      name: 'Editorial category',
      kind: SpaceChannelKind.category,
      history: SpaceChannelHistory.full,
    );
    expect(categoryId, isNotNull);
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          groupServiceProvider.overrideWithValue(service),
          conversationsProvider.overrideWith((ref) => Stream.value(const [])),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: SpaceSettingsScreen(spaceIdHex: spaceId.hex),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpaceSettingsScreen)));
    final accessExpansion = find.byKey(
      const ValueKey('space-access-expansion'),
    );
    await tester.ensureVisible(accessExpansion);
    await tester.tap(accessExpansion);
    await tester.pumpAndSettle();
    final addRole = find.byKey(const ValueKey('space-access-add-role'));
    await tester.ensureVisible(addRole);
    await tester.pumpAndSettle();
    await tester.tap(addRole);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-access-role-name')),
      'Publisher',
    );
    final permission = find.byKey(
      const ValueKey('space-access-permission-publishPosts'),
    );
    await tester.ensureVisible(permission);
    await tester.tap(permission);
    await tester.pump();
    final publishScope = find.byKey(
      const ValueKey('space-access-scope-publishPosts-0'),
    );
    await tester.ensureVisible(publishScope);
    await tester.tap(publishScope);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spaceAccessScopePosts).last);
    await tester.pumpAndSettle();
    final denyPublish = find.byKey(
      const ValueKey('space-access-add-deny-publishPosts'),
    );
    await tester.ensureVisible(denyPublish);
    await tester.tap(denyPublish);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('space-access-deny-scope-publishPosts-0')),
      findsOneWidget,
    );
    final manageChannels = find.byKey(
      const ValueKey('space-access-permission-manageChannels'),
    );
    await tester.ensureVisible(manageChannels);
    await tester.tap(manageChannels);
    await tester.pumpAndSettle();
    final channelScope = find.byKey(
      const ValueKey('space-access-scope-manageChannels-1'),
    );
    await tester.ensureVisible(channelScope);
    await tester.tap(channelScope);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spaceAccessScopeCategory).last);
    await tester.pumpAndSettle();
    expect(find.text('Editorial category'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('space-access-role-save')));
    await tester.pumpAndSettle();

    var state = (await service.stateOf(spaceId))!;
    final role = state.accessPolicy!.roles.single;
    expect(role.name, 'Publisher');
    expect(role.permissions, {
      SpacePermission.publishPosts,
      SpacePermission.manageChannels,
    });
    expect(role.grants, hasLength(2));
    expect(role.denials, [
      const SpacePermissionDenial(
        permission: SpacePermission.publishPosts,
        scope: SpacePermissionScope.space(),
      ),
    ]);
    expect(
      role.grants,
      contains(
        SpacePermissionGrant(
          permission: SpacePermission.manageChannels,
          scope: SpacePermissionScope(
            kind: SpacePermissionScopeKind.category,
            targetId: categoryId,
          ),
        ),
      ),
    );
    expect(state.accessPolicy?.schemaVersion, 3);
    expect(
      (await service.load(
        spaceId,
      ))!.control.lastWhere((entry) => entry.op == ControlOp.setPolicy).version,
      19,
    );
    expect(find.text('Publisher'), findsOneWidget);

    final assign = find.byKey(ValueKey('space-access-assign-${owner.hex}'));
    await tester.ensureVisible(assign);
    await tester.pumpAndSettle();
    await tester.tap(assign);
    await tester.pumpAndSettle();
    final directRole = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(CheckboxListTile, 'Publisher'),
    );
    await tester.tap(directRole);
    await tester.tap(find.byKey(const ValueKey('space-access-direct-save')));
    await tester.pumpAndSettle();
    state = (await service.stateOf(spaceId))!;
    expect(state.customRoleIdsOf(owner), {role.roleId});

    final addGroup = find.byKey(const ValueKey('space-access-add-group'));
    await tester.ensureVisible(addGroup);
    await tester.pumpAndSettle();
    await tester.tap(addGroup);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-access-group-name')),
      'Editorial',
    );
    final groupDialog = find.byType(AlertDialog);
    await tester.tap(
      find.descendant(
        of: groupDialog,
        matching: find.widgetWithText(CheckboxListTile, 'Publisher'),
      ),
    );
    await tester.tap(
      find.descendant(
        of: groupDialog,
        matching: find.widgetWithText(CheckboxListTile, l.spaceYou),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('space-access-group-save')));
    await tester.pumpAndSettle();

    state = (await service.stateOf(spaceId))!;
    expect(state.accessPolicy?.groups.single.name, 'Editorial');
    expect(state.accessPolicy?.revision, 3);
    expect(find.text('Editorial'), findsOneWidget);
  });

  testWidgets(
    'manageRoles delegate sees only lower roles, targets and permission scopes',
    (tester) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(90);
      final manager = _id(91);
      final member = _id(92);
      final ownerService = GroupService(storage, _Signer(owner));
      final managerService = GroupService(storage, _Signer(manager));
      addTearDown(ownerService.dispose);
      addTearDown(managerService.dispose);
      final spaceId = await ownerService.createSpace('Delegated role UI');
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: manager,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: member,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final managerRoleId = ownerService.newSpaceAccessObjectId();
      final publisherRoleId = ownerService.newSpaceAccessObjectId();
      final managerRole = SpaceRoleDefinition(
        roleId: managerRoleId,
        name: 'Role manager',
        permissions: const {
          SpacePermission.manageRoles,
          SpacePermission.managePosts,
        },
      );
      final publisherRole = SpaceRoleDefinition(
        roleId: publisherRoleId,
        name: 'Publisher',
        permissions: const {SpacePermission.publishPosts},
      );
      expect(
        await ownerService.replaceSpaceAccessPolicy(
          spaceId,
          expectedRevision: 0,
          roles: [managerRole, publisherRole],
          groups: const <SpaceMemberGroup>[],
          directAssignments: [
            SpaceMemberRoleAssignment(
              member: manager,
              roleIds: [managerRoleId],
            ),
            SpaceMemberRoleAssignment(
              member: member,
              roleIds: [publisherRoleId],
            ),
          ],
        ),
        isNotNull,
      );

      await tester.binding.setSurfaceSize(const Size(430, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [groupServiceProvider.overrideWithValue(managerService)],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: SpaceSettingsScreen(spaceIdHex: spaceId.hex),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('space-access-expansion')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('space-access-delegated-hint')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('space-access-add-role')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('space-access-add-group')),
        findsOneWidget,
      );
      final managerTile = find.byKey(
        ValueKey('space-access-role-$managerRoleId'),
      );
      final publisherTile = find.byKey(
        ValueKey('space-access-role-$publisherRoleId'),
      );
      expect(
        find.descendant(
          of: managerTile,
          matching: find.byIcon(Icons.edit_outlined),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: publisherTile,
          matching: find.byIcon(Icons.edit_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('space-access-assign-${manager.hex}')),
        findsNothing,
      );
      expect(
        find.byKey(ValueKey('space-access-assign-${owner.hex}')),
        findsNothing,
      );
      final memberAssignment = find.byKey(
        ValueKey('space-access-assign-${member.hex}'),
      );
      await tester.scrollUntilVisible(
        memberAssignment,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(memberAssignment, findsOneWidget);

      final addRole = find.byKey(const ValueKey('space-access-add-role'));
      await tester.ensureVisible(addRole);
      await tester.tap(addRole);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('space-access-permission-manageRoles')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('space-access-permission-manageStorage')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('space-access-permission-managePosts')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('space-access-permission-publishPosts')),
        findsOneWidget,
      );
    },
  );
}
