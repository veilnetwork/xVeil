import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import 'space_discovery.dart'
    show
        SpacePublicDescriptor,
        SpacePublicSignatureVerifier,
        kSpacePublicClockSkew,
        kSpacePublicDescriptorLifetime;
import 'space_post.dart';
import 'space_public_discussion.dart';

const int kSpacePublicFeedPageSize = 32;
const int kSpacePublicFeedPageMaxBytes = 1024 * 1024;
const int kSpacePublicFeedPageMaxCount = 4096;
const int kSpacePublicDiscussionPageSize = 64;
const int kSpacePublicDiscussionPageMaxBytes = 1024 * 1024;
const int kSpacePublicDiscussionPageMaxCount = 4096;
const int kSpacePublicFeedProjectionMaxBytes = 64 * 1024 * 1024;
const int kSpacePublicFeedPackageMaxBytes =
    kSpacePublicFeedProjectionMaxBytes + 2 * 1024 * 1024;
const int kSpacePublicSubscriptionSnapshotMaxBytes =
    kSpacePublicFeedPackageMaxBytes + 64 * 1024;

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

/// A bounded page of independently author-signed public discussion records.
///
/// The owner-signed feed manifest commits the page hash, but every comment and
/// reaction still verifies against its own author. Member-private message and
/// reaction logs are never decoded into this boundary.
class SpacePublicDiscussionPage {
  SpacePublicDiscussionPage({
    required this.spaceId,
    required this.index,
    required Iterable<SpacePublicComment> comments,
    required Iterable<SpacePublicReaction> reactions,
  }) : comments = List<SpacePublicComment>.unmodifiable(comments),
       reactions = List<SpacePublicReaction>.unmodifiable(reactions);

  final NodeId spaceId;
  final int index;
  final List<SpacePublicComment> comments;
  final List<SpacePublicReaction> reactions;

  int get itemCount => comments.length + reactions.length;

  bool get isStructurallyValid =>
      index >= 0 &&
      itemCount > 0 &&
      itemCount <= kSpacePublicDiscussionPageSize &&
      comments.every(
        (comment) => comment.spaceId == spaceId && comment.isStructurallyValid,
      ) &&
      reactions.every(
        (reaction) =>
            reaction.spaceId == spaceId && reaction.isStructurallyValid,
      ) &&
      canonicalBytes().length <= kSpacePublicDiscussionPageMaxBytes;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'kind': 'xveil.space.public-discussion-page',
    'space': spaceId.hex,
    'index': index,
    'comments': [for (final comment in comments) comment.toJson()],
    'reactions': [for (final reaction in reactions) reaction.toJson()],
  };

  Uint8List canonicalBytes() =>
      Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  String get contentHash => crypto.sha256.convert(canonicalBytes()).toString();

  bool verify({
    required String expectedHash,
    required SpacePublicSignatureVerifier verifySignature,
  }) =>
      isStructurallyValid &&
      contentHash == expectedHash &&
      comments.every((comment) => comment.verify(verifySignature)) &&
      reactions.every((reaction) => reaction.verify(verifySignature));

  static SpacePublicDiscussionPage? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'kind',
          'space',
          'index',
          'comments',
          'reactions',
        }) ||
        value.length != 6 ||
        value['v'] != 1 ||
        value['kind'] != 'xveil.space.public-discussion-page' ||
        value['space'] is! String ||
        value['index'] is! int ||
        value['comments'] is! List ||
        value['reactions'] is! List) {
      return null;
    }
    final rawComments = value['comments'] as List;
    final rawReactions = value['reactions'] as List;
    if (rawComments.length + rawReactions.length == 0 ||
        rawComments.length + rawReactions.length >
            kSpacePublicDiscussionPageSize) {
      return null;
    }
    final comments = rawComments
        .map(SpacePublicComment.fromJson)
        .whereType<SpacePublicComment>()
        .toList(growable: false);
    final reactions = rawReactions
        .map(SpacePublicReaction.fromJson)
        .whereType<SpacePublicReaction>()
        .toList(growable: false);
    if (comments.length != rawComments.length ||
        reactions.length != rawReactions.length) {
      return null;
    }
    try {
      final page = SpacePublicDiscussionPage(
        spaceId: NodeId.fromHex(value['space'] as String),
        index: value['index'] as int,
        comments: comments,
        reactions: reactions,
      );
      return page.isStructurallyValid ? page : null;
    } catch (_) {
      return null;
    }
  }

  static SpacePublicDiscussionPage? fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > kSpacePublicDiscussionPageMaxBytes) {
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
    this.wireVersion = version,
    this.discussionItemCount = 0,
    Iterable<String> discussionPageHashes = const [],
    Uint8List? signature,
  }) : pageHashes = List<String>.unmodifiable(pageHashes),
       discussionPageHashes = List<String>.unmodifiable(discussionPageHashes),
       signature = signature ?? Uint8List(0);

  static const int version = 1;
  static const int discussionVersion = 2;
  static const String kind = 'xveil.space.public-feed';

  final int wireVersion;
  final NodeId spaceId;
  final NodeId publisher;
  final String controlHeadHash;
  final int revision;
  final int updatedAtMs;
  final int issuedAtMs;
  final int expiresAtMs;
  final int itemCount;
  final List<String> pageHashes;
  final int discussionItemCount;
  final List<String> discussionPageHashes;
  final Uint8List signature;

  bool isStructurallyValidAt(int nowMs) {
    if ((wireVersion != version && wireVersion != discussionVersion) ||
        !_publicFeedHashPattern.hasMatch(controlHeadHash) ||
        revision < 0 ||
        updatedAtMs < 0 ||
        issuedAtMs < updatedAtMs ||
        expiresAtMs <= issuedAtMs ||
        expiresAtMs - issuedAtMs >
            kSpacePublicDescriptorLifetime.inMilliseconds ||
        issuedAtMs > nowMs + kSpacePublicClockSkew.inMilliseconds ||
        expiresAtMs <= nowMs ||
        signature.length != 64 ||
        !_validPageCommitment(
          itemCount: itemCount,
          pageSize: kSpacePublicFeedPageSize,
          maxPageCount: kSpacePublicFeedPageMaxCount,
          pageHashes: pageHashes,
        ) ||
        (wireVersion == version
            ? discussionItemCount != 0 || discussionPageHashes.isNotEmpty
            : !_validPageCommitment(
                itemCount: discussionItemCount,
                pageSize: kSpacePublicDiscussionPageSize,
                maxPageCount: kSpacePublicDiscussionPageMaxCount,
                pageHashes: discussionPageHashes,
              ))) {
      return false;
    }
    return true;
  }

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': wireVersion,
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
        if (wireVersion >= discussionVersion) ...{
          'discussionItemCount': discussionItemCount,
          'discussionPageHashes': discussionPageHashes,
        },
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
        wireVersion: wireVersion,
        discussionItemCount: discussionItemCount,
        discussionPageHashes: discussionPageHashes,
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
          'discussionItemCount',
          'discussionPageHashes',
          'signature',
        }) ||
        (value['v'] != version && value['v'] != discussionVersion) ||
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
    final wireVersion = value['v'] as int;
    if (wireVersion == version
        ? value.containsKey('discussionItemCount') ||
              value.containsKey('discussionPageHashes')
        : value['discussionItemCount'] is! int ||
              value['discussionPageHashes'] is! List) {
      return null;
    }
    final rawHashes = value['pageHashes'] as List;
    final rawDiscussionHashes =
        value['discussionPageHashes'] as List? ?? const [];
    if (rawHashes.length > kSpacePublicFeedPageMaxCount ||
        rawHashes.any((hash) => hash is! String) ||
        rawDiscussionHashes.length > kSpacePublicDiscussionPageMaxCount ||
        rawDiscussionHashes.any((hash) => hash is! String)) {
      return null;
    }
    try {
      return SpacePublicFeedManifest(
        wireVersion: wireVersion,
        spaceId: NodeId.fromHex(value['space'] as String),
        publisher: NodeId.fromHex(value['publisher'] as String),
        controlHeadHash: value['controlHeadHash'] as String,
        revision: value['revision'] as int,
        updatedAtMs: value['updatedAt'] as int,
        issuedAtMs: value['issuedAt'] as int,
        expiresAtMs: value['expiresAt'] as int,
        itemCount: value['itemCount'] as int,
        pageHashes: rawHashes.cast<String>(),
        discussionItemCount: value['discussionItemCount'] as int? ?? 0,
        discussionPageHashes: rawDiscussionHashes.cast<String>(),
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
    Iterable<SpacePublicDiscussionPage> discussionPages = const [],
  }) : pages = List<SpacePublicFeedPage>.unmodifiable(pages),
       discussionPages = List<SpacePublicDiscussionPage>.unmodifiable(
         discussionPages,
       );

  final SpacePublicFeedManifest manifest;
  final List<SpacePublicFeedPage> pages;
  final List<SpacePublicDiscussionPage> discussionPages;

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
        pages.length != manifest.pageHashes.length ||
        discussionPages.length != manifest.discussionPageHashes.length) {
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
    if (itemCount != manifest.itemCount) return false;

    final postLifecycles = <String, String?>{
      for (final page in pages)
        for (final post in page.posts)
          post.root.postId: _publicPostLifecycle(post.root),
    };
    final recordHashes = <String>{};
    var discussionItemCount = 0;
    for (var index = 0; index < discussionPages.length; index++) {
      final page = discussionPages[index];
      if (page.index != index ||
          page.spaceId != expectedSpaceId ||
          !page.verify(
            expectedHash: manifest.discussionPageHashes[index],
            verifySignature: verifySignature,
          )) {
        return false;
      }
      for (final comment in page.comments) {
        if (postLifecycles[comment.postId] != comment.lifecycleGeneration ||
            !recordHashes.add(comment.recordHash)) {
          return false;
        }
      }
      for (final reaction in page.reactions) {
        if (postLifecycles[reaction.postId] != reaction.lifecycleGeneration ||
            !recordHashes.add(reaction.recordHash)) {
          return false;
        }
      }
      discussionItemCount += page.itemCount;
    }
    return discussionItemCount == manifest.discussionItemCount;
  }

  List<SpacePostView> get posts => List<SpacePostView>.unmodifiable([
    for (final page in pages)
      for (final post in page.posts) post.toView(),
  ]);

  List<SpacePublicCommentView> commentsFor(
    String postId,
    SpacePublicSignatureVerifier verifySignature,
  ) => foldSpacePublicComments(
    comments: [for (final page in discussionPages) ...page.comments],
    spaceId: manifest.spaceId,
    postId: postId,
    verifySignature: verifySignature,
  );

  SpacePublicReactions reactionsFor(
    String postId,
    SpacePublicSignatureVerifier verifySignature,
  ) => foldSpacePublicReactions(
    reactions: [for (final page in discussionPages) ...page.reactions],
    spaceId: manifest.spaceId,
    postId: postId,
    verifySignature: verifySignature,
  );

  /// Content reachable from the current folded public projection.
  ///
  /// Callers that use this set as an authorization boundary must use
  /// [verifiedReferencedContentIds]. This compatibility getter assumes the
  /// enclosing projection has already passed [verifyAt], as storage
  /// reachability and diagnostics do.
  Set<String> get referencedContentIds =>
      _referencedContentIds(_acceptProjectionSignature);

  /// Signature-verifying variant used by the public media grant boundary.
  ///
  /// Comment CIDs come only from currently visible roots. A later signed
  /// delete, or owner moderation that omits the root from the snapshot,
  /// therefore revokes future grants without mutating historical records.
  Set<String> verifiedReferencedContentIds(
    SpacePublicSignatureVerifier verifySignature,
  ) => _referencedContentIds(verifySignature);

  Set<String> _referencedContentIds(
    SpacePublicSignatureVerifier verifySignature,
  ) {
    final contentIds = <String>{
      for (final page in pages)
        for (final post in page.posts)
          if (!post.mediaHiddenByRetention)
            for (final media in post.effective.media) media.contentId!,
    };
    final postIds = <String>{
      for (final page in discussionPages)
        for (final comment in page.comments) comment.postId,
    };
    for (final postId in postIds) {
      for (final comment in commentsFor(postId, verifySignature)) {
        final media = comment.media;
        if (media != null) contentIds.add(media.contentId!);
      }
    }
    return Set<String>.unmodifiable(contentIds);
  }
}

bool _acceptProjectionSignature({
  required NodeId signer,
  required Uint8List publicKey,
  required Uint8List message,
  required Uint8List signature,
}) => true;

/// Durable/cache wire unit for one exact descriptor revision. Keeping the
/// descriptor alongside its committed manifest lets a restarted holder serve
/// a still-live attestation without reconstructing any private GroupBundle.
class SpacePublicFeedPackage {
  const SpacePublicFeedPackage({
    required this.descriptor,
    required this.projection,
  });

  final SpacePublicDescriptor descriptor;
  final SpacePublicFeedProjection projection;

  bool verifyAt({
    required int nowMs,
    required SpacePublicSignatureVerifier verifySignature,
    required SpacePublicPostVerifier verifyPost,
  }) =>
      descriptor.verifyAt(nowMs, verifySignature) &&
      projection.manifest.revision == descriptor.publicFeedRevision &&
      projection.manifest.updatedAtMs == descriptor.publicFeedUpdatedAtMs &&
      projection.manifest.itemCount == descriptor.publicPostCount &&
      projection.verifyAt(
        nowMs: nowMs,
        expectedManifestHash: descriptor.publicFeedManifestHash,
        expectedSpaceId: descriptor.spaceId,
        expectedPublisher: descriptor.publisher,
        publisherPublicKey: descriptor.publisherPublicKey,
        expectedControlHeadHash: descriptor.controlHeadHash,
        verifySignature: verifySignature,
        verifyPost: verifyPost,
      );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'kind': 'xveil.space.public-feed-package',
    'descriptor': descriptor.toJson(),
    'manifest': projection.manifest.toJson(),
    'pages': [for (final page in projection.pages) page.toJson()],
    if (projection.manifest.wireVersion >=
        SpacePublicFeedManifest.discussionVersion)
      'discussionPages': [
        for (final page in projection.discussionPages) page.toJson(),
      ],
  };

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static SpacePublicFeedPackage? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'kind',
          'descriptor',
          'manifest',
          'pages',
          'discussionPages',
        }) ||
        value['v'] != 1 ||
        value['kind'] != 'xveil.space.public-feed-package' ||
        value['pages'] is! List ||
        (value.containsKey('discussionPages') &&
            value['discussionPages'] is! List)) {
      return null;
    }
    final descriptor = SpacePublicDescriptor.fromJson(value['descriptor']);
    final manifest = SpacePublicFeedManifest.fromJson(value['manifest']);
    final rawPages = value['pages'] as List;
    final rawDiscussionPages = value['discussionPages'] as List? ?? const [];
    if (descriptor == null ||
        manifest == null ||
        rawPages.length > kSpacePublicFeedPageMaxCount ||
        rawDiscussionPages.length > kSpacePublicDiscussionPageMaxCount ||
        (manifest.wireVersion == SpacePublicFeedManifest.version
            ? value.containsKey('discussionPages')
            : value['discussionPages'] is! List)) {
      return null;
    }
    final pages = rawPages
        .map(SpacePublicFeedPage.fromJson)
        .whereType<SpacePublicFeedPage>()
        .toList(growable: false);
    if (pages.length != rawPages.length) return null;
    final discussionPages = rawDiscussionPages
        .map(SpacePublicDiscussionPage.fromJson)
        .whereType<SpacePublicDiscussionPage>()
        .toList(growable: false);
    if (discussionPages.length != rawDiscussionPages.length) return null;
    return SpacePublicFeedPackage(
      descriptor: descriptor,
      projection: SpacePublicFeedProjection(
        manifest: manifest,
        pages: pages,
        discussionPages: discussionPages,
      ),
    );
  }

  static SpacePublicFeedPackage? fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > kSpacePublicFeedPackageMaxBytes) {
      return null;
    }
    try {
      return fromJson(jsonDecode(utf8.decode(bytes, allowMalformed: false)));
    } catch (_) {
      return null;
    }
  }
}

/// A locally subscribed, previously verified public snapshot.
///
/// Public signatures contain short network-expiry windows. An offline reader
/// may continue showing bytes that were valid when fetched, but must not
/// present the snapshot as current availability. [verifiedAtMs] records that
/// validation instant; refresh/discovery still uses the current clock and a
/// fresh holder quorum.
class SpacePublicSubscriptionSnapshot {
  const SpacePublicSubscriptionSnapshot({
    required this.verifiedAtMs,
    required this.package,
  });

  final int verifiedAtMs;
  final SpacePublicFeedPackage package;

  bool verifyStored({
    required SpacePublicSignatureVerifier verifySignature,
    required SpacePublicPostVerifier verifyPost,
  }) {
    final descriptor = package.descriptor;
    final manifest = package.projection.manifest;
    return verifiedAtMs >= 0 &&
        verifiedAtMs >= descriptor.issuedAtMs &&
        verifiedAtMs < descriptor.expiresAtMs &&
        verifiedAtMs >= manifest.issuedAtMs &&
        verifiedAtMs < manifest.expiresAtMs &&
        package.verifyAt(
          nowMs: verifiedAtMs,
          verifySignature: verifySignature,
          verifyPost: verifyPost,
        );
  }

  bool isStaleAt(int nowMs) =>
      nowMs >= package.descriptor.expiresAtMs ||
      nowMs >= package.projection.manifest.expiresAtMs;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'kind': 'xveil.space.public-subscription-snapshot',
    'verifiedAt': verifiedAtMs,
    'package': package.toJson(),
  };

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static SpacePublicSubscriptionSnapshot? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {'v', 'kind', 'verifiedAt', 'package'}) ||
        value['v'] != 1 ||
        value['kind'] != 'xveil.space.public-subscription-snapshot' ||
        value['verifiedAt'] is! int) {
      return null;
    }
    final package = SpacePublicFeedPackage.fromJson(value['package']);
    if (package == null) return null;
    return SpacePublicSubscriptionSnapshot(
      verifiedAtMs: value['verifiedAt'] as int,
      package: package,
    );
  }

  static SpacePublicSubscriptionSnapshot? fromBytes(Uint8List bytes) {
    if (bytes.isEmpty ||
        bytes.length > kSpacePublicSubscriptionSnapshotMaxBytes) {
      return null;
    }
    try {
      return fromJson(jsonDecode(utf8.decode(bytes, allowMalformed: false)));
    } catch (_) {
      return null;
    }
  }
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

String _publicPostLifecycle(SpacePost post) =>
    post.lifecycleGeneration ??
    crypto.sha256
        .convert(
          utf8.encode(
            'xveil.space-post-lifecycle.genesis.v1|${post.spaceId.hex}',
          ),
        )
        .toString();

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

bool _validPageCommitment({
  required int itemCount,
  required int pageSize,
  required int maxPageCount,
  required List<String> pageHashes,
}) {
  if (itemCount < 0 ||
      pageHashes.length > maxPageCount ||
      pageHashes.any((hash) => !_publicFeedHashPattern.hasMatch(hash)) ||
      pageHashes.toSet().length != pageHashes.length) {
    return false;
  }
  if (itemCount == 0) return pageHashes.isEmpty;
  return pageHashes.isNotEmpty &&
      itemCount <= pageHashes.length * pageSize &&
      itemCount > (pageHashes.length - 1) * pageSize;
}
