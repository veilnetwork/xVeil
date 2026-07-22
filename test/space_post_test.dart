import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group_payload.dart';
import 'package:xveil/domain/space_post.dart';

NodeId _id(int value) =>
    NodeId(Uint8List.fromList(List<int>.filled(32, value)));

NodeId _ordinalId(int value) {
  final bytes = Uint8List(32);
  bytes[0] = (value >> 8) & 0xff;
  bytes[1] = value & 0xff;
  return NodeId(bytes);
}

void main() {
  test(
    'local Space post draft round-trips strictly without wire semantics',
    () {
      final spaceId = _id(19);
      final draft = SpacePostDraft(
        spaceId: spaceId,
        title: 'Unpublished',
        body: 'Only this identity can read this draft.',
        type: SpacePostType.voiceMessage,
        updatedAtMs: 42,
        media: [
          MediaObjectRef(
            contentId: 'a' * 64,
            kind: 'audio',
            name: 'memo.opus',
            mimeType: 'audio/opus',
            size: 128,
          ),
        ],
      );

      expect(draft.isStructurallyValid, isTrue);
      expect(draft.hasContent, isTrue);
      expect(
        SpacePostDraft.fromJson(draft.toJson(), spaceId)?.media.single.name,
        'memo.opus',
      );
      final legacy = Map<String, dynamic>.from(draft.toJson())
        ..['v'] = 1
        ..remove('media');
      expect(
        SpacePostDraft.fromJson(legacy, spaceId)?.type,
        SpacePostType.voiceMessage,
      );
      expect(SpacePostDraft.fromJson(draft.toJson(), _id(20)), isNull);
      expect(
        SpacePostDraft.fromJson({
          ...draft.toJson(),
          'type': 'unknown',
        }, spaceId),
        isNull,
      );
      expect(
        SpacePostDraft.fromJson({
          ...draft.toJson(),
          'media': [draft.media.single.toJson(), draft.media.single.toJson()],
        }, spaceId),
        isNull,
      );
    },
  );

  test('public SpacePost round-trips with stable signed media metadata', () {
    final post = SpacePost(
      spaceId: _id(1),
      author: _id(2),
      seq: 0,
      prevHash: '',
      type: SpacePostType.article,
      visibility: SpacePostVisibility.public,
      title: 'Release notes',
      body: 'The body is separate from channel messages.',
      media: [
        MediaObjectRef(
          contentId: 'a' * 64,
          kind: 'image',
          name: 'cover.webp',
          mimeType: 'image/webp',
          size: 42,
          width: 16,
          height: 9,
        ),
      ],
      policyVersion: 3,
      createdAtMs: 100,
      publishedAtMs: 101,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
    );
    expect(post.isStructurallyValid, isTrue);
    final decoded = SpacePost.fromJson(post.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.canonicalBytes(), post.canonicalBytes());
    expect(decoded.media.single.contentId, 'a' * 64);
    expect(decoded.postId, '${_id(2).hex}:0');

    final mixed = Map<String, dynamic>.from(post.toJson())
      ..['v'] = 2
      ..['epoch'] = 1
      ..['enc'] = {
        'v': 1,
        'nonce': base64Encode(Uint8List(12)),
        'ct': '',
        'mac': base64Encode(Uint8List(16)),
      };
    expect(SpacePost.fromJson(mixed), isNull);
  });

  test(
    'private post AEAD binds type, visibility and chronological metadata',
    () async {
      final key = Uint8List.fromList(List<int>.generate(32, (index) => index));
      final clear = const SpacePostCleartext(
        title: 'Private',
        body: 'members only',
      ).encode();
      final encrypted = await encryptSpacePostPayload(
        spaceId: _id(3),
        membershipEpoch: 4,
        author: _id(5),
        seq: 6,
        prevHash: 'prev',
        postType: SpacePostType.post.name,
        visibility: SpacePostVisibility.members.name,
        policyVersion: 7,
        createdAtMs: 8,
        publishedAtMs: 9,
        clearText: clear,
        epochKey: key,
        random: Random(10),
      );
      final opened = await decryptSpacePostPayload(
        spaceId: _id(3),
        membershipEpoch: 4,
        author: _id(5),
        seq: 6,
        prevHash: 'prev',
        postType: SpacePostType.post.name,
        visibility: SpacePostVisibility.members.name,
        policyVersion: 7,
        createdAtMs: 8,
        publishedAtMs: 9,
        payload: encrypted,
        epochKey: key,
      );
      expect(SpacePostCleartext.decode(opened)?.body, 'members only');

      await expectLater(
        decryptSpacePostPayload(
          spaceId: _id(3),
          membershipEpoch: 4,
          author: _id(5),
          seq: 6,
          prevHash: 'prev',
          postType: SpacePostType.article.name,
          visibility: SpacePostVisibility.members.name,
          policyVersion: 7,
          createdAtMs: 8,
          publishedAtMs: 9,
          payload: encrypted,
          epochKey: key,
        ),
        throwsFormatException,
      );
    },
  );

  test('causal frontier is canonical, sorted and signed into a V3 post', () {
    final frontier = SpaceControlFrontier([
      SpaceControlHead(author: _id(1), seq: 2, hash: 'a' * 64),
      SpaceControlHead(author: _id(2), seq: 0, hash: 'b' * 64),
    ]);
    final post = SpacePost(
      spaceId: _id(3),
      author: _id(1),
      seq: 0,
      prevHash: '',
      type: SpacePostType.post,
      visibility: SpacePostVisibility.public,
      title: '',
      body: 'causal',
      policyVersion: 0,
      createdAtMs: 1,
      publishedAtMs: 1,
      version: 3,
      controlFrontier: frontier,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
    );
    expect(post.isStructurallyValid, isTrue);
    final decoded = SpacePost.fromJson(post.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.canonicalBytes(), post.canonicalBytes());

    final brokenGenesis = Map<String, dynamic>.from(post.toJson())
      ..['prev'] = 'not-empty';
    expect(SpacePost.fromJson(brokenGenesis), isNull);

    final unsorted = SpaceControlFrontier([
      SpaceControlHead(author: _id(2), seq: 0, hash: 'b' * 64),
      SpaceControlHead(author: _id(1), seq: 2, hash: 'a' * 64),
    ]);
    expect(unsorted.isStructurallyValid, isFalse);
  });

  test('V4 post AEAD binds the causal control frontier', () async {
    final key = Uint8List(32);
    final frontier = [
      SpaceControlHead(author: _id(1), seq: 0, hash: 'a' * 64).toJson(),
    ];
    final encrypted = await encryptSpacePostPayload(
      spaceId: _id(3),
      membershipEpoch: 1,
      author: _id(1),
      seq: 0,
      prevHash: '',
      postType: SpacePostType.post.name,
      visibility: SpacePostVisibility.members.name,
      policyVersion: 0,
      createdAtMs: 1,
      publishedAtMs: 1,
      controlFrontier: frontier,
      clearText: const SpacePostCleartext(title: '', body: 'secret').encode(),
      epochKey: key,
      random: Random(2),
    );
    await expectLater(
      decryptSpacePostPayload(
        spaceId: _id(3),
        membershipEpoch: 1,
        author: _id(1),
        seq: 0,
        prevHash: '',
        postType: SpacePostType.post.name,
        visibility: SpacePostVisibility.members.name,
        policyVersion: 0,
        createdAtMs: 1,
        publishedAtMs: 1,
        controlFrontier: [
          SpaceControlHead(author: _id(1), seq: 0, hash: 'b' * 64).toJson(),
        ],
        payload: encrypted,
        epochKey: key,
      ),
      throwsFormatException,
    );
  });

  test('control checkpoint commits a large sorted frontier by Merkle root', () {
    final heads = [
      for (var index = 0; index < kSpaceControlFrontierMax + 1; index++)
        SpaceControlHead(
          author: _ordinalId(index),
          seq: index,
          hash: index.toRadixString(16).padLeft(64, '0'),
        ),
    ];
    final checkpoint = SpaceControlCheckpoint(heads);
    expect(checkpoint.isStructurallyValid, isTrue);
    expect(checkpoint.heads, hasLength(kSpaceControlFrontierMax + 1));
    final decoded = SpaceControlCheckpoint.fromJson(checkpoint.toJson());
    expect(decoded?.merkleRoot, checkpoint.merkleRoot);

    final tampered = Map<String, dynamic>.from(checkpoint.toJson())
      ..['root'] = 'f' * 64;
    expect(SpaceControlCheckpoint.fromJson(tampered), isNull);
  });

  test('V5 post signs only the reusable control checkpoint hash', () {
    final post = SpacePost(
      spaceId: _id(3),
      author: _id(1),
      seq: 0,
      prevHash: '',
      type: SpacePostType.post,
      visibility: SpacePostVisibility.public,
      title: '',
      body: 'checkpointed',
      policyVersion: 0,
      createdAtMs: 1,
      publishedAtMs: 1,
      version: 5,
      controlCheckpointHash: 'a' * 64,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
    );
    expect(post.isStructurallyValid, isTrue);
    final decoded = SpacePost.fromJson(post.toJson());
    expect(decoded?.controlCheckpointHash, 'a' * 64);
    expect(decoded?.canonicalBytes(), post.canonicalBytes());

    final missing = Map<String, dynamic>.from(post.toJson())
      ..remove('checkpoint');
    expect(SpacePost.fromJson(missing), isNull);
  });

  test('V6 post AEAD binds the control checkpoint hash', () async {
    final key = Uint8List(32);
    final encrypted = await encryptSpacePostPayload(
      spaceId: _id(3),
      membershipEpoch: 1,
      author: _id(1),
      seq: 0,
      prevHash: '',
      postType: SpacePostType.post.name,
      visibility: SpacePostVisibility.members.name,
      policyVersion: 0,
      createdAtMs: 1,
      publishedAtMs: 1,
      controlCheckpointHash: 'a' * 64,
      clearText: const SpacePostCleartext(
        title: '',
        body: 'secret checkpoint',
      ).encode(),
      epochKey: key,
      random: Random(3),
    );
    await expectLater(
      decryptSpacePostPayload(
        spaceId: _id(3),
        membershipEpoch: 1,
        author: _id(1),
        seq: 0,
        prevHash: '',
        postType: SpacePostType.post.name,
        visibility: SpacePostVisibility.members.name,
        policyVersion: 0,
        createdAtMs: 1,
        publishedAtMs: 1,
        controlCheckpointHash: 'b' * 64,
        payload: encrypted,
        epochKey: key,
      ),
      throwsFormatException,
    );
  });

  test(
    'V7 edit and tombstone rows are typed, signed and target only past roots',
    () {
      final edit = SpacePost(
        spaceId: _id(3),
        author: _id(1),
        seq: 2,
        prevHash: 'b' * 64,
        type: SpacePostType.article,
        visibility: SpacePostVisibility.public,
        title: 'Corrected',
        body: 'Immutable revision',
        policyVersion: 0,
        createdAtMs: 2,
        publishedAtMs: 2,
        version: 7,
        controlCheckpointHash: 'a' * 64,
        operation: SpacePostOperation.edit,
        targetSeq: 0,
        signature: Uint8List(64),
        authorPubKey: Uint8List(32),
      );
      expect(edit.isStructurallyValid, isTrue);
      final decoded = SpacePost.fromJson(edit.toJson());
      expect(decoded?.operation, SpacePostOperation.edit);
      expect(decoded?.targetSeq, 0);
      expect(decoded?.canonicalBytes(), edit.canonicalBytes());

      final forwardTarget = Map<String, dynamic>.from(edit.toJson())
        ..['target'] = 2;
      expect(SpacePost.fromJson(forwardTarget), isNull);
      final legacyWithMutation = Map<String, dynamic>.from(edit.toJson())
        ..['v'] = 5;
      expect(SpacePost.fromJson(legacyWithMutation), isNull);

      final tombstone = SpacePost(
        spaceId: edit.spaceId,
        author: edit.author,
        seq: 3,
        prevHash: 'c' * 64,
        type: SpacePostType.article,
        visibility: SpacePostVisibility.public,
        title: '',
        body: '',
        policyVersion: 0,
        createdAtMs: 3,
        publishedAtMs: 3,
        version: 7,
        controlCheckpointHash: 'a' * 64,
        operation: SpacePostOperation.delete,
        targetSeq: 0,
        signature: Uint8List(64),
        authorPubKey: Uint8List(32),
      );
      expect(tombstone.isStructurallyValid, isTrue);
      expect(
        SpacePostCleartext.decode(
          const SpacePostCleartext(
            title: '',
            body: '',
            isTombstone: true,
          ).encode(),
        )?.isTombstone,
        isTrue,
      );
    },
  );

  test('V8 tombstone AEAD binds operation and target sequence', () async {
    final key = Uint8List(32);
    final clear = const SpacePostCleartext(
      title: '',
      body: '',
      isTombstone: true,
    ).encode();
    final encrypted = await encryptSpacePostPayload(
      spaceId: _id(3),
      membershipEpoch: 1,
      author: _id(1),
      seq: 2,
      prevHash: 'b' * 64,
      postType: SpacePostType.post.name,
      visibility: SpacePostVisibility.members.name,
      policyVersion: 0,
      createdAtMs: 2,
      publishedAtMs: 2,
      controlCheckpointHash: 'a' * 64,
      postOperation: SpacePostOperation.delete.name,
      targetSeq: 0,
      clearText: clear,
      epochKey: key,
      random: Random(4),
    );
    final opened = await decryptSpacePostPayload(
      spaceId: _id(3),
      membershipEpoch: 1,
      author: _id(1),
      seq: 2,
      prevHash: 'b' * 64,
      postType: SpacePostType.post.name,
      visibility: SpacePostVisibility.members.name,
      policyVersion: 0,
      createdAtMs: 2,
      publishedAtMs: 2,
      controlCheckpointHash: 'a' * 64,
      postOperation: SpacePostOperation.delete.name,
      targetSeq: 0,
      payload: encrypted,
      epochKey: key,
    );
    expect(SpacePostCleartext.decode(opened)?.isTombstone, isTrue);
    await expectLater(
      decryptSpacePostPayload(
        spaceId: _id(3),
        membershipEpoch: 1,
        author: _id(1),
        seq: 2,
        prevHash: 'b' * 64,
        postType: SpacePostType.post.name,
        visibility: SpacePostVisibility.members.name,
        policyVersion: 0,
        createdAtMs: 2,
        publishedAtMs: 2,
        controlCheckpointHash: 'a' * 64,
        postOperation: SpacePostOperation.edit.name,
        targetSeq: 0,
        payload: encrypted,
        epochKey: key,
      ),
      throwsFormatException,
    );
  });

  test('feed cursor round-trips every deterministic tie-breaker', () {
    final cursor = SpaceFeedCursor(
      publishedAtMs: 123,
      spaceId: _id(7),
      author: _id(8),
      seq: 9,
    );
    final decoded = SpaceFeedCursor.decode(cursor.encode());
    expect(decoded, isNotNull);
    expect(decoded!.compareTo(cursor), 0);
    expect(SpaceFeedCursor.decode('not a cursor'), isNull);
  });

  test('local SpaceSubscription is separate from membership authority', () {
    final value = SpaceSubscription.memberDefault(_id(9)).copyWith(
      feedEnabled: false,
      notificationsEnabled: false,
      commentNotifications: SpaceCommentNotificationMode.all,
      hiddenFromRecommendations: true,
      updatedAtMs: 42,
    );
    final decoded = SpaceSubscription.fromJson(value.toJson(), _id(9));
    expect(decoded, isNotNull);
    expect(decoded!.feedEnabled, isFalse);
    expect(decoded.notificationsEnabled, isFalse);
    expect(decoded.commentNotifications, SpaceCommentNotificationMode.all);
    expect(decoded.hiddenFromRecommendations, isTrue);
    expect(decoded.publicOnly, isFalse);
    expect(
      SpaceSubscription.fromJson(value.toJson(), _id(10)),
      isNull,
      reason: 'a copied preference cannot retarget another Space',
    );

    final legacy = Map<String, dynamic>.of(value.toJson())
      ..remove('commentNotifications');
    expect(
      SpaceSubscription.fromJson(legacy, _id(9))!.commentNotifications,
      SpaceCommentNotificationMode.none,
      reason: 'a legacy all-notifications opt-out must remain silent',
    );
  });
}
