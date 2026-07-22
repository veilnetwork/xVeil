import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:veil_media/veil_media.dart' show VeilVideoFrame;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/domain/space_channel.dart';
import 'package:xveil/features/spaces/space_feed_screen.dart';
import 'package:xveil/features/spaces/space_post_comments_screen.dart';
import 'package:xveil/features/spaces/space_posts_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/group_epoch_service.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/vnote_record_controller.dart';
import 'package:xveil/state/voice_record_controller.dart';

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

class _SpaceVoiceRecorder implements VoiceRecorder {
  bool disposed = false;

  @override
  int get elapsedMs => 1750;

  @override
  double get level => 0.6;

  @override
  bool start() => true;

  @override
  VoiceClip? stop({int waveformBars = 48}) => VoiceClip(
    bytes: Uint8List.fromList([1, 3, 5, 7]),
    durationMs: elapsedMs,
    waveform: List<double>.filled(waveformBars, 0.6),
  );

  @override
  void dispose() => disposed = true;
}

class _SpaceVnoteRecorder implements VnoteRecorder {
  bool disposed = false;

  @override
  int get elapsedMs => 2400;

  @override
  double get level => 0.4;

  @override
  VeilVideoFrame? frame() => null;

  @override
  Future<bool> start() async => true;

  @override
  VnoteClip? stop() =>
      VnoteClip(bytes: Uint8List.fromList([2, 4, 6, 8]), durationMs: elapsedMs);

  @override
  void dispose() => disposed = true;
}

Widget _host(
  GroupService service,
  Widget child, {
  Storage? storage,
  VoiceRecorderFactory? voiceRecorderFactory,
  VnoteRecorderFactory? vnoteRecorderFactory,
}) => ProviderScope(
  overrides: [
    groupServiceProvider.overrideWithValue(service),
    if (storage != null) storageProvider.overrideWithValue(storage),
    if (voiceRecorderFactory != null)
      voiceRecorderFactoryProvider.overrideWithValue(voiceRecorderFactory),
    if (vnoteRecorderFactory != null)
      vnoteRecorderFactoryProvider.overrideWithValue(vnoteRecorderFactory),
    if (voiceRecorderFactory != null || vnoteRecorderFactory != null)
      micPermissionProvider.overrideWithValue(() async => true),
    if (vnoteRecorderFactory != null)
      cameraPermissionProvider.overrideWithValue(() async => true),
  ],
  child: MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: child,
  ),
);

Widget _routerHost(GroupService service, GoRouter router, {Storage? storage}) =>
    ProviderScope(
      overrides: [
        groupServiceProvider.overrideWithValue(service),
        if (storage != null) storageProvider.overrideWithValue(storage),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        routerConfig: router,
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
    expect(
      await service.setSpacePostPinned(spaceId, post!.postId, true),
      isTrue,
    );

    await tester.pumpWidget(_host(service, const SpaceFeedScreen()));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpaceFeedScreen)));
    expect(find.text(l.feedPinnedTitle), findsNWidgets(2));
    expect(find.text('Protocol lab'), findsOneWidget);
    expect(
      find.text('Release'),
      findsOneWidget,
      reason: 'pin must not duplicate',
    );
    expect(find.text('A post, not a channel message'), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('space-post-add-reaction-${post.postId}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();
    expect(find.text('👍 1'), findsOneWidget);
    expect((await service.spacePostReactionsOf(spaceId))[post.postId]?['👍'], [
      _id(1),
    ]);
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

  testWidgets('Feed filters publication types and persists the selection', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final signer = _Signer(_id(7));
    final service = GroupService(storage, signer);
    final spaceId = await service.createSpace(
      'Media lab',
      visibility: SpaceVisibility.public,
    );
    await service.publishSpacePost(
      spaceId,
      title: 'Plain update',
      body: '',
      broadcast: false,
    );
    await service.publishSpacePost(
      spaceId,
      title: 'Long read',
      body: '',
      type: SpacePostType.article,
      broadcast: false,
    );

    await tester.pumpWidget(_host(service, const SpaceFeedScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Plain update'), findsOneWidget);
    expect(find.text('Long read'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('space-feed-type-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('space-feed-filter-post')));
    await tester.tap(find.byKey(const ValueKey('space-feed-filter-apply')));
    await tester.pumpAndSettle();
    expect(find.text('Plain update'), findsNothing);
    expect(find.text('Long read'), findsOneWidget);
    expect(
      await service.spaceFeedTypeFilter(),
      SpacePostType.values.where((type) => type != SpacePostType.post).toSet(),
    );

    final reopened = GroupService(storage, signer);
    await tester.pumpWidget(_host(reopened, const SpaceFeedScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Plain update'), findsNothing);
    expect(find.text('Long read'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('space-feed-type-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('space-feed-filter-all')));
    await tester.tap(find.byKey(const ValueKey('space-feed-filter-apply')));
    await tester.pumpAndSettle();
    expect(find.text('Plain update'), findsOneWidget);
    expect(find.text('Long read'), findsOneWidget);
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
    await tester.tap(find.byKey(const ValueKey('space-post-type-field')));
    await tester.pumpAndSettle();
    expect(find.text(l.spacePostTypePost), findsWidgets);
    expect(find.text(l.spacePostTypeArticle), findsOneWidget);
    expect(find.text(l.spacePostTypeVideo), findsOneWidget);
    expect(find.text(l.spacePostTypeShortVideo), findsOneWidget);
    expect(find.text(l.spacePostTypeAudio), findsOneWidget);
    expect(find.text(l.spacePostTypeVoiceMessage), findsOneWidget);
    await tester.tap(find.text(l.spacePostTypeShortVideo));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('space-post-body-field')),
      'Fresh update',
    );
    await tester.pump();
    await tester.tap(find.text(l.actionCancel));
    await tester.pumpAndSettle();
    final savedDraft = await service.spacePostDraft(spaceId);
    expect(savedDraft?.body, 'Fresh update');
    expect(savedDraft?.type, SpacePostType.shortVideo);
    expect((await service.load(spaceId))!.posts, isEmpty);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    final restoredBody = tester.widget<TextField>(
      find.byKey(const ValueKey('space-post-body-field')),
    );
    expect(restoredBody.controller?.text, 'Fresh update');
    expect(
      tester
          .widget<DropdownButtonFormField<SpacePostType>>(
            find.byKey(const ValueKey('space-post-type-field')),
          )
          .initialValue,
      SpacePostType.shortVideo,
    );
    await tester.tap(find.byKey(const ValueKey('space-post-publish')));
    await tester.pumpAndSettle();
    expect(find.text('Fresh update'), findsOneWidget);
    expect((await service.load(spaceId))!.messages, isEmpty);
    expect((await service.load(spaceId))!.posts, hasLength(1));
    expect(
      (await service.postsOf(spaceId)).single.type,
      SpacePostType.shortVideo,
    );
    expect(await service.spacePostDraft(spaceId), isNull);

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
    await tester.tap(find.text(l.spacePostPin));
    await tester.pumpAndSettle();
    expect(find.text(l.spacePostPinned), findsOneWidget);
    expect((await service.postsOf(spaceId)).single.pinned, isTrue);

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

  testWidgets(
    'Space publication discussion sends replies without becoming channel history',
    (tester) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(
        storage,
        _Signer(_id(8)),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: _id(8)),
        ),
      );
      final spaceId = await service.createSpace(
        'Discussion UI',
        visibility: SpaceVisibility.public,
      );
      final post = (await service.publishSpacePost(
        spaceId,
        title: 'Design review',
        body: 'Discuss this independently from channels.',
        broadcast: false,
      ))!;
      final commentMedia = MediaObject(
        contentId: 'f' * 64,
        kind: 'image',
        name: 'diagram.png',
        mimeType: 'image/png',
        size: 64,
      );

      await tester.pumpWidget(
        _host(
          service,
          SpacePostCommentsScreen(
            spaceIdHex: spaceId.hex,
            postId: post.postId,
            mediaPicker: (_) async => (media: [commentMedia], rejected: 0),
          ),
          storage: storage,
        ),
      );
      await tester.pumpAndSettle();
      final l = AppL10n.of(
        tester.element(find.byType(SpacePostCommentsScreen)),
      );
      expect(find.text('Design review'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('space-post-comments-back')),
        findsOneWidget,
      );
      expect(find.text(l.spacePostCommentsEmpty), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('space-post-comment-send')),
            )
            .onPressed,
        isNull,
      );

      await tester.enterText(
        find.byKey(const ValueKey('space-post-comment-composer')),
        'First comment',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('space-post-comment-send')));
      await tester.pumpAndSettle();
      expect(find.text('First comment'), findsOneWidget);

      final original = (await service.spacePostCommentsOf(
        spaceId,
        post.postId,
      )).single;
      await tester.enterText(
        find.byKey(const ValueKey('space-post-comment-composer')),
        'Preserved draft',
      );
      await tester.tap(
        find.byKey(ValueKey('space-post-comment-edit-${original.ref}')),
      );
      await tester.pump();
      expect(find.text(l.spacePostCommentEditing), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('space-post-comment-composer')),
        'Corrected first comment',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('space-post-comment-send')));
      await tester.pumpAndSettle();
      expect(find.text('First comment'), findsNothing);
      expect(find.text('Corrected first comment'), findsOneWidget);
      expect(find.text(l.spacePostCommentEdited), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('space-post-comment-composer')),
            )
            .controller
            ?.text,
        'Preserved draft',
      );
      final first = (await service.spacePostCommentsOf(
        spaceId,
        post.postId,
      )).single;
      expect(first.ref, original.ref);
      expect(first.edited, isTrue);
      await tester.tap(
        find.byKey(ValueKey('space-post-comment-reply-${first.ref}')),
      );
      await tester.pump();
      expect(
        find.text(l.spacePostCommentReplyingTo(first.author.short)),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('space-post-comment-composer')),
        'Threaded reply',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('space-post-comment-send')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('space-post-comment-attach')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('space-post-comment-media')),
        findsOneWidget,
      );
      expect(find.text('diagram.png'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('space-post-comment-send')));
      await tester.pumpAndSettle();

      final comments = await service.spacePostCommentsOf(spaceId, post.postId);
      expect(comments.map((comment) => comment.body), [
        'Corrected first comment',
        'Threaded reply',
        '',
      ]);
      expect(comments[1].replyTo, comments.first.ref);
      expect(
        comments.last.attachment?.toReferenceJson(),
        commentMedia.toReferenceJson(),
      );
      expect(find.text('Threaded reply'), findsOneWidget);
      expect(
        find.byKey(ValueKey('space-post-media-${commentMedia.contentId}')),
        findsOneWidget,
      );
      await tester.drag(
        find.byKey(const PageStorageKey('space-post-comments-list')),
        const Offset(0, 800),
      );
      await tester.pumpAndSettle();
      expect(find.text(l.spacePostCommentsCount(3)), findsOneWidget);
      expect(await service.referencedContentIds(spaceId), contains('f' * 64));
      expect(await service.messagesOf(spaceId), isEmpty);
      expect(
        await service.messagesOf(
          spaceId,
          channelId: defaultSpaceChannelId(spaceId),
        ),
        isEmpty,
      );
      expect((await service.listGroups()), isEmpty);
    },
  );

  testWidgets('Space comments back button returns to the previous screen', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(_id(18)));
    final spaceId = await service.createSpace(
      'Back navigation',
      visibility: SpaceVisibility.public,
    );
    final post = (await service.publishSpacePost(
      spaceId,
      title: 'Back navigation post',
      body: '',
      broadcast: false,
    ))!;
    final commentsPath =
        '/space/${spaceId.hex}/comments?post='
        '${Uri.encodeQueryComponent(post.postId)}';
    final router = GoRouter(
      initialLocation: '/feed',
      routes: [
        GoRoute(
          path: '/feed',
          builder: (context, _) => Scaffold(
            body: TextButton(
              key: const ValueKey('open-comments'),
              onPressed: () => context.push(commentsPath),
              child: const Text('Feed'),
            ),
          ),
        ),
        GoRoute(
          path: '/space/:id/comments',
          builder: (_, state) => SpacePostCommentsScreen(
            spaceIdHex: state.pathParameters['id']!,
            postId: state.uri.queryParameters['post']!,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_routerHost(service, router, storage: storage));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-comments')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('space-post-comments-back')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('open-comments')), findsOneWidget);
    expect(find.byType(SpacePostCommentsScreen), findsNothing);
  });

  testWidgets('Space comments back button has a direct-route fallback', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(_id(19)));
    final spaceId = await service.createSpace(
      'Back fallback',
      visibility: SpaceVisibility.public,
    );
    final post = (await service.publishSpacePost(
      spaceId,
      title: 'Fallback post',
      body: '',
      broadcast: false,
    ))!;
    final router = GoRouter(
      initialLocation:
          '/space/${spaceId.hex}/comments?post='
          '${Uri.encodeQueryComponent(post.postId)}',
      routes: [
        GoRoute(
          path: '/space/:id/posts',
          builder: (_, _) => const Scaffold(body: Text('Posts fallback')),
        ),
        GoRoute(
          path: '/space/:id/comments',
          builder: (_, state) => SpacePostCommentsScreen(
            spaceIdHex: state.pathParameters['id']!,
            postId: state.uri.queryParameters['post']!,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_routerHost(service, router, storage: storage));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('space-post-comments-back')));
    await tester.pumpAndSettle();

    expect(find.text('Posts fallback'), findsOneWidget);
    expect(find.byType(SpacePostCommentsScreen), findsNothing);
  });

  testWidgets(
    'Space publication composer persists, publishes and edits shared media refs',
    (tester) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _Signer(_id(12)));
      final spaceId = await service.createSpace(
        'Media writers',
        visibility: SpaceVisibility.public,
      );
      final media = MediaObjectRef(
        contentId: 'a' * 64,
        kind: 'image',
        name: 'release.png',
        mimeType: 'image/png',
        size: 42,
      );
      final screen = SpacePostsScreen(
        spaceIdHex: spaceId.hex,
        mediaPicker: (_) async => (media: [media], rejected: 0),
      );

      await tester.pumpWidget(_host(service, screen, storage: storage));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      final attach = find.byKey(const ValueKey('space-post-attach-media'));
      await tester.ensureVisible(attach);
      await tester.pumpAndSettle();
      await tester.tap(attach);
      await tester.pumpAndSettle();
      expect(find.text('release.png'), findsOneWidget);
      await tester.tap(
        find.text(
          AppL10n.of(
            tester.element(find.byType(SpacePostsScreen)),
          ).actionCancel,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        (await service.spacePostDraft(spaceId))?.media.single.name,
        'release.png',
      );

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      expect(find.text('release.png'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('space-post-publish')));
      await tester.pumpAndSettle();
      final published = (await service.postsOf(spaceId)).single;
      expect(published.media.single.contentId, media.contentId);
      expect(
        find.byKey(ValueKey('space-post-media-${media.contentId}')),
        findsOneWidget,
      );
      expect(await service.spacePostDraft(spaceId), isNull);

      final menu = find.byKey(ValueKey('space-post-menu-${published.postId}'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(SpacePostsScreen)));
      await tester.tap(find.text(l.spacePostEdit));
      await tester.pumpAndSettle();
      tester
          .widget<InputChip>(
            find.byKey(ValueKey('space-post-draft-media-${media.contentId}')),
          )
          .onDeleted!();
      await tester.enterText(
        find.byKey(const ValueKey('space-post-body-field')),
        'Text replacement',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('space-post-save-edit')));
      await tester.pumpAndSettle();
      final edited = (await service.postsOf(spaceId)).single;
      expect(edited.body, 'Text replacement');
      expect(edited.media, isEmpty);
      expect(await service.referencedContentIds(spaceId), isEmpty);
    },
  );

  testWidgets(
    'Space voice composer records into MediaObject and keeps it in the draft',
    (tester) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _Signer(_id(13)));
      final spaceId = await service.createSpace(
        'Voice writers',
        visibility: SpaceVisibility.public,
      );
      VoiceClip? captured;
      final recorders = <_SpaceVoiceRecorder>[];
      final screen = SpacePostsScreen(
        spaceIdHex: spaceId.hex,
        voiceMediaRegistrar: (clip) async {
          captured = clip;
          return MediaObject(
            contentId: 'b' * 64,
            kind: 'voice',
            name: 'voice.vop1',
            mimeType: 'audio/x-veil-vop1',
            size: clip.bytes.length,
            durationMs: clip.durationMs,
          );
        },
      );

      await tester.pumpWidget(
        _host(
          service,
          screen,
          storage: storage,
          voiceRecorderFactory: () {
            final recorder = _SpaceVoiceRecorder();
            recorders.add(recorder);
            return recorder;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(SpacePostsScreen)));
      await tester.tap(find.byKey(const ValueKey('space-post-type-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.spacePostTypeVoiceMessage));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('space-post-record-voice')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('space-post-record-voice')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('space-post-use-voice-recording')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('space-post-use-voice-recording')),
      );
      await tester.pumpAndSettle();

      expect(captured?.bytes, [1, 3, 5, 7]);
      expect(captured?.durationMs, 1750);
      expect(recorders.single.disposed, isTrue);
      expect(find.text('voice.vop1'), findsOneWidget);
      await tester.tap(find.text(l.actionCancel));
      await tester.pumpAndSettle();
      final draft = await service.spacePostDraft(spaceId);
      expect(draft?.type, SpacePostType.voiceMessage);
      expect(draft?.media.single.kind, 'voice');
      expect(draft?.media.single.durationMs, 1750);
    },
  );

  testWidgets(
    'Space short-video composer cancels cleanly then attaches a video note',
    (tester) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _Signer(_id(14)));
      final spaceId = await service.createSpace(
        'Short video writers',
        visibility: SpaceVisibility.public,
      );
      var registrations = 0;
      final recorders = <_SpaceVnoteRecorder>[];
      final screen = SpacePostsScreen(
        spaceIdHex: spaceId.hex,
        vnoteMediaRegistrar: (clip) async {
          registrations++;
          return MediaObject(
            contentId: 'c' * 64,
            kind: 'vnote',
            name: 'vnote.vn01',
            mimeType: 'video/x-veil-vnote',
            size: clip.bytes.length,
            durationMs: clip.durationMs,
          );
        },
      );

      await tester.pumpWidget(
        _host(
          service,
          screen,
          storage: storage,
          vnoteRecorderFactory: () {
            final recorder = _SpaceVnoteRecorder();
            recorders.add(recorder);
            return recorder;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(SpacePostsScreen)));
      await tester.tap(find.byKey(const ValueKey('space-post-type-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.spacePostTypeShortVideo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('space-post-record-vnote')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(
        find.byKey(const ValueKey('space-post-cancel-vnote-recording')),
      );
      await tester.pumpAndSettle();
      expect(registrations, 0);
      expect(recorders.single.disposed, isTrue);

      await tester.tap(find.byKey(const ValueKey('space-post-record-vnote')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(
        find.byKey(const ValueKey('space-post-use-vnote-recording')),
      );
      await tester.pumpAndSettle();
      expect(registrations, 1);
      expect(recorders, hasLength(2));
      expect(recorders.last.disposed, isTrue);
      expect(find.text('vnote.vn01'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('space-post-publish')));
      await tester.pumpAndSettle();
      final post = (await service.postsOf(spaceId)).single;
      expect(post.type, SpacePostType.shortVideo);
      expect(post.media.single.kind, 'vnote');
      expect(post.media.single.durationMs, 2400);
    },
  );
}
