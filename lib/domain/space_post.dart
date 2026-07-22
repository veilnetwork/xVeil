import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import 'group_payload.dart';

const int kSpacePostTitleMax = 300;
const int kSpacePostBodyMax = 256 * 1024;
const int kSpacePostMediaMax = 32;
const int kSpaceControlFrontierMax = 256;
const int kSpaceControlCheckpointHeadsMax = 4096;

/// One accepted per-author control-log head observed by a publisher. A list of
/// these heads is a compact causal cut: receivers can reconstruct precisely
/// the authorization state against which the post was signed.
class SpaceControlHead {
  const SpaceControlHead({
    required this.author,
    required this.seq,
    required this.hash,
  });

  final NodeId author;
  final int seq;
  final String hash;

  bool get isStructurallyValid =>
      seq >= 0 && RegExp(r'^[0-9a-f]{64}$').hasMatch(hash);

  Map<String, dynamic> toJson() => {
    'author': author.hex,
    'seq': seq,
    'hash': hash,
  };

  static SpaceControlHead? fromJson(Object? value) {
    if (value is! Map ||
        value['author'] is! String ||
        value['seq'] is! int ||
        value['hash'] is! String) {
      return null;
    }
    try {
      final head = SpaceControlHead(
        author: NodeId.fromHex(value['author'] as String),
        seq: value['seq'] as int,
        hash: value['hash'] as String,
      );
      return head.isStructurallyValid ? head : null;
    } catch (_) {
      return null;
    }
  }
}

class SpaceControlFrontier {
  SpaceControlFrontier(Iterable<SpaceControlHead> heads)
    : heads = List<SpaceControlHead>.unmodifiable(heads);

  final List<SpaceControlHead> heads;

  bool get isStructurallyValid {
    if (heads.isEmpty || heads.length > kSpaceControlFrontierMax) return false;
    String? previous;
    for (final head in heads) {
      if (!head.isStructurallyValid ||
          (previous != null && head.author.hex.compareTo(previous) <= 0)) {
        return false;
      }
      previous = head.author.hex;
    }
    return true;
  }

  List<Map<String, dynamic>> toJson() => [
    for (final head in heads) head.toJson(),
  ];

  static SpaceControlFrontier? fromJson(Object? value) {
    if (value is! List) return null;
    final heads = value
        .map(SpaceControlHead.fromJson)
        .whereType<SpaceControlHead>()
        .toList();
    if (heads.length != value.length) return null;
    final frontier = SpaceControlFrontier(heads);
    return frontier.isStructurallyValid ? frontier : null;
  }
}

/// A reusable causal cut stored once in the signed control log. Publications
/// reference the checkpoint entry hash instead of repeating every author head.
/// The full ordered leaves remain available for deterministic historical fold;
/// [merkleRoot] makes that set independently commitment-addressable and leaves
/// room for proof-based partial transport in a later wire version.
class SpaceControlCheckpoint {
  factory SpaceControlCheckpoint(
    Iterable<SpaceControlHead> heads, {
    String? merkleRoot,
  }) {
    final copied = List<SpaceControlHead>.unmodifiable(heads);
    return SpaceControlCheckpoint._(
      copied,
      merkleRoot ?? calculateMerkleRoot(copied),
    );
  }

  const SpaceControlCheckpoint._(this.heads, this.merkleRoot);

  final List<SpaceControlHead> heads;
  final String merkleRoot;

  bool get isStructurallyValid {
    if (heads.length > kSpaceControlCheckpointHeadsMax ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(merkleRoot)) {
      return false;
    }
    String? previous;
    for (final head in heads) {
      if (!head.isStructurallyValid ||
          (previous != null && head.author.hex.compareTo(previous) <= 0)) {
        return false;
      }
      previous = head.author.hex;
    }
    return merkleRoot == calculateMerkleRoot(heads);
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'root': merkleRoot,
    'heads': [for (final head in heads) head.toJson()],
  };

  static SpaceControlCheckpoint? fromJson(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['root'] is! String ||
        value['heads'] is! List) {
      return null;
    }
    final rawHeads = value['heads'] as List;
    final heads = rawHeads
        .map(SpaceControlHead.fromJson)
        .whereType<SpaceControlHead>()
        .toList();
    if (heads.length != rawHeads.length) return null;
    final checkpoint = SpaceControlCheckpoint(
      heads,
      merkleRoot: value['root'] as String,
    );
    return checkpoint.isStructurallyValid ? checkpoint : null;
  }

  static String calculateMerkleRoot(Iterable<SpaceControlHead> input) {
    var level = <List<int>>[
      for (final head in input)
        crypto.sha256.convert(<int>[
          0,
          ...utf8.encode(head.author.hex),
          0,
          ...utf8.encode('${head.seq}'),
          0,
          ...utf8.encode(head.hash),
        ]).bytes,
    ];
    if (level.isEmpty) {
      return crypto.sha256
          .convert(utf8.encode('xveil.space-control-checkpoint.empty.v1'))
          .toString();
    }
    while (level.length > 1) {
      final next = <List<int>>[];
      for (var index = 0; index < level.length; index += 2) {
        final left = level[index];
        final right = index + 1 < level.length ? level[index + 1] : left;
        next.add(crypto.sha256.convert(<int>[1, ...left, ...right]).bytes);
      }
      level = next;
    }
    return crypto.Digest(level.single).toString();
  }
}

enum SpacePostType {
  post,
  article,
  video,
  shortVideo,
  audio,
  voiceMessage;

  static SpacePostType? fromName(String? value) {
    for (final type in values) {
      if (type.name == value) return type;
    }
    return null;
  }
}

/// Visibility of one publication. `public` is permitted only in a public
/// Space; `members` is encrypted with the current Space membership epoch.
enum SpacePostVisibility {
  members,
  public;

  static SpacePostVisibility? fromName(String? value) {
    for (final visibility in values) {
      if (visibility.name == value) return visibility;
    }
    return null;
  }
}

/// Immutable row semantics inside an author's publication chain.
///
/// Legacy V1-V6 rows are always [publish]. V7/V8 add an explicit operation and
/// an author-local [SpacePost.targetSeq]: edits and tombstones can therefore be
/// replayed deterministically without rewriting a previously signed row.
enum SpacePostOperation {
  publish,
  edit,
  delete;

  static SpacePostOperation? fromName(String? value) {
    for (final operation in values) {
      if (operation.name == value) return operation;
    }
    return null;
  }
}

/// A content-addressed media reference shared by publication types. Bytes do
/// not ride in a post log row; they use the existing content path. This is the
/// first consumer of the common media vocabulary and deliberately avoids a
/// separate attachment model per publication kind.
class MediaObjectRef {
  const MediaObjectRef({
    required this.contentId,
    required this.kind,
    this.name,
    this.mimeType,
    this.size,
    this.width,
    this.height,
    this.durationMs,
  });

  final String contentId;
  final String kind;
  final String? name;
  final String? mimeType;
  final int? size;
  final int? width;
  final int? height;
  final int? durationMs;

  bool get isStructurallyValid =>
      contentId.isNotEmpty &&
      contentId.length <= 512 &&
      kind.isNotEmpty &&
      kind.length <= 32 &&
      (name == null || name!.length <= 255) &&
      (mimeType == null || mimeType!.length <= 128) &&
      (size == null || size! >= 0) &&
      (width == null || width! > 0) &&
      (height == null || height! > 0) &&
      (durationMs == null || durationMs! >= 0);

  Map<String, dynamic> toJson() => {
    'cid': contentId,
    'kind': kind,
    if (name != null) 'name': name,
    if (mimeType != null) 'mime': mimeType,
    if (size != null) 'size': size,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (durationMs != null) 'duration': durationMs,
  };

  static MediaObjectRef? fromJson(Object? value) {
    if (value is! Map || value['cid'] is! String || value['kind'] is! String) {
      return null;
    }
    final ref = MediaObjectRef(
      contentId: value['cid'] as String,
      kind: value['kind'] as String,
      name: value['name'] is String ? value['name'] as String : null,
      mimeType: value['mime'] is String ? value['mime'] as String : null,
      size: value['size'] is int ? value['size'] as int : null,
      width: value['width'] is int ? value['width'] as int : null,
      height: value['height'] is int ? value['height'] as int : null,
      durationMs: value['duration'] is int ? value['duration'] as int : null,
    );
    return ref.isStructurallyValid ? ref : null;
  }
}

class SpacePostCleartext {
  const SpacePostCleartext({
    required this.title,
    required this.body,
    this.media = const [],
    this.isTombstone = false,
  });

  final String title;
  final String body;
  final List<MediaObjectRef> media;
  final bool isTombstone;

  bool get isStructurallyValid =>
      title.length <= kSpacePostTitleMax &&
      body.length <= kSpacePostBodyMax &&
      media.length <= kSpacePostMediaMax &&
      media.every((item) => item.isStructurallyValid) &&
      (isTombstone
          ? title.isEmpty && body.isEmpty && media.isEmpty
          : title.trim().isNotEmpty ||
                body.trim().isNotEmpty ||
                media.isNotEmpty);

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': isTombstone ? 2 : 1,
        if (isTombstone) 'deleted': true,
        'title': title,
        'body': body,
        if (media.isNotEmpty)
          'media': media.map((item) => item.toJson()).toList(),
      }),
    ),
  );

  static SpacePostCleartext? decode(Uint8List bytes) {
    if (bytes.length > maxGroupEncryptedPayloadBytes) return null;
    try {
      final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (value is! Map ||
          (value['v'] != 1 && value['v'] != 2) ||
          value['title'] is! String ||
          value['body'] is! String ||
          (value['media'] != null && value['media'] is! List)) {
        return null;
      }
      final isTombstone = value['v'] == 2;
      if (isTombstone
          ? value['deleted'] != true
          : value.containsKey('deleted')) {
        return null;
      }
      final media = (value['media'] as List? ?? const [])
          .map(MediaObjectRef.fromJson)
          .whereType<MediaObjectRef>()
          .toList();
      if (media.length != (value['media'] as List? ?? const []).length) {
        return null;
      }
      final cleartext = SpacePostCleartext(
        title: value['title'] as String,
        body: value['body'] as String,
        media: media,
        isTombstone: isTombstone,
      );
      return cleartext.isStructurallyValid ? cleartext : null;
    } catch (_) {
      return null;
    }
  }
}

/// One immutable publication in a Space-owned per-author log.
///
/// V1/V2 are legacy public/encrypted rows authorized against current state.
/// V3/V4 add a signed causal control frontier for public/encrypted content.
/// V5/V6 replace that repeated list with one signed control-checkpoint hash.
/// V7/V8 add public/encrypted typed edit and delete rows. Moderation remains a
/// future distinct operation; author edits never rewrite signed history.
class SpacePost {
  SpacePost({
    required this.spaceId,
    required this.author,
    required this.seq,
    required this.prevHash,
    required this.type,
    required this.visibility,
    required this.title,
    required this.body,
    required this.policyVersion,
    required this.createdAtMs,
    required this.publishedAtMs,
    required this.signature,
    this.media = const [],
    this.version = 1,
    this.membershipEpoch,
    this.encryptedPayload,
    this.controlFrontier,
    this.controlCheckpointHash,
    this.operation = SpacePostOperation.publish,
    this.targetSeq,
    Uint8List? authorPubKey,
  }) : authorPubKey = authorPubKey ?? Uint8List(0);

  final NodeId spaceId;
  final NodeId author;
  final int seq;
  final String prevHash;
  final SpacePostType type;
  final SpacePostVisibility visibility;
  final String title;
  final String body;
  final List<MediaObjectRef> media;
  final int policyVersion;
  final int createdAtMs;
  final int publishedAtMs;
  final int version;
  final int? membershipEpoch;
  final GroupEncryptedPayload? encryptedPayload;
  final SpaceControlFrontier? controlFrontier;
  final String? controlCheckpointHash;
  final SpacePostOperation operation;
  final int? targetSeq;
  final Uint8List signature;
  final Uint8List authorPubKey;

  String get postId => '${author.hex}:$seq';
  bool get isEncrypted =>
      (version == 2 || version == 4 || version == 6 || version == 8) &&
      membershipEpoch != null &&
      encryptedPayload != null;
  bool get isCausal => version >= 3 && version <= 8;
  bool get isCheckpointed => version >= 5 && version <= 8;
  bool get isMutation => operation != SpacePostOperation.publish;

  bool get isStructurallyValid {
    if (seq < 0 ||
        prevHash.length > 128 ||
        policyVersion < 0 ||
        createdAtMs < 0 ||
        publishedAtMs < createdAtMs ||
        publishedAtMs >
            createdAtMs + const Duration(days: 365).inMilliseconds ||
        signature.length > 16384 ||
        authorPubKey.length > 16384) {
      return false;
    }
    if (isCausal &&
        (seq == 0
            ? prevHash.isNotEmpty
            : !RegExp(r'^[0-9a-f]{64}$').hasMatch(prevHash))) {
      return false;
    }
    final checkpointValid =
        controlCheckpointHash != null &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(controlCheckpointHash!);
    final operationValid = version <= 6
        ? operation == SpacePostOperation.publish && targetSeq == null
        : (operation == SpacePostOperation.publish
              ? targetSeq == null
              : targetSeq != null && targetSeq! >= 0 && targetSeq! < seq);
    if (!operationValid) return false;
    if (version == 1 || version == 3 || version == 5 || version == 7) {
      final contentValid = operation == SpacePostOperation.delete
          ? title.isEmpty && body.isEmpty && media.isEmpty
          : SpacePostCleartext(
              title: title,
              body: body,
              media: media,
            ).isStructurallyValid;
      return visibility == SpacePostVisibility.public &&
          membershipEpoch == null &&
          encryptedPayload == null &&
          (version == 1
              ? controlFrontier == null && controlCheckpointHash == null
              : version == 3
              ? controlFrontier?.isStructurallyValid == true &&
                    controlCheckpointHash == null
              : controlFrontier == null && checkpointValid) &&
          contentValid;
    }
    return (version == 2 || version == 4 || version == 6 || version == 8) &&
        visibility == SpacePostVisibility.members &&
        (version == 2
            ? controlFrontier == null && controlCheckpointHash == null
            : version == 4
            ? controlFrontier?.isStructurallyValid == true &&
                  controlCheckpointHash == null
            : controlFrontier == null && checkpointValid) &&
        membershipEpoch != null &&
        membershipEpoch! > 0 &&
        encryptedPayload?.isStructurallyValid == true &&
        ((title.isEmpty && body.isEmpty && media.isEmpty) ||
            SpacePostCleartext(
              title: title,
              body: body,
              media: media,
            ).isStructurallyValid);
  }

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': version,
        'sid': spaceId.hex,
        'author': author.hex,
        'seq': seq,
        'prev': prevHash,
        'type': type.name,
        'visibility': visibility.name,
        if (version == 3 || version == 4) 'frontier': controlFrontier?.toJson(),
        if (isCheckpointed) 'checkpoint': controlCheckpointHash,
        if (version >= 7) ...{
          'op': operation.name,
          if (targetSeq != null) 'target': targetSeq,
        },
        if (version == 1 || version == 3 || version == 5 || version == 7) ...{
          'title': title,
          'body': body,
          if (media.isNotEmpty)
            'media': media.map((item) => item.toJson()).toList(),
        } else ...{
          'epoch': membershipEpoch,
          'enc': encryptedPayload?.toJson(),
        },
        'pv': policyVersion,
        'created': createdAtMs,
        'published': publishedAtMs,
      }),
    ),
  );

  SpacePost withSignature(Uint8List value, Uint8List publicKey) => SpacePost(
    spaceId: spaceId,
    author: author,
    seq: seq,
    prevHash: prevHash,
    type: type,
    visibility: visibility,
    title: title,
    body: body,
    media: media,
    policyVersion: policyVersion,
    createdAtMs: createdAtMs,
    publishedAtMs: publishedAtMs,
    version: version,
    membershipEpoch: membershipEpoch,
    encryptedPayload: encryptedPayload,
    controlFrontier: controlFrontier,
    controlCheckpointHash: controlCheckpointHash,
    operation: operation,
    targetSeq: targetSeq,
    signature: value,
    authorPubKey: publicKey,
  );

  SpacePost withDecryptedContent(SpacePostCleartext cleartext) => SpacePost(
    spaceId: spaceId,
    author: author,
    seq: seq,
    prevHash: prevHash,
    type: type,
    visibility: visibility,
    title: cleartext.title,
    body: cleartext.body,
    media: cleartext.media,
    policyVersion: policyVersion,
    createdAtMs: createdAtMs,
    publishedAtMs: publishedAtMs,
    version: version,
    membershipEpoch: membershipEpoch,
    encryptedPayload: encryptedPayload,
    controlFrontier: controlFrontier,
    controlCheckpointHash: controlCheckpointHash,
    operation: operation,
    targetSeq: targetSeq,
    signature: signature,
    authorPubKey: authorPubKey,
  );

  Map<String, dynamic> toJson() => {
    'v': version,
    'sid': spaceId.hex,
    'author': author.hex,
    'seq': seq,
    'prev': prevHash,
    'type': type.name,
    'visibility': visibility.name,
    if (version == 3 || version == 4) 'frontier': controlFrontier?.toJson(),
    if (isCheckpointed) 'checkpoint': controlCheckpointHash,
    if (version >= 7) ...{
      'op': operation.name,
      if (targetSeq != null) 'target': targetSeq,
    },
    if (version == 1 || version == 3 || version == 5 || version == 7) ...{
      'title': title,
      'body': body,
      if (media.isNotEmpty)
        'media': media.map((item) => item.toJson()).toList(),
    } else ...{
      'epoch': membershipEpoch,
      'enc': encryptedPayload?.toJson(),
    },
    'pv': policyVersion,
    'created': createdAtMs,
    'published': publishedAtMs,
    'sig': base64Encode(signature),
    if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
  };

  static SpacePost? fromJson(Object? value) {
    if (value is! Map) return null;
    final version = value['v'];
    final type = SpacePostType.fromName(value['type'] as String?);
    final visibility = SpacePostVisibility.fromName(
      value['visibility'] as String?,
    );
    if ((version != 1 &&
            version != 2 &&
            version != 3 &&
            version != 4 &&
            version != 5 &&
            version != 6 &&
            version != 7 &&
            version != 8) ||
        value['sid'] is! String ||
        value['author'] is! String ||
        value['seq'] is! int ||
        value['prev'] is! String ||
        type == null ||
        visibility == null ||
        value['pv'] is! int ||
        value['created'] is! int ||
        value['published'] is! int ||
        value['sig'] is! String) {
      return null;
    }
    try {
      final rawMedia = value['media'];
      final isPublic =
          version == 1 || version == 3 || version == 5 || version == 7;
      final isEncrypted =
          version == 2 || version == 4 || version == 6 || version == 8;
      final operation = version >= 7
          ? SpacePostOperation.fromName(value['op'] as String?)
          : SpacePostOperation.publish;
      if (operation == null ||
          (version < 7 &&
              (value.containsKey('op') || value.containsKey('target'))) ||
          (version >= 7 &&
              (operation == SpacePostOperation.publish
                  ? value.containsKey('target')
                  : value['target'] is! int))) {
        return null;
      }
      if (isPublic && rawMedia != null && rawMedia is! List) return null;
      final media = isPublic
          ? (rawMedia as List? ?? const [])
                .map(MediaObjectRef.fromJson)
                .whereType<MediaObjectRef>()
                .toList()
          : const <MediaObjectRef>[];
      if (isPublic && media.length != (rawMedia as List? ?? const []).length) {
        return null;
      }
      if (isEncrypted &&
          (value.containsKey('title') ||
              value.containsKey('body') ||
              value.containsKey('media'))) {
        return null;
      }
      final post = SpacePost(
        spaceId: NodeId.fromHex(value['sid'] as String),
        author: NodeId.fromHex(value['author'] as String),
        seq: value['seq'] as int,
        prevHash: value['prev'] as String,
        type: type,
        visibility: visibility,
        title: isPublic && value['title'] is String
            ? value['title'] as String
            : '',
        body: isPublic && value['body'] is String
            ? value['body'] as String
            : '',
        media: media,
        policyVersion: value['pv'] as int,
        createdAtMs: value['created'] as int,
        publishedAtMs: value['published'] as int,
        version: version as int,
        membershipEpoch: isEncrypted && value['epoch'] is int
            ? value['epoch'] as int
            : null,
        encryptedPayload: isEncrypted
            ? GroupEncryptedPayload.fromJson(value['enc'])
            : null,
        controlFrontier: version == 3 || version == 4
            ? SpaceControlFrontier.fromJson(value['frontier'])
            : null,
        controlCheckpointHash: version == 5 || version == 6
            ? value['checkpoint'] as String?
            : version == 7 || version == 8
            ? value['checkpoint'] as String?
            : null,
        operation: operation,
        targetSeq: version >= 7 && value['target'] is int
            ? value['target'] as int
            : null,
        signature: Uint8List.fromList(base64Decode(value['sig'] as String)),
        authorPubKey: value['apk'] is String
            ? Uint8List.fromList(base64Decode(value['apk'] as String))
            : null,
      );
      return post.isStructurallyValid ? post : null;
    } catch (_) {
      return null;
    }
  }
}

/// User-facing fold of one immutable publication root and its latest accepted
/// edit. The root owns identity, chronological position and feed cursor; the
/// effective row owns the current content. Neither signed row is rewritten.
class SpacePostView {
  const SpacePostView({required this.root, required this.effective});

  final SpacePost root;
  final SpacePost effective;

  String get postId => root.postId;
  String get revisionId => effective.postId;
  NodeId get spaceId => root.spaceId;
  NodeId get author => root.author;
  int get seq => root.seq;
  int get revisionSeq => effective.seq;
  String get prevHash => root.prevHash;
  SpacePostType get type => effective.type;
  SpacePostVisibility get visibility => effective.visibility;
  String get title => effective.title;
  String get body => effective.body;
  List<MediaObjectRef> get media => effective.media;
  int get policyVersion => effective.policyVersion;
  int get createdAtMs => root.createdAtMs;
  int get publishedAtMs => root.publishedAtMs;
  int get updatedAtMs => effective.createdAtMs;
  bool get edited => effective.seq != root.seq;
}

/// Stable chronological cursor. Every tie-breaker is signed by the post, so
/// pagination cannot duplicate or skip rows merely because two clocks share a
/// millisecond.
class SpaceFeedCursor {
  const SpaceFeedCursor({
    required this.publishedAtMs,
    required this.spaceId,
    required this.author,
    required this.seq,
  });

  factory SpaceFeedCursor.fromPost(SpacePost post) => SpaceFeedCursor(
    publishedAtMs: post.publishedAtMs,
    spaceId: post.spaceId,
    author: post.author,
    seq: post.seq,
  );

  factory SpaceFeedCursor.fromView(SpacePostView post) => SpaceFeedCursor(
    publishedAtMs: post.publishedAtMs,
    spaceId: post.spaceId,
    author: post.author,
    seq: post.seq,
  );

  final int publishedAtMs;
  final NodeId spaceId;
  final NodeId author;
  final int seq;

  int compareTo(SpaceFeedCursor other) {
    final time = publishedAtMs.compareTo(other.publishedAtMs);
    if (time != 0) return time;
    final space = spaceId.hex.compareTo(other.spaceId.hex);
    if (space != 0) return space;
    final authorOrder = author.hex.compareTo(other.author.hex);
    if (authorOrder != 0) return authorOrder;
    return seq.compareTo(other.seq);
  }

  String encode() => base64Url.encode(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'ts': publishedAtMs,
        'sid': spaceId.hex,
        'author': author.hex,
        'seq': seq,
      }),
    ),
  );

  static SpaceFeedCursor? decode(String? value) {
    if (value == null || value.isEmpty || value.length > 1024) return null;
    try {
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(value))),
      );
      if (decoded is! Map ||
          decoded['v'] != 1 ||
          decoded['ts'] is! int ||
          decoded['sid'] is! String ||
          decoded['author'] is! String ||
          decoded['seq'] is! int ||
          decoded['ts'] as int < 0 ||
          decoded['seq'] as int < 0) {
        return null;
      }
      return SpaceFeedCursor(
        publishedAtMs: decoded['ts'] as int,
        spaceId: NodeId.fromHex(decoded['sid'] as String),
        author: NodeId.fromHex(decoded['author'] as String),
        seq: decoded['seq'] as int,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Device-local user preference. It is not membership authority and never
/// grants control/channel/epoch data. A future public-only subscription uses
/// the same record with [publicOnly] set, while membership remains in the
/// signed Space control log.
class SpaceSubscription {
  const SpaceSubscription({
    required this.spaceId,
    required this.feedEnabled,
    required this.notificationsEnabled,
    required this.hiddenFromRecommendations,
    required this.publicOnly,
    required this.updatedAtMs,
  });

  factory SpaceSubscription.memberDefault(NodeId spaceId) => SpaceSubscription(
    spaceId: spaceId,
    feedEnabled: true,
    notificationsEnabled: true,
    hiddenFromRecommendations: false,
    publicOnly: false,
    updatedAtMs: 0,
  );

  final NodeId spaceId;
  final bool feedEnabled;
  final bool notificationsEnabled;
  final bool hiddenFromRecommendations;
  final bool publicOnly;
  final int updatedAtMs;

  SpaceSubscription copyWith({
    bool? feedEnabled,
    bool? notificationsEnabled,
    bool? hiddenFromRecommendations,
    bool? publicOnly,
    int? updatedAtMs,
  }) => SpaceSubscription(
    spaceId: spaceId,
    feedEnabled: feedEnabled ?? this.feedEnabled,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    hiddenFromRecommendations:
        hiddenFromRecommendations ?? this.hiddenFromRecommendations,
    publicOnly: publicOnly ?? this.publicOnly,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'sid': spaceId.hex,
    'feed': feedEnabled,
    'notifications': notificationsEnabled,
    'hideRecommendations': hiddenFromRecommendations,
    'publicOnly': publicOnly,
    'updated': updatedAtMs,
  };

  static SpaceSubscription? fromJson(Object? value, NodeId expectedSpaceId) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['sid'] != expectedSpaceId.hex ||
        value['feed'] is! bool ||
        value['notifications'] is! bool ||
        value['hideRecommendations'] is! bool ||
        value['publicOnly'] is! bool ||
        value['updated'] is! int ||
        value['updated'] as int < 0) {
      return null;
    }
    return SpaceSubscription(
      spaceId: expectedSpaceId,
      feedEnabled: value['feed'] as bool,
      notificationsEnabled: value['notifications'] as bool,
      hiddenFromRecommendations: value['hideRecommendations'] as bool,
      publicOnly: value['publicOnly'] as bool,
      updatedAtMs: value['updated'] as int,
    );
  }
}
