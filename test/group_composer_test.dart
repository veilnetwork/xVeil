import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/features/groups/group_chat_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

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
  testWidgets('group chat uses the same unified composer contract', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final self = NodeId(Uint8List.fromList(List<int>.filled(32, 7)));
    final service = GroupService(storage, _Signer(self));
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
}
