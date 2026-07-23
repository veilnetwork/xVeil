import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/space_discovery.dart';
import 'package:xveil/domain/space_join_request.dart';
import 'package:xveil/domain/space_public_feed.dart';
import 'package:xveil/domain/space_public_feed_transport.dart';
import 'package:xveil/domain/space_public_discussion.dart';
import 'package:xveil/domain/space_post.dart';

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

SpacePost _signedPost({
  required NodeId space,
  required NodeId author,
  required int seq,
  required String body,
  SpacePostOperation operation = SpacePostOperation.publish,
  int? targetSeq,
  String prevHash = '',
  List<MediaObject> media = const [],
  String? lifecycleGeneration,
}) {
  final unsigned = SpacePost(
    spaceId: space,
    author: author,
    seq: seq,
    prevHash: prevHash,
    type: SpacePostType.post,
    visibility: SpacePostVisibility.public,
    title: '',
    body: body,
    media: media,
    policyVersion: 0,
    createdAtMs: 1000 + seq,
    publishedAtMs: 1000 + seq,
    version: lifecycleGeneration != null
        ? 9
        : operation == SpacePostOperation.publish
        ? 5
        : 7,
    controlCheckpointHash: '11' * 32,
    lifecycleGeneration: lifecycleGeneration,
    operation: operation,
    targetSeq: targetSeq,
    signature: Uint8List(0),
  );
  return unsigned.withSignature(
    _signature(author, author.bytes, unsigned.canonicalBytes()),
    author.bytes,
  );
}

bool _verifyPost(SpacePost post) => _verifyDetached(
  signer: post.author,
  publicKey: post.authorPubKey,
  message: post.canonicalBytes(),
  signature: post.signature,
);

SpacePublicFeedProjection _projection({
  required NodeId space,
  required NodeId owner,
  required List<SpacePublicPostProjection> posts,
  List<SpacePublicDiscussionPage> discussionPages = const [],
  int revision = 1,
}) {
  final pages = posts.isEmpty
      ? const <SpacePublicFeedPage>[]
      : [SpacePublicFeedPage(spaceId: space, index: 0, posts: posts)];
  final unsigned = SpacePublicFeedManifest(
    spaceId: space,
    publisher: owner,
    controlHeadHash: '22' * 32,
    revision: revision,
    updatedAtMs: 1000,
    issuedAtMs: 2000,
    expiresAtMs: 3000,
    itemCount: posts.length,
    pageHashes: [for (final page in pages) page.contentHash],
    wireVersion: discussionPages.isEmpty
        ? SpacePublicFeedManifest.version
        : SpacePublicFeedManifest.discussionVersion,
    discussionItemCount: discussionPages.fold(
      0,
      (total, page) => total + page.itemCount,
    ),
    discussionPageHashes: [
      for (final page in discussionPages) page.contentHash,
    ],
  );
  final manifest = unsigned.withSignature(
    _signature(owner, owner.bytes, unsigned.canonicalBytes()),
  );
  return SpacePublicFeedProjection(
    manifest: manifest,
    pages: pages,
    discussionPages: discussionPages,
  );
}

SpacePublicComment _signedComment({
  required NodeId space,
  required String postId,
  required NodeId author,
  required String lifecycle,
  required String body,
  MediaObject? media,
}) {
  final unsigned = SpacePublicComment(
    spaceId: space,
    postId: postId,
    author: author,
    seq: 0,
    prevHash: '',
    operation: SpacePublicCommentOperation.create,
    body: body,
    media: media,
    lifecycleGeneration: lifecycle,
    createdAtMs: 1200,
    signature: Uint8List(0),
    authorPubKey: Uint8List(0),
  );
  return unsigned.withSignature(
    _signature(author, author.bytes, unsigned.canonicalBytes()),
    author.bytes,
  );
}

SpacePublicReaction _signedReaction({
  required NodeId space,
  required String postId,
  required NodeId author,
  required String lifecycle,
  required String emoji,
}) {
  final unsigned = SpacePublicReaction(
    spaceId: space,
    postId: postId,
    author: author,
    seq: 0,
    prevHash: '',
    emoji: emoji,
    lifecycleGeneration: lifecycle,
    createdAtMs: 1300,
    signature: Uint8List(0),
    authorPubKey: Uint8List(0),
  );
  return unsigned.withSignature(
    _signature(author, author.bytes, unsigned.canonicalBytes()),
    author.bytes,
  );
}

SpacePublicFeedPackage _package({
  required NodeId space,
  required NodeId owner,
  required SpacePublicFeedProjection projection,
}) {
  final unsignedGenesis = SpaceManifest.space(
    spaceId: space,
    owner: owner,
    genesisPubKey: owner.bytes,
    name: 'Stored public Space',
    description: 'Only the signed public projection is retained.',
    visibility: SpaceVisibility.public,
    discoverable: true,
    createdAtMs: 1000,
  );
  final genesis = unsignedGenesis.withSignature(
    _signature(owner, owner.bytes, unsignedGenesis.canonicalBytes()),
  );
  final ticket = SpaceJoinTicket(
    ticketId: '77' * 32,
    spaceId: space,
    approver: owner,
    spaceName: 'Stored public Space',
    createdAtMs: 1000,
    expiresAtMs: 3000,
  );
  final unsignedDescriptor = SpacePublicDescriptor(
    spaceId: space,
    publisher: owner,
    genesisManifest: genesis,
    controlHeadHash: projection.manifest.controlHeadHash,
    revision: projection.manifest.revision,
    publicFeedManifestHash: projection.manifest.manifestHash,
    publicFeedRevision: projection.manifest.revision,
    publicFeedUpdatedAtMs: projection.manifest.updatedAtMs,
    publicPostCount: projection.manifest.itemCount,
    name: 'Stored public Space',
    description: 'Only the signed public projection is retained.',
    avatarContentId: null,
    coverContentId: null,
    createdAtMs: 1000,
    updatedAtMs: 1900,
    issuedAtMs: 2000,
    expiresAtMs: 3000,
    joinCode: SpaceJoinCode.encode(ticket),
  );
  final descriptor = unsignedDescriptor.withSignature(
    _signature(owner, owner.bytes, unsignedDescriptor.canonicalBytes()),
  );
  return SpacePublicFeedPackage(descriptor: descriptor, projection: projection);
}

void main() {
  test('owner manifest commits exact author-signed publish/edit view', () {
    final space = _id(1);
    final owner = _id(2);
    final author = _id(3);
    final root = _signedPost(
      space: space,
      author: author,
      seq: 0,
      body: 'Original',
    );
    final edit = _signedPost(
      space: space,
      author: author,
      seq: 1,
      body: 'Edited',
      operation: SpacePostOperation.edit,
      targetSeq: 0,
      prevHash: '33' * 32,
    );
    final projected = SpacePublicPostProjection(
      root: root,
      effective: edit,
      pinned: true,
      pinnedAtMs: 1500,
      mediaHiddenByRetention: false,
    );
    final projection = _projection(
      space: space,
      owner: owner,
      posts: [projected],
      revision: 2,
    );

    expect(
      projection.verifyAt(
        nowMs: 2500,
        expectedManifestHash: projection.manifest.manifestHash,
        expectedSpaceId: space,
        expectedPublisher: owner,
        publisherPublicKey: owner.bytes,
        expectedControlHeadHash: '22' * 32,
        verifySignature: _verifyDetached,
        verifyPost: _verifyPost,
      ),
      isTrue,
    );
    expect(projection.posts.single.postId, root.postId);
    expect(projection.posts.single.body, 'Edited');

    final pageWire = projection.pages.single.canonicalBytes();
    final decoded = SpacePublicFeedPage.fromBytes(pageWire);
    expect(decoded?.toJson(), projection.pages.single.toJson());
    expect(
      SpacePublicFeedManifest.fromJson(
        jsonDecode(jsonEncode(projection.manifest.toJson())),
      )?.toJson(),
      projection.manifest.toJson(),
    );
  });

  test(
    'public boundary rejects private fields, tampering and delete-as-view',
    () {
      final space = _id(4);
      final owner = _id(5);
      final author = _id(6);
      final root = _signedPost(
        space: space,
        author: author,
        seq: 0,
        body: 'Public',
      );
      final projected = SpacePublicPostProjection(
        root: root,
        effective: root,
        pinned: false,
        mediaHiddenByRetention: false,
      );
      final projection = _projection(
        space: space,
        owner: owner,
        posts: [projected],
      );

      final injectedPage = projection.pages.single.toJson()
        ..['comments'] = [
          {'membershipEpoch': 7},
        ];
      expect(SpacePublicFeedPage.fromJson(injectedPage), isNull);

      final nestedInjection = projection.pages.single.toJson();
      ((nestedInjection['posts'] as List).single as Map)['reactions'] = [];
      expect(SpacePublicFeedPage.fromJson(nestedInjection), isNull);

      final tamperedPage = projection.pages.single.toJson();
      final tamperedRoot =
          (((tamperedPage['posts'] as List).single as Map)['root'] as Map);
      tamperedRoot['body'] = 'Changed without the author';
      final tamperedEffective =
          (((tamperedPage['posts'] as List).single as Map)['effective'] as Map);
      tamperedEffective['body'] = 'Changed without the author';
      final decodedTamper = SpacePublicFeedPage.fromJson(tamperedPage);
      expect(decodedTamper, isNotNull);
      expect(
        decodedTamper!.verify(
          expectedHash: decodedTamper.contentHash,
          verifyPost: _verifyPost,
        ),
        isFalse,
      );

      final deletion = _signedPost(
        space: space,
        author: author,
        seq: 1,
        body: '',
        operation: SpacePostOperation.delete,
        targetSeq: 0,
        prevHash: '44' * 32,
      );
      expect(
        SpacePublicPostProjection(
          root: root,
          effective: deletion,
          pinned: false,
          mediaHiddenByRetention: false,
        ).isStructurallyValid,
        isFalse,
        reason:
            'a deletion is represented by absence from the committed snapshot, '
            'not by rendering a tombstone as current content',
      );
    },
  );

  test('page splice and stale manifest hash fail closed', () {
    final space = _id(7);
    final owner = _id(8);
    final root = _signedPost(space: space, author: owner, seq: 0, body: 'One');
    final projection = _projection(
      space: space,
      owner: owner,
      posts: [
        SpacePublicPostProjection(
          root: root,
          effective: root,
          pinned: false,
          mediaHiddenByRetention: false,
        ),
      ],
    );

    expect(
      projection.verifyAt(
        nowMs: 2500,
        expectedManifestHash: 'ff' * 32,
        expectedSpaceId: space,
        expectedPublisher: owner,
        publisherPublicKey: owner.bytes,
        expectedControlHeadHash: '22' * 32,
        verifySignature: _verifyDetached,
        verifyPost: _verifyPost,
      ),
      isFalse,
    );

    final wrongIndex = SpacePublicFeedPage(
      spaceId: space,
      index: 1,
      posts: projection.pages.single.posts,
    );
    final spliced = SpacePublicFeedProjection(
      manifest: projection.manifest,
      pages: [wrongIndex],
    );
    expect(
      spliced.verifyAt(
        nowMs: 2500,
        expectedManifestHash: projection.manifest.manifestHash,
        expectedSpaceId: space,
        expectedPublisher: owner,
        publisherPublicKey: owner.bytes,
        expectedControlHeadHash: '22' * 32,
        verifySignature: _verifyDetached,
        verifyPost: _verifyPost,
      ),
      isFalse,
    );
  });

  test('v2 manifest commits independently signed discussion pages', () {
    final space = _id(24);
    final owner = _id(25);
    final postAuthor = _id(26);
    final commenter = _id(27);
    final reactor = _id(28);
    final lifecycle = 'cc' * 32;
    final root = _signedPost(
      space: space,
      author: postAuthor,
      seq: 0,
      body: 'Discussable',
      lifecycleGeneration: lifecycle,
    );
    final comment = _signedComment(
      space: space,
      postId: root.postId,
      author: commenter,
      lifecycle: lifecycle,
      body: 'Author signed',
      media: MediaObject(kind: 'image', contentId: 'ab' * 32),
    );
    final reaction = _signedReaction(
      space: space,
      postId: root.postId,
      author: reactor,
      lifecycle: lifecycle,
      emoji: '👍',
    );
    final discussionPage = SpacePublicDiscussionPage(
      spaceId: space,
      index: 0,
      comments: [comment],
      reactions: [reaction],
    );
    final projection = _projection(
      space: space,
      owner: owner,
      posts: [
        SpacePublicPostProjection(
          root: root,
          effective: root,
          pinned: false,
          mediaHiddenByRetention: false,
        ),
      ],
      discussionPages: [discussionPage],
      revision: 3,
    );

    expect(projection.manifest.wireVersion, 2);
    expect(
      projection.verifyAt(
        nowMs: 2500,
        expectedManifestHash: projection.manifest.manifestHash,
        expectedSpaceId: space,
        expectedPublisher: owner,
        publisherPublicKey: owner.bytes,
        expectedControlHeadHash: '22' * 32,
        verifySignature: _verifyDetached,
        verifyPost: _verifyPost,
      ),
      isTrue,
    );
    expect(
      projection.commentsFor(root.postId, _verifyDetached).single.body,
      'Author signed',
    );
    expect(projection.reactionsFor(root.postId, _verifyDetached), {
      '👍': [reactor],
    });
    expect(projection.referencedContentIds, {'ab' * 32});

    final package = _package(
      space: space,
      owner: owner,
      projection: projection,
    );
    final decoded = SpacePublicFeedPackage.fromBytes(package.toBytes());
    expect(decoded, isNotNull);
    expect(
      decoded!.verifyAt(
        nowMs: 2500,
        verifySignature: _verifyDetached,
        verifyPost: _verifyPost,
      ),
      isTrue,
    );

    final tampered = package.toJson();
    final discussionPages = tampered['discussionPages'] as List;
    final comments = ((discussionPages.single as Map)['comments'] as List);
    (comments.single as Map)['body'] = 'Publisher rewrite';
    final decodedTamper = SpacePublicFeedPackage.fromJson(tampered);
    expect(decodedTamper, isNotNull);
    expect(
      decodedTamper!.verifyAt(
        nowMs: 2500,
        verifySignature: _verifyDetached,
        verifyPost: _verifyPost,
      ),
      isFalse,
    );
  });

  test('discussion records cannot cross a post lifecycle boundary', () {
    final space = _id(29);
    final owner = _id(30);
    final author = _id(31);
    final root = _signedPost(
      space: space,
      author: author,
      seq: 0,
      body: 'Restored generation',
      lifecycleGeneration: 'dd' * 32,
    );
    final stale = _signedComment(
      space: space,
      postId: root.postId,
      author: _id(32),
      lifecycle: 'ee' * 32,
      body: 'Stale generation',
    );
    final page = SpacePublicDiscussionPage(
      spaceId: space,
      index: 0,
      comments: [stale],
      reactions: const [],
    );
    final projection = _projection(
      space: space,
      owner: owner,
      posts: [
        SpacePublicPostProjection(
          root: root,
          effective: root,
          pinned: false,
          mediaHiddenByRetention: false,
        ),
      ],
      discussionPages: [page],
    );

    expect(
      projection.verifyAt(
        nowMs: 2500,
        expectedManifestHash: projection.manifest.manifestHash,
        expectedSpaceId: space,
        expectedPublisher: owner,
        publisherPublicKey: owner.bytes,
        expectedControlHeadHash: '22' * 32,
        verifySignature: _verifyDetached,
        verifyPost: _verifyPost,
      ),
      isFalse,
    );
  });

  test('retention-hidden media is absent from the public grant allowlist', () {
    final space = _id(15);
    final owner = _id(16);
    final root = _signedPost(
      space: space,
      author: owner,
      seq: 0,
      body: 'Text remains',
      media: [
        const MediaObject(
          kind: 'image',
          contentId:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      ],
    );
    final visible = _projection(
      space: space,
      owner: owner,
      posts: [
        SpacePublicPostProjection(
          root: root,
          effective: root,
          pinned: false,
          mediaHiddenByRetention: false,
        ),
      ],
    );
    final hidden = _projection(
      space: space,
      owner: owner,
      posts: [
        SpacePublicPostProjection(
          root: root,
          effective: root,
          pinned: false,
          mediaHiddenByRetention: true,
        ),
      ],
    );

    expect(visible.referencedContentIds, {'a' * 64});
    expect(hidden.referencedContentIds, isEmpty);
    expect(hidden.posts.single.body, 'Text remains');
  });

  test(
    'subscription snapshot proves fetch-time validity and stays readable offline',
    () {
      final space = _id(17);
      final owner = _id(18);
      final root = _signedPost(
        space: space,
        author: owner,
        seq: 0,
        body: 'Verified while online',
      );
      final projection = _projection(
        space: space,
        owner: owner,
        posts: [
          SpacePublicPostProjection(
            root: root,
            effective: root,
            pinned: false,
            mediaHiddenByRetention: false,
          ),
        ],
      );
      final snapshot = SpacePublicSubscriptionSnapshot(
        verifiedAtMs: 2500,
        package: _package(space: space, owner: owner, projection: projection),
      );

      expect(
        snapshot.verifyStored(
          verifySignature: _verifyDetached,
          verifyPost: _verifyPost,
        ),
        isTrue,
      );
      expect(snapshot.isStaleAt(2999), isFalse);
      expect(snapshot.isStaleAt(3000), isTrue);
      final decoded = SpacePublicSubscriptionSnapshot.fromBytes(
        snapshot.toBytes(),
      );
      expect(decoded, isNotNull);
      expect(
        decoded!.verifyStored(
          verifySignature: _verifyDetached,
          verifyPost: _verifyPost,
        ),
        isTrue,
        reason:
            'expiry blocks refresh/availability, not a previously verified '
            'offline publication',
      );

      final injected = snapshot.toJson()..['members'] = [owner.hex];
      expect(SpacePublicSubscriptionSnapshot.fromJson(injected), isNull);
      final tampered = snapshot.toJson();
      final package = tampered['package'] as Map;
      final pages = package['pages'] as List;
      final post = ((pages.single as Map)['posts'] as List).single as Map;
      (post['root'] as Map)['body'] = 'unsigned replacement';
      (post['effective'] as Map)['body'] = 'unsigned replacement';
      final decodedTamper = SpacePublicSubscriptionSnapshot.fromJson(tampered);
      expect(decodedTamper, isNotNull);
      expect(
        decodedTamper!.verifyStored(
          verifySignature: _verifyDetached,
          verifyPost: _verifyPost,
        ),
        isFalse,
      );
    },
  );

  test('object request is signed, source-bound, fresh and strictly parsed', () {
    const now = 5000;
    final requester = _id(9);
    final unsigned = SpacePublicFeedObjectRequest(
      spaceId: _id(10),
      descriptorHash: '11' * 32,
      manifestHash: '22' * 32,
      objectHash: '33' * 32,
      requester: requester,
      requesterPublicKey: requester.bytes,
      nonce: '44' * 32,
      createdAtMs: now,
    );
    final request = unsigned.withSignature(
      _signature(requester, requester.bytes, unsigned.canonicalBytes()),
    );

    expect(request.verifyAt(now, requester, _verifyDetached), isTrue);
    expect(request.verifyAt(now, _id(11), _verifyDetached), isFalse);
    expect(
      request.verifyAt(
        now + kSpacePublicFeedRequestWindow.inMilliseconds + 1,
        requester,
        _verifyDetached,
      ),
      isFalse,
    );
    expect(
      SpacePublicFeedObjectRequest.fromJson(
        jsonDecode(jsonEncode(request.toJson())),
      )?.toJson(),
      request.toJson(),
    );
    final injected = request.toJson()..['page'] = {'privateEpoch': 2};
    expect(SpacePublicFeedObjectRequest.fromJson(injected), isNull);
  });

  test(
    'public media grant request binds source, feed revision and exact CID',
    () {
      const now = 6000;
      final requester = _id(12);
      final unsigned = SpacePublicMediaGrantRequest(
        spaceId: _id(13),
        descriptorHash: '11' * 32,
        manifestHash: '22' * 32,
        contentId: '33' * 32,
        requester: requester,
        requesterPublicKey: requester.bytes,
        nonce: '44' * 32,
        createdAtMs: now,
      );
      final request = unsigned.withSignature(
        _signature(requester, requester.bytes, unsigned.canonicalBytes()),
      );

      expect(request.verifyAt(now, requester, _verifyDetached), isTrue);
      expect(request.verifyAt(now, _id(14), _verifyDetached), isFalse);
      expect(
        request.verifyAt(
          now + kSpacePublicMediaGrantRequestWindow.inMilliseconds + 1,
          requester,
          _verifyDetached,
        ),
        isFalse,
      );
      expect(
        SpacePublicMediaGrantRequest.fromJson(
          jsonDecode(jsonEncode(request.toJson())),
        )?.toJson(),
        request.toJson(),
      );
      final changedCid = request.toJson()..['contentId'] = '55' * 32;
      final decodedChanged = SpacePublicMediaGrantRequest.fromJson(changedCid);
      expect(decodedChanged, isNotNull);
      expect(
        decodedChanged!.verifyAt(now, requester, _verifyDetached),
        isFalse,
      );
      final injected = request.toJson()..['channelEpoch'] = 7;
      expect(SpacePublicMediaGrantRequest.fromJson(injected), isNull);
    },
  );

  test('object chunks are bounded, exact and losslessly reassembled', () {
    final bytes = Uint8List.fromList(
      List<int>.generate(5000, (index) => index & 0xff),
    );
    final chunks = chunkSpacePublicFeedObject(
      spaceId: _id(12),
      manifestHash: '55' * 32,
      objectHash: '66' * 32,
      nonce: '77' * 32,
      bytes: bytes,
    ).toList();
    expect(chunks, hasLength(3));
    expect(chunks.every((chunk) => chunk.isStructurallyValid), isTrue);
    final joined = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      final decoded = SpacePublicFeedObjectChunk.fromJson(
        jsonDecode(jsonEncode(chunk.toJson())),
      );
      expect(decoded, isNotNull);
      joined.add(decoded!.data);
    }
    expect(joined.toBytes(), bytes);

    final malformed = chunks.last.toJson()..['totalBytes'] = 4999;
    expect(SpacePublicFeedObjectChunk.fromJson(malformed), isNull);
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
