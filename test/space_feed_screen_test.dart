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
import 'package:xveil/features/spaces/space_feed_screen.dart';
import 'package:xveil/features/spaces/space_posts_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/group_service_providers.dart';

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
  bool _valid(List<int> signature, List<int> publicKey) =>
      signature.length == 64 && publicKey.length == 32;
  @override
  bool verifyControl(ControlEntry value) =>
      _valid(value.signature, value.authorPubKey);
  @override
  bool verifyMessage(GroupMessage value) =>
      _valid(value.signature, value.authorPubKey);
  @override
  bool verifyReaction(GroupReaction value) =>
      _valid(value.signature, value.authorPubKey);
  @override
  bool verifyPost(SpacePost value) =>
      _valid(value.signature, value.authorPubKey);
  @override
  bool verifyContentRequest(GroupContentRequest value) =>
      _valid(value.signature, value.authorPubKey);
  @override
  bool verifyCallSignal(GroupCallSignal value) =>
      _valid(value.signature, value.authorPubKey);
  @override
  bool verifySpaceManifest(SpaceManifest value) => value.signature.length == 64;
  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => false;
}

Widget _host(GroupService service, Widget child) => ProviderScope(
  overrides: [groupServiceProvider.overrideWithValue(service)],
  child: MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: child,
  ),
);

void main() {
  testWidgets('Feed renders a separate chronological Space publication', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(_id(1)));
    final spaceId = await service.createSpace(
      'Protocol lab',
      visibility: SpaceVisibility.public,
    );
    final post = await service.publishSpacePost(
      spaceId,
      title: 'Release',
      body: 'A post, not a channel message',
      broadcast: false,
    );

    await tester.pumpWidget(_host(service, const SpaceFeedScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Protocol lab'), findsOneWidget);
    expect(find.text('Release'), findsOneWidget);
    expect(find.text('A post, not a channel message'), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('space-post-add-reaction-${post!.postId}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();
    expect(find.text('👍 1'), findsOneWidget);
    expect((await service.spacePostReactionsOf(spaceId))[post.postId]?['👍'], [
      _id(1),
    ]);
    final l = AppL10n.of(tester.element(find.byType(SpaceFeedScreen)));
    await tester.tap(
      find.byKey(ValueKey('space-feed-post-menu-${post.postId}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.feedPostHide));
    await tester.pumpAndSettle();
    expect(find.text('Release'), findsNothing);
    expect(find.text(l.feedPostHidden), findsOneWidget);
    expect(await service.postsOf(spaceId), hasLength(1));

    await tester.tap(find.text(l.feedPostUndo));
    await tester.pumpAndSettle();
    expect(find.text('Release'), findsOneWidget);
  });

  testWidgets('Space publications screen composes and publishes through ACL', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(_id(2)));
    final spaceId = await service.createSpace(
      'Writers',
      visibility: SpaceVisibility.public,
    );

    await tester.pumpWidget(
      _host(service, SpacePostsScreen(spaceIdHex: spaceId.hex)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpacePostsScreen)));
    expect(find.text(l.spacePostCreateTitle), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(1), 'Fresh update');
    await tester.tap(find.text(l.spacePostPublish));
    await tester.pumpAndSettle();
    expect(find.text('Fresh update'), findsOneWidget);
    expect((await service.load(spaceId))!.messages, isEmpty);
    expect((await service.load(spaceId))!.posts, hasLength(1));

    final postId = (await service.postsOf(spaceId)).single.postId;
    final menu = find.byKey(ValueKey('space-post-menu-$postId'));
    await tester.ensureVisible(menu);
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spacePostEdit));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-post-body-field')),
      'Corrected update',
    );
    await tester.tap(find.byKey(const ValueKey('space-post-save-edit')));
    await tester.pumpAndSettle();
    expect(find.text('Corrected update'), findsOneWidget);
    expect(find.text(l.spacePostEdited), findsOneWidget);
    expect((await service.load(spaceId))!.posts, hasLength(2));

    await tester.ensureVisible(menu);
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.spacePostDelete));
    await tester.pumpAndSettle();
    expect(find.text(l.spacePostDeleteTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('space-post-delete-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Corrected update'), findsNothing);
    expect(await service.postsOf(spaceId), isEmpty);
    expect((await service.load(spaceId))!.posts, hasLength(3));
  });
}
