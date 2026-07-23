import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/space_public_feed.dart';
import 'package:xveil/domain/space_public_feed_transport.dart';
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
    policyVersion: 0,
    createdAtMs: 1000 + seq,
    publishedAtMs: 1000 + seq,
    version: operation == SpacePostOperation.publish ? 5 : 7,
    controlCheckpointHash: '11' * 32,
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
  );
  final manifest = unsigned.withSignature(
    _signature(owner, owner.bytes, unsigned.canonicalBytes()),
  );
  return SpacePublicFeedProjection(manifest: manifest, pages: pages);
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
