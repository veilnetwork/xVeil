import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/domain/space_channel.dart';
import 'package:xveil/features/groups/group_chat_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/group_epoch_service.dart';
import 'package:xveil/state/media_ffi.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';
import 'package:xveil/domain/space_moderation.dart';

class _Signer implements GroupSigner {
  _Signer(this.selfId);

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
      signature.length == 64 &&
      publicKey.length == 32;

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
  // The composer contract below is the one for a build that HAS a call media
  // engine, and that is now a thing worth saying out loud: the mic and
  // video-note buttons are wired to `callMediaAvailableProvider`, and a test
  // binary carries no libveil_media, so without this both tests would be
  // asserting the shape of a build nobody ships. The last test in this file
  // asserts the other shape.
  setUp(() => VeilMediaNative.debugForceAvailable = true);
  tearDown(() {
    VeilMediaNative.debugForceAvailable = null;
    VeilMediaNative.forgetProbe();
  });

  testWidgets('group chat uses the same unified composer contract', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final self = NodeId(Uint8List.fromList(List<int>.filled(32, 7)));
    final service = GroupService(storage, _Signer(self));
    addTearDown(service.dispose);
    final groupId = await service.createGroup('Composer test');

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          groupServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: GroupChatScreen(groupIdHex: groupId.hex),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('group-sync-settings')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group-sync-settings')));
    await tester.pumpAndSettle();
    expect(find.text('XOR neighbours: 5'), findsOneWidget);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('group-sync-neighbors-slider')),
    );
    slider.onChanged!(8);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await service.groupSyncNeighborCount(groupId), 8);

    expect(
      find.byKey(const ValueKey('group-message-composer')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('composer-attachment-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('composer-format-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('composer-expression-button')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('composer-video-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-voice-note')), findsOneWidget);
    expect(
      find.byIcon(Icons.image_outlined),
      findsNothing,
      reason: 'the old permanent group image button must be gone',
    );

    await tester.tap(find.byKey(const ValueKey('composer-expression-button')));
    await tester.pumpAndSettle();
    expect(find.text('Emoji'), findsOneWidget);
    expect(find.text('Stickers'), findsOneWidget);
    expect(find.text('GIF'), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    final field = find.byType(TextField).first;
    await tester.enterText(field, 'hello');
    await tester.pump();
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-video-note')), findsNothing);
    expect(find.byKey(const ValueKey('composer-voice-note')), findsNothing);

    await tester.enterText(field, '');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-attachment-button')));
    await tester.pumpAndSettle();
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Upload photo'), findsOneWidget);
    expect(find.text('Upload video'), findsOneWidget);
    expect(find.text('Upload file'), findsOneWidget);
    expect(find.text('Poll'), findsOneWidget);
    expect(find.text('Location'), findsOneWidget);
  });

  testWidgets('restricted channel keeps protected media composer actions', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final self = NodeId(Uint8List.fromList(List<int>.filled(32, 8)));
    final service = GroupService(
      storage,
      _Signer(self),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: self),
      ),
    );
    addTearDown(service.dispose);
    final spaceId = await service.createSpace('Protected composer');
    final channelId = await service.createChannel(
      spaceId,
      name: 'Private media',
      kind: SpaceChannelKind.text,
      access: SpaceChannelAccess.restricted,
      members: const [],
    );
    expect(channelId, isNotNull);
    expect(
      await service.postMessage(
        spaceId,
        'private reaction target',
        channelId: channelId,
        broadcast: false,
      ),
      isTrue,
    );

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          groupServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: GroupChatScreen(
            groupIdHex: spaceId.hex,
            channelIdHex: channelId!.hex,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('composer-attachment-button')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('composer-video-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-voice-note')), findsOneWidget);
    await tester.longPress(find.text('private reaction target'));
    await tester.pumpAndSettle();
    expect(find.text('👍'), findsOneWidget);
    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();
    final target = (await service.messagesOf(
      spaceId,
      channelId: channelId,
    )).single;
    expect((await service.reactionsOf(spaceId))[target.ref]?['👍'], [self]);
    expect((await service.load(spaceId))!.reactions.single.version, 7);
    await tester.tap(find.byKey(const ValueKey('composer-attachment-button')));
    await tester.pumpAndSettle();
    expect(find.text('Upload photo'), findsOneWidget);
    expect(find.text('Upload video'), findsOneWidget);
    expect(find.text('Upload file'), findsOneWidget);
  });

  // The other shape: a build assembled with no libveil_media, which the
  // desktop plugin CMake now allows on purpose. Recording is not offered
  // rather than offered and broken — the same answer the Transcribe
  // affordance gives without whisper. Everything else in the composer is
  // untouched, because nothing else needs the engine.
  testWidgets('with no media engine the composer offers no recording', (
    tester,
  ) async {
    VeilMediaNative.debugForceAvailable = false;
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final self = NodeId(Uint8List.fromList(List<int>.filled(32, 9)));
    final service = GroupService(storage, _Signer(self));
    addTearDown(service.dispose);
    final groupId = await service.createGroup('No engine here');

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          groupServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: GroupChatScreen(groupIdHex: groupId.hex),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('composer-video-note')), findsNothing);
    expect(find.byKey(const ValueKey('composer-voice-note')), findsNothing);
    // Starting a group call is gated on the same answer: without it the
    // attempt fails inside the FSM and the only feedback is "busy".
    expect(find.byKey(const ValueKey('group-call-start-audio')), findsNothing);
    expect(find.byKey(const ValueKey('group-call-start-video')), findsNothing);
    // The rest of the composer is unaffected.
    expect(
      find.byKey(const ValueKey('group-message-composer')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('composer-attachment-button')),
      findsOneWidget,
    );
  });
}
