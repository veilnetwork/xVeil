import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import 'media_object.dart';
import 'space_discovery.dart' show SpacePublicSignatureVerifier;

const int kSpacePublicCommentBodyMaxBytes = 64 * 1024;
const int kSpacePublicCommentWireMaxBytes = 96 * 1024;
const int kSpacePublicReactionWireMaxBytes = 8 * 1024;

final RegExp _publicDiscussionHashPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _publicDiscussionRefPattern = RegExp(r'^[0-9a-f]{64}:[0-9]+$');

enum SpacePublicCommentOperation {
  create,
  edit,
  delete;

  static SpacePublicCommentOperation? fromName(String? value) {
    for (final operation in values) {
      if (operation.name == value) return operation;
    }
    return null;
  }
}

/// One independently author-signed public comment record.
///
/// This is deliberately not a decoded [GroupMessage]. Member discussion stays
/// encrypted in the membership log. A client creates this separate statement
/// only when it intentionally contributes to a public discussion. The Space
/// owner may admit or omit the statement from a public snapshot, but cannot
/// alter its author, post, body, reply target or lifecycle without invalidating
/// the author's signature.
class SpacePublicComment {
  SpacePublicComment({
    required this.spaceId,
    required this.postId,
    required this.author,
    required this.seq,
    required this.prevHash,
    required this.operation,
    required this.body,
    required this.lifecycleGeneration,
    required this.createdAtMs,
    required this.signature,
    required this.authorPubKey,
    this.targetSeq,
    this.replyTo,
    this.media,
  });

  static const int version = 1;
  static const String kind = 'xveil.space.public-comment';

  final NodeId spaceId;
  final String postId;
  final NodeId author;

  /// Monotonic inside this author's public-comment chain for [postId].
  final int seq;
  final String prevHash;
  final SpacePublicCommentOperation operation;

  /// Root sequence for edit/delete. A create owns its own [seq].
  final int? targetSeq;
  final String body;
  final String? replyTo;
  final MediaObject? media;
  final String lifecycleGeneration;
  final int createdAtMs;
  final Uint8List signature;
  final Uint8List authorPubKey;

  String get ref =>
      '${author.hex}:'
      '${operation == SpacePublicCommentOperation.create ? seq : targetSeq}';

  bool get isStructurallyValid {
    if (!_publicDiscussionRefPattern.hasMatch(postId) ||
        seq < 0 ||
        createdAtMs < 0 ||
        !_publicDiscussionHashPattern.hasMatch(lifecycleGeneration) ||
        signature.length != 64 ||
        authorPubKey.length != 32 ||
        utf8.encode(body).length > kSpacePublicCommentBodyMaxBytes ||
        (prevHash.isNotEmpty &&
            !_publicDiscussionHashPattern.hasMatch(prevHash))) {
      return false;
    }
    final validMedia =
        media == null ||
        (media!.inlinePreviewB64 == null &&
            media!.isReferenceStructurallyValid);
    if (!validMedia) return false;
    switch (operation) {
      case SpacePublicCommentOperation.create:
        return targetSeq == null &&
            (body.trim().isNotEmpty || media != null) &&
            (replyTo == null ||
                (_publicDiscussionRefPattern.hasMatch(replyTo!) &&
                    replyTo != ref));
      case SpacePublicCommentOperation.edit:
        return targetSeq != null &&
            targetSeq! >= 0 &&
            targetSeq! < seq &&
            replyTo == null &&
            media == null;
      case SpacePublicCommentOperation.delete:
        return targetSeq != null &&
            targetSeq! >= 0 &&
            targetSeq! < seq &&
            body.isEmpty &&
            replyTo == null &&
            media == null;
    }
  }

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': version,
        'kind': kind,
        'space': spaceId.hex,
        'post': postId,
        'author': author.hex,
        'seq': seq,
        'prev': prevHash,
        'op': operation.name,
        if (targetSeq != null) 'target': targetSeq,
        'body': body,
        if (replyTo != null) 'replyTo': replyTo,
        if (media != null) 'media': media!.toJson(),
        'lifecycle': lifecycleGeneration,
        'created': createdAtMs,
      }),
    ),
  );

  String get recordHash => crypto.sha256.convert(<int>[
    ...canonicalBytes(),
    ...signature,
  ]).toString();

  bool verify(SpacePublicSignatureVerifier verifySignature) =>
      isStructurallyValid &&
      verifySignature(
        signer: author,
        publicKey: authorPubKey,
        message: canonicalBytes(),
        signature: signature,
      );

  SpacePublicComment withSignature(Uint8List value, Uint8List publicKey) =>
      SpacePublicComment(
        spaceId: spaceId,
        postId: postId,
        author: author,
        seq: seq,
        prevHash: prevHash,
        operation: operation,
        targetSeq: targetSeq,
        body: body,
        replyTo: replyTo,
        media: media,
        lifecycleGeneration: lifecycleGeneration,
        createdAtMs: createdAtMs,
        signature: value,
        authorPubKey: publicKey,
      );

  Map<String, dynamic> toJson() => {
    ...jsonDecode(utf8.decode(canonicalBytes())) as Map<String, dynamic>,
    'signature': base64Encode(signature),
    'authorPublicKey': base64Encode(authorPubKey),
  };

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static SpacePublicComment? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'kind',
          'space',
          'post',
          'author',
          'seq',
          'prev',
          'op',
          'target',
          'body',
          'replyTo',
          'media',
          'lifecycle',
          'created',
          'signature',
          'authorPublicKey',
        }) ||
        value['v'] != version ||
        value['kind'] != kind ||
        value['space'] is! String ||
        value['post'] is! String ||
        value['author'] is! String ||
        value['seq'] is! int ||
        value['prev'] is! String ||
        value['op'] is! String ||
        value['body'] is! String ||
        value['lifecycle'] is! String ||
        value['created'] is! int ||
        value['signature'] is! String ||
        value['authorPublicKey'] is! String ||
        (value.containsKey('target') && value['target'] is! int) ||
        (value.containsKey('replyTo') && value['replyTo'] is! String) ||
        (value.containsKey('media') && value['media'] is! Map)) {
      return null;
    }
    final operation = SpacePublicCommentOperation.fromName(
      value['op'] as String,
    );
    if (operation == null) return null;
    try {
      final media = value.containsKey('media')
          ? MediaObject.fromReferenceJson(value['media'])
          : null;
      if (value.containsKey('media') && media == null) return null;
      final comment = SpacePublicComment(
        spaceId: NodeId.fromHex(value['space'] as String),
        postId: value['post'] as String,
        author: NodeId.fromHex(value['author'] as String),
        seq: value['seq'] as int,
        prevHash: value['prev'] as String,
        operation: operation,
        targetSeq: value['target'] as int?,
        body: value['body'] as String,
        replyTo: value['replyTo'] as String?,
        media: media,
        lifecycleGeneration: value['lifecycle'] as String,
        createdAtMs: value['created'] as int,
        signature: Uint8List.fromList(
          base64Decode(value['signature'] as String),
        ),
        authorPubKey: Uint8List.fromList(
          base64Decode(value['authorPublicKey'] as String),
        ),
      );
      return comment.isStructurallyValid ? comment : null;
    } catch (_) {
      return null;
    }
  }

  static SpacePublicComment? fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > kSpacePublicCommentWireMaxBytes) {
      return null;
    }
    try {
      return fromJson(jsonDecode(utf8.decode(bytes, allowMalformed: false)));
    } catch (_) {
      return null;
    }
  }
}

/// One independently author-signed public reaction state transition.
///
/// An empty [emoji] removes this author's reaction. Records form an isolated
/// per-author chain for one post, so a holder cannot reorder or splice a
/// terminal reaction without breaking [prevHash].
class SpacePublicReaction {
  SpacePublicReaction({
    required this.spaceId,
    required this.postId,
    required this.author,
    required this.seq,
    required this.prevHash,
    required this.emoji,
    required this.lifecycleGeneration,
    required this.createdAtMs,
    required this.signature,
    required this.authorPubKey,
  });

  static const int version = 1;
  static const String kind = 'xveil.space.public-reaction';

  final NodeId spaceId;
  final String postId;
  final NodeId author;
  final int seq;
  final String prevHash;
  final String emoji;
  final String lifecycleGeneration;
  final int createdAtMs;
  final Uint8List signature;
  final Uint8List authorPubKey;

  bool get isStructurallyValid =>
      _publicDiscussionRefPattern.hasMatch(postId) &&
      seq >= 0 &&
      createdAtMs >= 0 &&
      utf8.encode(emoji).length <= 64 &&
      _publicDiscussionHashPattern.hasMatch(lifecycleGeneration) &&
      signature.length == 64 &&
      authorPubKey.length == 32 &&
      (prevHash.isEmpty || _publicDiscussionHashPattern.hasMatch(prevHash));

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': version,
        'kind': kind,
        'space': spaceId.hex,
        'post': postId,
        'author': author.hex,
        'seq': seq,
        'prev': prevHash,
        'emoji': emoji,
        'lifecycle': lifecycleGeneration,
        'created': createdAtMs,
      }),
    ),
  );

  String get recordHash => crypto.sha256.convert(<int>[
    ...canonicalBytes(),
    ...signature,
  ]).toString();

  bool verify(SpacePublicSignatureVerifier verifySignature) =>
      isStructurallyValid &&
      verifySignature(
        signer: author,
        publicKey: authorPubKey,
        message: canonicalBytes(),
        signature: signature,
      );

  SpacePublicReaction withSignature(Uint8List value, Uint8List publicKey) =>
      SpacePublicReaction(
        spaceId: spaceId,
        postId: postId,
        author: author,
        seq: seq,
        prevHash: prevHash,
        emoji: emoji,
        lifecycleGeneration: lifecycleGeneration,
        createdAtMs: createdAtMs,
        signature: value,
        authorPubKey: publicKey,
      );

  Map<String, dynamic> toJson() => {
    ...jsonDecode(utf8.decode(canonicalBytes())) as Map<String, dynamic>,
    'signature': base64Encode(signature),
    'authorPublicKey': base64Encode(authorPubKey),
  };

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static SpacePublicReaction? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'kind',
          'space',
          'post',
          'author',
          'seq',
          'prev',
          'emoji',
          'lifecycle',
          'created',
          'signature',
          'authorPublicKey',
        }) ||
        value.length != 12 ||
        value['v'] != version ||
        value['kind'] != kind ||
        value['space'] is! String ||
        value['post'] is! String ||
        value['author'] is! String ||
        value['seq'] is! int ||
        value['prev'] is! String ||
        value['emoji'] is! String ||
        value['lifecycle'] is! String ||
        value['created'] is! int ||
        value['signature'] is! String ||
        value['authorPublicKey'] is! String) {
      return null;
    }
    try {
      final reaction = SpacePublicReaction(
        spaceId: NodeId.fromHex(value['space'] as String),
        postId: value['post'] as String,
        author: NodeId.fromHex(value['author'] as String),
        seq: value['seq'] as int,
        prevHash: value['prev'] as String,
        emoji: value['emoji'] as String,
        lifecycleGeneration: value['lifecycle'] as String,
        createdAtMs: value['created'] as int,
        signature: Uint8List.fromList(
          base64Decode(value['signature'] as String),
        ),
        authorPubKey: Uint8List.fromList(
          base64Decode(value['authorPublicKey'] as String),
        ),
      );
      return reaction.isStructurallyValid ? reaction : null;
    } catch (_) {
      return null;
    }
  }

  static SpacePublicReaction? fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > kSpacePublicReactionWireMaxBytes) {
      return null;
    }
    try {
      return fromJson(jsonDecode(utf8.decode(bytes, allowMalformed: false)));
    } catch (_) {
      return null;
    }
  }
}

class SpacePublicCommentView {
  const SpacePublicCommentView({required this.root, this.revision});

  final SpacePublicComment root;
  final SpacePublicComment? revision;

  String get ref => root.ref;
  NodeId get author => root.author;
  String get body => revision?.body ?? root.body;
  String? get replyTo => root.replyTo;
  MediaObject? get media => root.media;
  int get createdAtMs => root.createdAtMs;
  bool get edited => revision?.operation == SpacePublicCommentOperation.edit;
  int? get editedAtMs => edited ? revision!.createdAtMs : null;
}

/// Strictly folds one post's author-signed public comment chains.
///
/// A fork, gap or bad predecessor rejects only that author's chain. Invalid
/// edits never replace a valid root. Deleted roots are omitted from the current
/// view, while replies may retain their stable reference to a deleted root.
List<SpacePublicCommentView> foldSpacePublicComments({
  required Iterable<SpacePublicComment> comments,
  required NodeId spaceId,
  required String postId,
  required SpacePublicSignatureVerifier verifySignature,
}) {
  final byAuthor = <NodeId, List<SpacePublicComment>>{};
  for (final comment in comments) {
    if (comment.spaceId != spaceId ||
        comment.postId != postId ||
        !comment.verify(verifySignature)) {
      continue;
    }
    byAuthor.putIfAbsent(comment.author, () => []).add(comment);
  }

  final accepted = <SpacePublicComment>[];
  for (final chain in byAuthor.values) {
    chain.sort((left, right) => left.seq.compareTo(right.seq));
    var valid = chain.isNotEmpty;
    for (var index = 0; valid && index < chain.length; index++) {
      final current = chain[index];
      if ((index > 0 && current.seq <= chain[index - 1].seq) ||
          (index == 0
              ? current.prevHash.isNotEmpty
              : current.prevHash != chain[index - 1].recordHash)) {
        valid = false;
      }
    }
    if (valid) accepted.addAll(chain);
  }
  accepted.sort((left, right) {
    final byTime = left.createdAtMs.compareTo(right.createdAtMs);
    if (byTime != 0) return byTime;
    final byAuthor = left.author.hex.compareTo(right.author.hex);
    return byAuthor != 0 ? byAuthor : left.seq.compareTo(right.seq);
  });

  final roots = <String, SpacePublicComment>{};
  final revisions = <String, SpacePublicComment>{};
  for (final comment in accepted) {
    if (comment.operation == SpacePublicCommentOperation.create) {
      roots[comment.ref] = comment;
      continue;
    }
    final rootRef = comment.ref;
    final root = roots[rootRef];
    if (root == null || root.author != comment.author) continue;
    final current = revisions[rootRef];
    if (current == null || comment.seq > current.seq) {
      revisions[rootRef] = comment;
    }
  }

  final views = <SpacePublicCommentView>[];
  for (final root in roots.values) {
    if (root.replyTo != null) {
      final parent = roots[root.replyTo];
      if (parent == null || !_precedes(parent, root)) continue;
    }
    final revision = revisions[root.ref];
    if (revision?.operation == SpacePublicCommentOperation.delete) continue;
    if (revision?.operation == SpacePublicCommentOperation.edit &&
        revision!.body.trim().isEmpty &&
        root.media == null) {
      continue;
    }
    views.add(SpacePublicCommentView(root: root, revision: revision));
  }
  views.sort((left, right) {
    final byTime = left.createdAtMs.compareTo(right.createdAtMs);
    return byTime != 0 ? byTime : left.ref.compareTo(right.ref);
  });
  return List<SpacePublicCommentView>.unmodifiable(views);
}

typedef SpacePublicReactions = Map<String, List<NodeId>>;

/// Folds the terminal verified reaction for each author on one public post.
SpacePublicReactions foldSpacePublicReactions({
  required Iterable<SpacePublicReaction> reactions,
  required NodeId spaceId,
  required String postId,
  required SpacePublicSignatureVerifier verifySignature,
}) {
  final byAuthor = <NodeId, List<SpacePublicReaction>>{};
  for (final reaction in reactions) {
    if (reaction.spaceId != spaceId ||
        reaction.postId != postId ||
        !reaction.verify(verifySignature)) {
      continue;
    }
    byAuthor.putIfAbsent(reaction.author, () => []).add(reaction);
  }

  final terminal = <SpacePublicReaction>[];
  for (final chain in byAuthor.values) {
    chain.sort((left, right) => left.seq.compareTo(right.seq));
    var valid = chain.isNotEmpty;
    for (var index = 0; valid && index < chain.length; index++) {
      final current = chain[index];
      if ((index > 0 && current.seq <= chain[index - 1].seq) ||
          (index == 0
              ? current.prevHash.isNotEmpty
              : current.prevHash != chain[index - 1].recordHash)) {
        valid = false;
      }
    }
    if (valid) terminal.add(chain.last);
  }
  terminal.sort((left, right) => left.author.hex.compareTo(right.author.hex));

  final mutable = <String, List<NodeId>>{};
  for (final reaction in terminal) {
    if (reaction.emoji.isEmpty) continue;
    mutable.putIfAbsent(reaction.emoji, () => []).add(reaction.author);
  }
  final emojis = mutable.keys.toList()..sort();
  return Map<String, List<NodeId>>.unmodifiable({
    for (final emoji in emojis)
      emoji: List<NodeId>.unmodifiable(mutable[emoji]!),
  });
}

bool _precedes(SpacePublicComment left, SpacePublicComment right) =>
    left.createdAtMs < right.createdAtMs ||
    (left.createdAtMs == right.createdAtMs &&
        left.ref.compareTo(right.ref) < 0);

bool _hasOnlyKeys(Map value, Set<String> allowed) =>
    value.keys.every((key) => key is String && allowed.contains(key));
