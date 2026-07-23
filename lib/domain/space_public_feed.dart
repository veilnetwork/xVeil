import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import 'space_discovery.dart'
    show
        SpacePublicSignatureVerifier,
        kSpacePublicClockSkew,
        kSpacePublicDescriptorLifetime;
import 'space_post.dart';

const int kSpacePublicFeedPageSize = 32;
const int kSpacePublicFeedPageMaxBytes = 1024 * 1024;
const int kSpacePublicFeedPageMaxCount = 4096;

final RegExp _publicFeedHashPattern = RegExp(r'^[0-9a-f]{64}$');

typedef SpacePublicPostVerifier = bool Function(SpacePost post);

/// One already-authorized public publication view.
///
/// The exact author-signed root and latest author-signed edit are retained;
/// the owner signature over [SpacePublicFeedManifest] only certifies that the
/// private control-log/lifecycle fold admitted this view. No control entry,
/// roster row, membership epoch, channel id, comment or reaction is copied to
/// this public boundary.
class SpacePublicPostProjection {
  const SpacePublicPostProjection({
    required this.root,
    required this.effective,
    required this.pinned,
    required this.mediaHiddenByRetention,
    this.pinnedAtMs,
  });

  factory SpacePublicPostProjection.fromView(SpacePostView view) =>
      SpacePublicPostProjection(
        root: view.root,
        effective: view.effective,
        pinned: view.pinned,
        pinnedAtMs: view.pinnedAtMs,
        mediaHiddenByRetention: view.mediaHiddenByRetention,
      );

  final SpacePost root;
  final SpacePost effective;
  final bool pinned;
  final int? pinnedAtMs;
  final bool mediaHiddenByRetention;

  bool get isStructurallyValid {
    if (root.visibility != SpacePostVisibility.public ||
        effective.visibility != SpacePostVisibility.public ||
        root.isEncrypted ||
        effective.isEncrypted ||
        root.operation != SpacePostOperation.publish ||
        root.spaceId != effective.spaceId ||
        root.author != effective.author ||
        root.lifecycleGeneration != effective.lifecycleGeneration ||
        (pinned ? pinnedAtMs == null || pinnedAtMs! < 0 : pinnedAtMs != null)) {
      return false;
    }
    final rootIsEffective =
        effective.seq == root.seq &&
        effective.operation == SpacePostOperation.publish &&
        _spacePostWireHash(effective) == _spacePostWireHash(root);
    final validEdit =
        effective.operation == SpacePostOperation.edit &&
        effective.targetSeq == root.seq &&
        effective.seq > root.seq;
    return (rootIsEffective || validEdit) &&
        root.isStructurallyValid &&
        effective.isStructurallyValid;
  }

  bool verify(SpacePublicPostVerifier verifyPost) =>
      isStructurallyValid &&
      verifyPost(root) &&
      (_spacePostWireHash(root) == _spacePostWireHash(effective) ||
          verifyPost(effective));

  SpacePostView toView() => SpacePostView(
    root: root,
    effective: effective,
    pinned: pinned,
    pinnedAtMs: pinnedAtMs,
    mediaHiddenByRetention: mediaHiddenByRetention,
  );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'root': root.toJson(),
    'effective': effective.toJson(),
    'pinned': pinned,
    if (pinnedAtMs != null) 'pinnedAt': pinnedAtMs,
    'mediaHidden': mediaHiddenByRetention,
  };

  static SpacePublicPostProjection? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'root',
          'effective',
          'pinned',
          'pinnedAt',
          'mediaHidden',
        }) ||
        value['v'] != 1 ||
        value['root'] is! Map ||
        value['effective'] is! Map ||
        value['pinned'] is! bool ||
        (value['pinnedAt'] != null && value['pinnedAt'] is! int) ||
        value['mediaHidden'] is! bool) {
      return null;
    }
    final root = _strictSpacePostFromJson(value['root']);
    final effective = _strictSpacePostFromJson(value['effective']);
    if (root == null || effective == null) return null;
    final projection = SpacePublicPostProjection(
      root: root,
      effective: effective,
      pinned: value['pinned'] as bool,
      pinnedAtMs: value['pinnedAt'] as int?,
      mediaHiddenByRetention: value['mediaHidden'] as bool,
    );
    return projection.isStructurallyValid ? projection : null;
  }
}

/// A bounded content-addressed page. Pages are not trusted independently:
/// their exact hashes and order are committed by the owner-signed manifest.
class SpacePublicFeedPage {
  SpacePublicFeedPage({
    required this.spaceId,
    required this.index,
    required Iterable<SpacePublicPostProjection> posts,
  }) : posts = List<SpacePublicPostProjection>.unmodifiable(posts);

  final NodeId spaceId;
  final int index;
  final List<SpacePublicPostProjection> posts;

  bool get isStructurallyValid =>
      index >= 0 &&
      posts.isNotEmpty &&
      posts.length <= kSpacePublicFeedPageSize &&
      posts.every(
        (post) => post.isStructurallyValid && post.root.spaceId == spaceId,
      ) &&
      canonicalBytes().length <= kSpacePublicFeedPageMaxBytes;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'kind': 'xveil.space.public-feed-page',
    'space': spaceId.hex,
    'index': index,
    'posts': [for (final post in posts) post.toJson()],
  };

  Uint8List canonicalBytes() =>
      Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  String get contentHash => crypto.sha256.convert(canonicalBytes()).toString();

  bool verify({
    required String expectedHash,
    required SpacePublicPostVerifier verifyPost,
  }) =>
      isStructurallyValid &&
      contentHash == expectedHash &&
      posts.every((post) => post.verify(verifyPost));

  static SpacePublicFeedPage? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {'v', 'kind', 'space', 'index', 'posts'}) ||
        value['v'] != 1 ||
        value['kind'] != 'xveil.space.public-feed-page' ||
        value['space'] is! String ||
        value['index'] is! int ||
        value['posts'] is! List) {
      return null;
    }
    final rawPosts = value['posts'] as List;
    if (rawPosts.isEmpty || rawPosts.length > kSpacePublicFeedPageSize) {
      return null;
    }
    final posts = rawPosts
        .map(SpacePublicPostProjection.fromJson)
        .whereType<SpacePublicPostProjection>()
        .toList(growable: false);
    if (posts.length != rawPosts.length) return null;
    try {
      final page = SpacePublicFeedPage(
        spaceId: NodeId.fromHex(value['space'] as String),
        index: value['index'] as int,
        posts: posts,
      );
      return page.isStructurallyValid ? page : null;
    } catch (_) {
      return null;
    }
  }

  static SpacePublicFeedPage? fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > kSpacePublicFeedPageMaxBytes) {
      return null;
    }
    try {
      return fromJson(jsonDecode(utf8.decode(bytes, allowMalformed: false)));
    } catch (_) {
      return null;
    }
  }
}

/// Owner-signed commitment to the complete current public publication view.
///
/// A descriptor commits [manifestHash], and this manifest commits every page.
/// Consequently a holder cannot replay a removed post, splice a private row or
/// claim availability for a partial snapshot without changing an owner-signed
/// hash.
class SpacePublicFeedManifest {
  SpacePublicFeedManifest({
    required this.spaceId,
    required this.publisher,
    required this.controlHeadHash,
    required this.revision,
    required this.updatedAtMs,
    required this.issuedAtMs,
    required this.expiresAtMs,
    required this.itemCount,
    required Iterable<String> pageHashes,
    Uint8List? signature,
  }) : pageHashes = List<String>.unmodifiable(pageHashes),
       signature = signature ?? Uint8List(0);

  static const int version = 1;
  static const String kind = 'xveil.space.public-feed';

  final NodeId spaceId;
  final NodeId publisher;
  final String controlHeadHash;
  final int revision;
  final int updatedAtMs;
  final int issuedAtMs;
  final int expiresAtMs;
  final int itemCount;
  final List<String> pageHashes;
  final Uint8List signature;

  bool isStructurallyValidAt(int nowMs) {
    if (!_publicFeedHashPattern.hasMatch(controlHeadHash) ||
        revision < 0 ||
        updatedAtMs < 0 ||
        issuedAtMs < updatedAtMs ||
        expiresAtMs <= issuedAtMs ||
        expiresAtMs - issuedAtMs >
            kSpacePublicDescriptorLifetime.inMilliseconds ||
        issuedAtMs > nowMs + kSpacePublicClockSkew.inMilliseconds ||
        expiresAtMs <= nowMs ||
        itemCount < 0 ||
        pageHashes.length > kSpacePublicFeedPageMaxCount ||
        signature.length != 64 ||
        pageHashes.any((hash) => !_publicFeedHashPattern.hasMatch(hash))) {
      return false;
    }
    if (itemCount == 0) return pageHashes.isEmpty;
    if (pageHashes.isEmpty ||
        itemCount > pageHashes.length * kSpacePublicFeedPageSize ||
        itemCount <= (pageHashes.length - 1) * kSpacePublicFeedPageSize) {
      return false;
    }
    return pageHashes.toSet().length == pageHashes.length;
  }

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': version,
        'kind': kind,
        'space': spaceId.hex,
        'publisher': publisher.hex,
        'controlHeadHash': controlHeadHash,
        'revision': revision,
        'updatedAt': updatedAtMs,
        'issuedAt': issuedAtMs,
        'expiresAt': expiresAtMs,
        'itemCount': itemCount,
        'pageHashes': pageHashes,
      }),
    ),
  );

  String get manifestHash {
    final bytes = BytesBuilder(copy: false)
      ..add(canonicalBytes())
      ..add(signature);
    return crypto.sha256.convert(bytes.toBytes()).toString();
  }

  bool verifyAt({
    required int nowMs,
    required NodeId expectedSpaceId,
    required NodeId expectedPublisher,
    required Uint8List publisherPublicKey,
    required SpacePublicSignatureVerifier verify,
  }) =>
      spaceId == expectedSpaceId &&
      publisher == expectedPublisher &&
      isStructurallyValidAt(nowMs) &&
      verify(
        signer: publisher,
        publicKey: publisherPublicKey,
        message: canonicalBytes(),
        signature: signature,
      );

  SpacePublicFeedManifest withSignature(Uint8List value) =>
      SpacePublicFeedManifest(
        spaceId: spaceId,
        publisher: publisher,
        controlHeadHash: controlHeadHash,
        revision: revision,
        updatedAtMs: updatedAtMs,
        issuedAtMs: issuedAtMs,
        expiresAtMs: expiresAtMs,
        itemCount: itemCount,
        pageHashes: pageHashes,
        signature: value,
      );

  Map<String, dynamic> toJson() => {
    ...jsonDecode(utf8.decode(canonicalBytes())) as Map<String, dynamic>,
    'signature': base64Encode(signature),
  };

  static SpacePublicFeedManifest? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'kind',
          'space',
          'publisher',
          'controlHeadHash',
          'revision',
          'updatedAt',
          'issuedAt',
          'expiresAt',
          'itemCount',
          'pageHashes',
          'signature',
        }) ||
        value['v'] != version ||
        value['kind'] != kind ||
        value['space'] is! String ||
        value['publisher'] is! String ||
        value['controlHeadHash'] is! String ||
        value['revision'] is! int ||
        value['updatedAt'] is! int ||
        value['issuedAt'] is! int ||
        value['expiresAt'] is! int ||
        value['itemCount'] is! int ||
        value['pageHashes'] is! List ||
        value['signature'] is! String) {
      return null;
    }
    final rawHashes = value['pageHashes'] as List;
    if (rawHashes.length > kSpacePublicFeedPageMaxCount ||
        rawHashes.any((hash) => hash is! String)) {
      return null;
    }
    try {
      return SpacePublicFeedManifest(
        spaceId: NodeId.fromHex(value['space'] as String),
        publisher: NodeId.fromHex(value['publisher'] as String),
        controlHeadHash: value['controlHeadHash'] as String,
        revision: value['revision'] as int,
        updatedAtMs: value['updatedAt'] as int,
        issuedAtMs: value['issuedAt'] as int,
        expiresAtMs: value['expiresAt'] as int,
        itemCount: value['itemCount'] as int,
        pageHashes: rawHashes.cast<String>(),
        signature: Uint8List.fromList(
          base64Decode(value['signature'] as String),
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

/// In-memory verified unit used by an owner or a replicated public holder.
class SpacePublicFeedProjection {
  SpacePublicFeedProjection({
    required this.manifest,
    required Iterable<SpacePublicFeedPage> pages,
  }) : pages = List<SpacePublicFeedPage>.unmodifiable(pages);

  final SpacePublicFeedManifest manifest;
  final List<SpacePublicFeedPage> pages;

  bool verifyAt({
    required int nowMs,
    required String expectedManifestHash,
    required NodeId expectedSpaceId,
    required NodeId expectedPublisher,
    required Uint8List publisherPublicKey,
    required String expectedControlHeadHash,
    required SpacePublicSignatureVerifier verifySignature,
    required SpacePublicPostVerifier verifyPost,
  }) {
    if (manifest.manifestHash != expectedManifestHash ||
        manifest.controlHeadHash != expectedControlHeadHash ||
        !manifest.verifyAt(
          nowMs: nowMs,
          expectedSpaceId: expectedSpaceId,
          expectedPublisher: expectedPublisher,
          publisherPublicKey: publisherPublicKey,
          verify: verifySignature,
        ) ||
        pages.length != manifest.pageHashes.length) {
      return false;
    }
    var itemCount = 0;
    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      if (page.index != index ||
          page.spaceId != expectedSpaceId ||
          !page.verify(
            expectedHash: manifest.pageHashes[index],
            verifyPost: verifyPost,
          )) {
        return false;
      }
      itemCount += page.posts.length;
    }
    return itemCount == manifest.itemCount;
  }

  List<SpacePostView> get posts => List<SpacePostView>.unmodifiable([
    for (final page in pages)
      for (final post in page.posts) post.toView(),
  ]);

  Set<String> get referencedContentIds => Set<String>.unmodifiable({
    for (final page in pages)
      for (final post in page.posts)
        if (!post.mediaHiddenByRetention)
          for (final media in post.effective.media) media.contentId!,
  });
}

SpacePost? _strictSpacePostFromJson(Object? value) {
  if (value is! Map) return null;
  final post = SpacePost.fromJson(value);
  if (post == null) return null;
  return _deepCanonicalJson(value) == _deepCanonicalJson(post.toJson())
      ? post
      : null;
}

String _spacePostWireHash(SpacePost post) =>
    crypto.sha256.convert(utf8.encode(jsonEncode(post.toJson()))).toString();

String _deepCanonicalJson(Object? value) => jsonEncode(_canonicalize(value));

Object? _canonicalize(Object? value) {
  if (value is List) return [for (final item in value) _canonicalize(item)];
  if (value is Map) {
    final keys = value.keys.whereType<String>().toList()..sort();
    if (keys.length != value.length) return const <String, Object?>{};
    return {for (final key in keys) key: _canonicalize(value[key])};
  }
  return value;
}

bool _hasOnlyKeys(Map<dynamic, dynamic> value, Set<String> allowed) {
  for (final key in value.keys) {
    if (key is! String || !allowed.contains(key)) return false;
  }
  return true;
}
