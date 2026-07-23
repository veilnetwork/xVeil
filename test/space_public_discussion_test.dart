import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/media_object.dart';
import 'package:xveil/domain/space_public_discussion.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

Uint8List _signature(NodeId signer, Uint8List publicKey, Uint8List message) =>
    Uint8List.fromList(
      crypto.sha512.convert([...signer.bytes, ...publicKey, ...message]).bytes,
    );

bool _verifyDetached({
  required NodeId signer,
  required Uint8List publicKey,
  required Uint8List message,
  required Uint8List signature,
}) =>
    publicKey.length == 32 &&
    _same(signature, _signature(signer, publicKey, message));

SpacePublicComment _comment({
  required NodeId space,
  required String postId,
  required NodeId author,
  required int seq,
  required SpacePublicCommentOperation operation,
  required String body,
  SpacePublicComment? previous,
  int? targetSeq,
  String? replyTo,
  MediaObject? media,
  int? createdAtMs,
}) {
  final unsigned = SpacePublicComment(
    spaceId: space,
    postId: postId,
    author: author,
    seq: seq,
    prevHash: previous?.recordHash ?? '',
    operation: operation,
    targetSeq: targetSeq,
    body: body,
    replyTo: replyTo,
    media: media,
    lifecycleGeneration: 'aa' * 32,
    createdAtMs: createdAtMs ?? 1000 + seq,
    signature: Uint8List(0),
    authorPubKey: Uint8List(0),
  );
  return unsigned.withSignature(
    _signature(author, author.bytes, unsigned.canonicalBytes()),
    author.bytes,
  );
}

SpacePublicReaction _reaction({
  required NodeId space,
  required String postId,
  required NodeId author,
  required int seq,
  required String emoji,
  SpacePublicReaction? previous,
}) {
  final unsigned = SpacePublicReaction(
    spaceId: space,
    postId: postId,
    author: author,
    seq: seq,
    prevHash: previous?.recordHash ?? '',
    emoji: emoji,
    lifecycleGeneration: 'bb' * 32,
    createdAtMs: 2000 + seq,
    signature: Uint8List(0),
    authorPubKey: Uint8List(0),
  );
  return unsigned.withSignature(
    _signature(author, author.bytes, unsigned.canonicalBytes()),
    author.bytes,
  );
}

void main() {
  test('folds signed roots, edits and replies without owner attribution', () {
    final space = _id(1);
    final postId = '${_id(2).hex}:7';
    final firstAuthor = _id(3);
    final secondAuthor = _id(4);
    final root = _comment(
      space: space,
      postId: postId,
      author: firstAuthor,
      seq: 0,
      operation: SpacePublicCommentOperation.create,
      body: 'Original',
    );
    final edit = _comment(
      space: space,
      postId: postId,
      author: firstAuthor,
      seq: 1,
      previous: root,
      operation: SpacePublicCommentOperation.edit,
      targetSeq: 0,
      body: 'Edited',
    );
    final reply = _comment(
      space: space,
      postId: postId,
      author: secondAuthor,
      seq: 0,
      operation: SpacePublicCommentOperation.create,
      body: 'Reply',
      replyTo: root.ref,
      createdAtMs: 3000,
    );

    final views = foldSpacePublicComments(
      comments: [reply, edit, root],
      spaceId: space,
      postId: postId,
      verifySignature: _verifyDetached,
    );

    expect(views, hasLength(2));
    expect(views.first.ref, root.ref);
    expect(views.first.body, 'Edited');
    expect(views.first.edited, isTrue);
    expect(views.last.replyTo, root.ref);
    expect(
      SpacePublicComment.fromBytes(root.toBytes())?.toJson(),
      root.toJson(),
    );
  });

  test(
    'strict parser and signature reject injection and attribution changes',
    () {
      final space = _id(5);
      final postId = '${_id(6).hex}:0';
      final author = _id(7);
      final root = _comment(
        space: space,
        postId: postId,
        author: author,
        seq: 0,
        operation: SpacePublicCommentOperation.create,
        body: 'Public by explicit signature',
      );

      final injected = root.toJson()..['membershipEpoch'] = 8;
      expect(SpacePublicComment.fromJson(injected), isNull);
      final nullOptional = root.toJson()..['target'] = null;
      expect(SpacePublicComment.fromJson(nullOptional), isNull);
      final invalidMedia = root.toJson()
        ..['media'] = {'kind': 'image', 'contentId': 'not-a-content-id'};
      expect(SpacePublicComment.fromJson(invalidMedia), isNull);

      final tampered = root.toJson()..['body'] = 'Changed by the publisher';
      final decodedTamper = SpacePublicComment.fromJson(tampered);
      expect(decodedTamper, isNotNull);
      expect(decodedTamper!.verify(_verifyDetached), isFalse);

      final reassigned = root.toJson()..['author'] = _id(8).hex;
      final decodedReassigned = SpacePublicComment.fromJson(reassigned);
      expect(decodedReassigned, isNotNull);
      expect(decodedReassigned!.verify(_verifyDetached), isFalse);

      final wrongPost = SpacePublicComment.fromJson(
        jsonDecode(jsonEncode(root.toJson())),
      )!;
      expect(
        foldSpacePublicComments(
          comments: [wrongPost],
          spaceId: space,
          postId: '${_id(6).hex}:1',
          verifySignature: _verifyDetached,
        ),
        isEmpty,
      );
    },
  );

  test('forks fail closed per author and delete removes only its root', () {
    final space = _id(9);
    final postId = '${_id(10).hex}:2';
    final forkedAuthor = _id(11);
    final stableAuthor = _id(12);
    final forkRoot = _comment(
      space: space,
      postId: postId,
      author: forkedAuthor,
      seq: 0,
      operation: SpacePublicCommentOperation.create,
      body: 'Forked root',
    );
    final forkA = _comment(
      space: space,
      postId: postId,
      author: forkedAuthor,
      seq: 1,
      previous: forkRoot,
      operation: SpacePublicCommentOperation.edit,
      targetSeq: 0,
      body: 'A',
    );
    final forkB = _comment(
      space: space,
      postId: postId,
      author: forkedAuthor,
      seq: 1,
      previous: forkRoot,
      operation: SpacePublicCommentOperation.edit,
      targetSeq: 0,
      body: 'B',
    );
    final stableRoot = _comment(
      space: space,
      postId: postId,
      author: stableAuthor,
      seq: 0,
      operation: SpacePublicCommentOperation.create,
      body: 'Stable root',
    );
    final deletion = _comment(
      space: space,
      postId: postId,
      author: stableAuthor,
      seq: 1,
      previous: stableRoot,
      operation: SpacePublicCommentOperation.delete,
      targetSeq: 0,
      body: '',
    );

    expect(
      foldSpacePublicComments(
        comments: [forkRoot, forkA, forkB, stableRoot],
        spaceId: space,
        postId: postId,
        verifySignature: _verifyDetached,
      ).map((comment) => comment.ref),
      [stableRoot.ref],
    );
    expect(
      foldSpacePublicComments(
        comments: [stableRoot, deletion],
        spaceId: space,
        postId: postId,
        verifySignature: _verifyDetached,
      ),
      isEmpty,
    );
  });

  test('media-only root stays valid and an invalid reply is omitted', () {
    final space = _id(13);
    final postId = '${_id(14).hex}:0';
    final mediaRoot = _comment(
      space: space,
      postId: postId,
      author: _id(15),
      seq: 0,
      operation: SpacePublicCommentOperation.create,
      body: '',
      media: const MediaObject(
        kind: 'image',
        contentId:
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      ),
    );
    final orphan = _comment(
      space: space,
      postId: postId,
      author: _id(16),
      seq: 0,
      operation: SpacePublicCommentOperation.create,
      body: 'Orphan',
      replyTo: '${_id(17).hex}:0',
    );

    final views = foldSpacePublicComments(
      comments: [orphan, mediaRoot],
      spaceId: space,
      postId: postId,
      verifySignature: _verifyDetached,
    );
    expect(views, hasLength(1));
    expect(views.single.ref, mediaRoot.ref);
    expect(views.single.media?.contentId, 'c' * 64);
  });

  test('reaction chain exposes only terminal verified state', () {
    final space = _id(18);
    final postId = '${_id(19).hex}:3';
    final removedAuthor = _id(20);
    final activeAuthor = _id(21);
    final added = _reaction(
      space: space,
      postId: postId,
      author: removedAuthor,
      seq: 0,
      emoji: '👍',
    );
    final removed = _reaction(
      space: space,
      postId: postId,
      author: removedAuthor,
      seq: 1,
      previous: added,
      emoji: '',
    );
    final active = _reaction(
      space: space,
      postId: postId,
      author: activeAuthor,
      seq: 0,
      emoji: '👍',
    );

    expect(
      foldSpacePublicReactions(
        reactions: [removed, active, added],
        spaceId: space,
        postId: postId,
        verifySignature: _verifyDetached,
      ),
      {
        '👍': [activeAuthor],
      },
    );
    expect(
      SpacePublicReaction.fromBytes(active.toBytes())?.toJson(),
      active.toJson(),
    );
    final injected = active.toJson()..['epoch'] = 2;
    expect(SpacePublicReaction.fromJson(injected), isNull);
  });

  test('reaction fork rejects only the forked author', () {
    final space = _id(22);
    final postId = '${_id(23).hex}:0';
    final forkedAuthor = _id(24);
    final root = _reaction(
      space: space,
      postId: postId,
      author: forkedAuthor,
      seq: 0,
      emoji: '🔥',
    );
    final forkA = _reaction(
      space: space,
      postId: postId,
      author: forkedAuthor,
      seq: 1,
      previous: root,
      emoji: '👍',
    );
    final forkB = _reaction(
      space: space,
      postId: postId,
      author: forkedAuthor,
      seq: 1,
      previous: root,
      emoji: '👎',
    );

    expect(
      foldSpacePublicReactions(
        reactions: [root, forkA, forkB],
        spaceId: space,
        postId: postId,
        verifySignature: _verifyDetached,
      ),
      isEmpty,
    );
  });
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
