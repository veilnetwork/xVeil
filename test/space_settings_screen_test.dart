import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_moderation.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/features/spaces/space_list_screen.dart';
import 'package:xveil/features/spaces/space_moderation_screen.dart';
import 'package:xveil/features/spaces/space_rules_screen.dart';
import 'package:xveil/features/spaces/space_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
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

void main() {
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
    expect(find.text(l.spaceOwnerLeaveHint), findsOneWidget);

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
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('space-lifecycle-action')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('space-lifecycle-action')));
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
}
