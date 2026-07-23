import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import 'group_payload.dart';
import 'media_object.dart';
import 'message_mention.dart';

export 'media_object.dart' show MediaObject, MediaObjectRef;

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

/// Device-local, identity-scoped publication draft.
///
/// Drafts are never signed, added to the Space post log, advertised to peers,
/// or included in feed projections. The storage layer encrypts this value in
/// the active identity container; [spaceId] only scopes independent composers.
class SpacePostDraft {
  const SpacePostDraft({
    required this.spaceId,
    required this.title,
    required this.body,
    required this.type,
    required this.updatedAtMs,
    this.media = const [],
    this.scheduledAtMs,
  });

  final NodeId spaceId;
  final String title;
  final String body;
  final SpacePostType type;
  final int updatedAtMs;
  final List<MediaObject> media;
  final int? scheduledAtMs;

  bool get hasContent =>
      title.trim().isNotEmpty || body.trim().isNotEmpty || media.isNotEmpty;

  bool get isStructurallyValid =>
      title.length <= kSpacePostTitleMax &&
      body.length <= kSpacePostBodyMax &&
      media.length <= kSpacePostMediaMax &&
      media.every((item) => item.isStructurallyValid) &&
      media.map((item) => item.contentId).toSet().length == media.length &&
      updatedAtMs >= 0 &&
      (scheduledAtMs == null || scheduledAtMs! >= 0);

  Map<String, dynamic> toJson() => {
    'v': 3,
    'sid': spaceId.hex,
    'title': title,
    'body': body,
    'type': type.name,
    'updatedAt': updatedAtMs,
    if (media.isNotEmpty) 'media': [for (final item in media) item.toJson()],
    if (scheduledAtMs != null) 'scheduledAt': scheduledAtMs,
  };

  static SpacePostDraft? fromJson(Object? value, NodeId expectedSpaceId) {
    if (value is! Map ||
        (value['v'] != 1 && value['v'] != 2 && value['v'] != 3) ||
        value['sid'] != expectedSpaceId.hex ||
        value['title'] is! String ||
        value['body'] is! String ||
        value['type'] is! String ||
        value['updatedAt'] is! int ||
        (value['scheduledAt'] != null && value['scheduledAt'] is! int) ||
        (value['media'] != null && value['media'] is! List)) {
      return null;
    }
    final type = SpacePostType.fromName(value['type'] as String);
    if (type == null) return null;
    final rawMedia = value['media'] as List? ?? const [];
    final media = rawMedia
        .map(MediaObject.fromReferenceJson)
        .whereType<MediaObject>()
        .toList(growable: false);
    if (media.length != rawMedia.length) return null;
    final draft = SpacePostDraft(
      spaceId: expectedSpaceId,
      title: value['title'] as String,
      body: value['body'] as String,
      type: type,
      updatedAtMs: value['updatedAt'] as int,
      media: media,
      scheduledAtMs: value['scheduledAt'] as int?,
    );
    return draft.isStructurallyValid ? draft : null;
  }
}

enum ScheduledSpacePostStatus {
  pending,
  failed;

  static ScheduledSpacePostStatus? fromName(String? value) {
    for (final status in values) {
      if (status.name == value) return status;
    }
    return null;
  }
}

/// A future publication stored only inside the active deniable identity.
///
/// The payload is deliberately unsigned and never enters Space replication
/// before [scheduledAtMs]. At execution the service rechecks the exact
/// membership grant, lifecycle generation, policy and current ACL, then signs
/// a normal [SpacePost]. A failed job is retained for explicit review instead
/// of silently retrying after authority changes.
class ScheduledSpacePost {
  const ScheduledSpacePost({
    required this.id,
    required this.spaceId,
    required this.title,
    required this.body,
    required this.type,
    required this.queuedAtMs,
    required this.scheduledAtMs,
    required this.membershipGrant,
    required this.lifecycleGeneration,
    required this.policyVersion,
    this.media = const [],
    this.status = ScheduledSpacePostStatus.pending,
    this.publicationAtMs,
    this.lastAttemptAtMs,
  });

  final String id;
  final NodeId spaceId;
  final String title;
  final String body;
  final SpacePostType type;
  final List<MediaObject> media;
  final int queuedAtMs;
  final int scheduledAtMs;
  final String membershipGrant;
  final String lifecycleGeneration;
  final int policyVersion;
  final ScheduledSpacePostStatus status;
  final int? publicationAtMs;
  final int? lastAttemptAtMs;

  bool get hasContent =>
      title.trim().isNotEmpty || body.trim().isNotEmpty || media.isNotEmpty;

  bool get isStructurallyValid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(id) &&
      title.length <= kSpacePostTitleMax &&
      body.length <= kSpacePostBodyMax &&
      media.length <= kSpacePostMediaMax &&
      media.every((item) => item.isStructurallyValid) &&
      media.map((item) => item.contentId).toSet().length == media.length &&
      queuedAtMs >= 0 &&
      scheduledAtMs >= queuedAtMs &&
      scheduledAtMs <= queuedAtMs + const Duration(days: 365).inMilliseconds &&
      (membershipGrant == 'genesis' ||
          RegExp(r'^[0-9a-f]{64}$').hasMatch(membershipGrant)) &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(lifecycleGeneration) &&
      policyVersion >= 0 &&
      (status == ScheduledSpacePostStatus.pending
          ? lastAttemptAtMs == null
          : publicationAtMs != null &&
                lastAttemptAtMs != null &&
                lastAttemptAtMs! >= publicationAtMs!) &&
      (publicationAtMs == null || publicationAtMs! >= scheduledAtMs) &&
      hasContent;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'id': id,
    'sid': spaceId.hex,
    'title': title,
    'body': body,
    'type': type.name,
    if (media.isNotEmpty) 'media': [for (final item in media) item.toJson()],
    'queuedAt': queuedAtMs,
    'scheduledAt': scheduledAtMs,
    'grant': membershipGrant,
    'lifecycle': lifecycleGeneration,
    'pv': policyVersion,
    'status': status.name,
    if (publicationAtMs != null) 'publicationAt': publicationAtMs,
    if (lastAttemptAtMs != null) 'lastAttemptAt': lastAttemptAtMs,
  };

  static ScheduledSpacePost? fromJson(Object? value, {String? expectedId}) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['id'] is! String ||
        (expectedId != null && value['id'] != expectedId) ||
        value['sid'] is! String ||
        value['title'] is! String ||
        value['body'] is! String ||
        value['type'] is! String ||
        (value['media'] != null && value['media'] is! List) ||
        value['queuedAt'] is! int ||
        value['scheduledAt'] is! int ||
        value['grant'] is! String ||
        value['lifecycle'] is! String ||
        value['pv'] is! int ||
        value['status'] is! String ||
        (value['publicationAt'] != null && value['publicationAt'] is! int) ||
        (value['lastAttemptAt'] != null && value['lastAttemptAt'] is! int)) {
      return null;
    }
    final type = SpacePostType.fromName(value['type'] as String);
    final status = ScheduledSpacePostStatus.fromName(value['status'] as String);
    if (type == null || status == null) return null;
    final rawMedia = value['media'] as List? ?? const [];
    final media = rawMedia
        .map(MediaObject.fromReferenceJson)
        .whereType<MediaObject>()
        .toList(growable: false);
    if (media.length != rawMedia.length) return null;
    try {
      final scheduled = ScheduledSpacePost(
        id: value['id'] as String,
        spaceId: NodeId.fromHex(value['sid'] as String),
        title: value['title'] as String,
        body: value['body'] as String,
        type: type,
        media: media,
        queuedAtMs: value['queuedAt'] as int,
        scheduledAtMs: value['scheduledAt'] as int,
        membershipGrant: value['grant'] as String,
        lifecycleGeneration: value['lifecycle'] as String,
        policyVersion: value['pv'] as int,
        status: status,
        publicationAtMs: value['publicationAt'] as int?,
        lastAttemptAtMs: value['lastAttemptAt'] as int?,
      );
      return scheduled.isStructurallyValid ? scheduled : null;
    } catch (_) {
      return null;
    }
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

/// One community-wide pin state carried by the signed Space control log.
///
/// The exact root hash prevents an early or replayed control row from pinning a
/// different publication that later happens to reuse the same author/sequence
/// identity. The control entry also binds [changedAtMs] to its signed timestamp.
class SpacePostPin {
  const SpacePostPin({
    required this.spaceId,
    required this.postAuthor,
    required this.postSeq,
    required this.rootHash,
    required this.pinned,
    required this.changedAtMs,
  });

  final NodeId spaceId;
  final NodeId postAuthor;
  final int postSeq;
  final String rootHash;
  final bool pinned;
  final int changedAtMs;

  String get postId => '${postAuthor.hex}:$postSeq';

  bool get isStructurallyValid =>
      postSeq >= 0 &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(rootHash) &&
      changedAtMs >= 0;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'sid': spaceId.hex,
    'author': postAuthor.hex,
    'seq': postSeq,
    'root': rootHash,
    'pinned': pinned,
    'ts': changedAtMs,
  };

  static SpacePostPin? fromJson(Object? value) {
    if (value is! Map ||
        value.length != 7 ||
        !const {
          'v',
          'sid',
          'author',
          'seq',
          'root',
          'pinned',
          'ts',
        }.every(value.containsKey) ||
        value['v'] != 1 ||
        value['sid'] is! String ||
        value['author'] is! String ||
        value['seq'] is! int ||
        value['root'] is! String ||
        value['pinned'] is! bool ||
        value['ts'] is! int) {
      return null;
    }
    try {
      final pin = SpacePostPin(
        spaceId: NodeId.fromHex(value['sid'] as String),
        postAuthor: NodeId.fromHex(value['author'] as String),
        postSeq: value['seq'] as int,
        rootHash: value['root'] as String,
        pinned: value['pinned'] as bool,
        changedAtMs: value['ts'] as int,
      );
      return pin.isStructurallyValid ? pin : null;
    } catch (_) {
      return null;
    }
  }
}

/// Decrypted publication content. Media bytes do not ride in the post log row;
/// [MediaObject] carries strict references into the shared content path.
class SpacePostCleartext {
  const SpacePostCleartext({
    required this.title,
    required this.body,
    this.media = const [],
    this.isTombstone = false,
  });

  final String title;
  final String body;
  final List<MediaObject> media;
  final bool isTombstone;

  bool get isStructurallyValid =>
      title.length <= kSpacePostTitleMax &&
      body.length <= kSpacePostBodyMax &&
      media.length <= kSpacePostMediaMax &&
      media.every((item) => item.isStructurallyValid) &&
      media.map((item) => item.contentId).toSet().length == media.length &&
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
          .map(MediaObject.fromReferenceJson)
          .whereType<MediaObject>()
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
/// V7/V8 add public/encrypted typed edit and delete rows. V9/V10 add an exact
/// lifecycle generation so a stale offline suffix authored during archive can
/// never join the post-restore chain.
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
    this.lifecycleGeneration,
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
  final List<MediaObject> media;
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
  final String? lifecycleGeneration;
  final Uint8List signature;
  final Uint8List authorPubKey;

  String get postId => '${author.hex}:$seq';
  bool get isEncrypted =>
      (version == 2 ||
          version == 4 ||
          version == 6 ||
          version == 8 ||
          version == 10) &&
      membershipEpoch != null &&
      encryptedPayload != null;
  bool get isCausal => version >= 3 && version <= 10;
  bool get isCheckpointed => version >= 5 && version <= 10;
  bool get isLifecycleScoped => version == 9 || version == 10;
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
        !isLifecycleScoped &&
        (seq == 0
            ? prevHash.isNotEmpty
            : !RegExp(r'^[0-9a-f]{64}$').hasMatch(prevHash))) {
      return false;
    }
    if (isLifecycleScoped &&
        (lifecycleGeneration == null ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(lifecycleGeneration!) ||
            (prevHash.isNotEmpty &&
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(prevHash)))) {
      return false;
    }
    if (!isLifecycleScoped && lifecycleGeneration != null) return false;
    final checkpointValid =
        controlCheckpointHash != null &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(controlCheckpointHash!);
    final operationValid = version <= 6
        ? operation == SpacePostOperation.publish && targetSeq == null
        : (operation == SpacePostOperation.publish
              ? targetSeq == null
              : targetSeq != null && targetSeq! >= 0 && targetSeq! < seq);
    if (!operationValid) return false;
    if (version == 1 ||
        version == 3 ||
        version == 5 ||
        version == 7 ||
        version == 9) {
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
    return (version == 2 ||
            version == 4 ||
            version == 6 ||
            version == 8 ||
            version == 10) &&
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
        if (isLifecycleScoped) 'lifecycle': lifecycleGeneration,
        if (version >= 7) ...{
          'op': operation.name,
          if (targetSeq != null) 'target': targetSeq,
        },
        if (version == 1 ||
            version == 3 ||
            version == 5 ||
            version == 7 ||
            version == 9) ...{
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
    lifecycleGeneration: lifecycleGeneration,
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
    lifecycleGeneration: lifecycleGeneration,
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
    if (isLifecycleScoped) 'lifecycle': lifecycleGeneration,
    if (version >= 7) ...{
      'op': operation.name,
      if (targetSeq != null) 'target': targetSeq,
    },
    if (version == 1 ||
        version == 3 ||
        version == 5 ||
        version == 7 ||
        version == 9) ...{
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
            version != 8 &&
            version != 9 &&
            version != 10) ||
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
          version == 1 ||
          version == 3 ||
          version == 5 ||
          version == 7 ||
          version == 9;
      final isEncrypted =
          version == 2 ||
          version == 4 ||
          version == 6 ||
          version == 8 ||
          version == 10;
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
                .map(MediaObject.fromReferenceJson)
                .whereType<MediaObject>()
                .toList()
          : const <MediaObject>[];
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
        controlCheckpointHash: version >= 5 && version <= 10
            ? value['checkpoint'] as String?
            : null,
        operation: operation,
        targetSeq: version >= 7 && value['target'] is int
            ? value['target'] as int
            : null,
        lifecycleGeneration: version == 9 || version == 10
            ? value['lifecycle'] as String?
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
  const SpacePostView({
    required this.root,
    required this.effective,
    this.pinned = false,
    this.pinnedAtMs,
    this.mediaHiddenByRetention = false,
  });

  final SpacePost root;
  final SpacePost effective;
  final bool pinned;
  final int? pinnedAtMs;

  /// Projection-only state; [root] and [effective] remain the exact immutable
  /// signed rows used for verification and replication.
  final bool mediaHiddenByRetention;

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
  List<MediaObject> get media =>
      mediaHiddenByRetention ? const <MediaObject>[] : effective.media;
  int get policyVersion => effective.policyVersion;
  int get createdAtMs => root.createdAtMs;
  int get publishedAtMs => root.publishedAtMs;
  int get updatedAtMs => effective.createdAtMs;
  bool get edited => effective.seq != root.seq;

  SpacePostView withPin({required bool pinned, int? pinnedAtMs}) =>
      SpacePostView(
        root: root,
        effective: effective,
        pinned: pinned,
        pinnedAtMs: pinned ? pinnedAtMs : null,
        mediaHiddenByRetention: mediaHiddenByRetention,
      );

  SpacePostView withMediaHiddenByRetention() => mediaHiddenByRetention
      ? this
      : SpacePostView(
          root: root,
          effective: effective,
          pinned: pinned,
          pinnedAtMs: pinnedAtMs,
          mediaHiddenByRetention: true,
        );
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

enum SpaceFeedTimePreset {
  all,
  lastHour,
  lastDay,
  lastWeek,
  lastMonth,
  custom;

  static SpaceFeedTimePreset? fromName(Object? value) => value is String
      ? SpaceFeedTimePreset.values
            .where((preset) => preset.name == value)
            .firstOrNull
      : null;
}

/// Device-local, identity-scoped filters for the merged publication Feed.
///
/// Empty [spaceIds] means every subscribed community. Relative time presets
/// are stored symbolically and recalculated when the Feed is opened, while a
/// custom interval stores absolute inclusive millisecond bounds.
class SpaceFeedFilter {
  SpaceFeedFilter({
    required Set<SpacePostType> types,
    this.mentionsOnly = false,
    this.timePreset = SpaceFeedTimePreset.all,
    this.customFromMs,
    this.customToMs,
    Set<NodeId> spaceIds = const {},
  }) : types = Set<SpacePostType>.unmodifiable(
         types.isEmpty ? SpacePostType.values : types,
       ),
       spaceIds = Set<NodeId>.unmodifiable(spaceIds);

  factory SpaceFeedFilter.defaults() =>
      SpaceFeedFilter(types: SpacePostType.values.toSet());

  final Set<SpacePostType> types;
  final bool mentionsOnly;
  final SpaceFeedTimePreset timePreset;
  final int? customFromMs;
  final int? customToMs;
  final Set<NodeId> spaceIds;

  bool get isStructurallyValid =>
      spaceIds.length <= 4096 &&
      (timePreset != SpaceFeedTimePreset.custom ||
          (customFromMs != null &&
              customToMs != null &&
              customFromMs! >= 0 &&
              customToMs! >= customFromMs!));

  bool get isDefault =>
      types.length == SpacePostType.values.length &&
      !mentionsOnly &&
      timePreset == SpaceFeedTimePreset.all &&
      spaceIds.isEmpty;

  int get activeDimensionCount =>
      (types.length == SpacePostType.values.length ? 0 : 1) +
      (mentionsOnly ? 1 : 0) +
      (timePreset == SpaceFeedTimePreset.all ? 0 : 1) +
      (spaceIds.isEmpty ? 0 : 1);

  SpaceFeedFilter copyWith({
    Set<SpacePostType>? types,
    bool? mentionsOnly,
    SpaceFeedTimePreset? timePreset,
    int? customFromMs,
    int? customToMs,
    bool clearCustomRange = false,
    Set<NodeId>? spaceIds,
  }) => SpaceFeedFilter(
    types: types ?? this.types,
    mentionsOnly: mentionsOnly ?? this.mentionsOnly,
    timePreset: timePreset ?? this.timePreset,
    customFromMs: clearCustomRange ? null : customFromMs ?? this.customFromMs,
    customToMs: clearCustomRange ? null : customToMs ?? this.customToMs,
    spaceIds: spaceIds ?? this.spaceIds,
  );

  ({int? fromMs, int? toMs}) windowAt(int nowMs) => switch (timePreset) {
    SpaceFeedTimePreset.all => (fromMs: null, toMs: null),
    SpaceFeedTimePreset.lastHour => (
      fromMs: nowMs - const Duration(hours: 1).inMilliseconds,
      toMs: null,
    ),
    SpaceFeedTimePreset.lastDay => (
      fromMs: nowMs - const Duration(days: 1).inMilliseconds,
      toMs: null,
    ),
    SpaceFeedTimePreset.lastWeek => (
      fromMs: nowMs - const Duration(days: 7).inMilliseconds,
      toMs: null,
    ),
    SpaceFeedTimePreset.lastMonth => (
      fromMs: nowMs - const Duration(days: 30).inMilliseconds,
      toMs: null,
    ),
    SpaceFeedTimePreset.custom => (fromMs: customFromMs, toMs: customToMs),
  };

  bool allowsPost(
    SpacePostView post, {
    required NodeId viewer,
    required int nowMs,
  }) {
    if (!types.contains(post.type) ||
        (spaceIds.isNotEmpty && !spaceIds.contains(post.spaceId))) {
      return false;
    }
    final window = windowAt(nowMs);
    final from = window.fromMs;
    if (from != null && post.publishedAtMs < from) {
      return false;
    }
    final to = window.toMs;
    if (to != null && post.publishedAtMs > to) {
      return false;
    }
    if (mentionsOnly &&
        (post.author == viewer ||
            !messageMentionsNode('${post.title}\n${post.body}', viewer))) {
      return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() {
    final spaces = [for (final id in spaceIds) id.hex]..sort();
    return {
      'v': 2,
      'types': [
        for (final type in SpacePostType.values)
          if (types.contains(type)) type.name,
      ],
      'mentionsOnly': mentionsOnly,
      'timePreset': timePreset.name,
      if (timePreset == SpaceFeedTimePreset.custom) ...{
        'fromMs': customFromMs,
        'toMs': customToMs,
      },
      'spaces': spaces,
    };
  }

  /// Reads both the original type-only v1 record and the complete v2 filter.
  static SpaceFeedFilter? fromJson(Object? value) {
    if (value is! Map ||
        (value['v'] != 1 && value['v'] != 2) ||
        value['types'] is! List) {
      return null;
    }
    final types = <SpacePostType>{};
    for (final name in value['types'] as List) {
      final type = SpacePostType.fromName(name is String ? name : null);
      if (type == null) return null;
      types.add(type);
    }
    if (types.isEmpty) types.addAll(SpacePostType.values);
    if (value['v'] == 1) return SpaceFeedFilter(types: types);

    final mentionsOnly = value['mentionsOnly'];
    final preset = SpaceFeedTimePreset.fromName(value['timePreset']);
    final spacesValue = value['spaces'];
    if (mentionsOnly is! bool ||
        preset == null ||
        spacesValue is! List ||
        spacesValue.length > 4096) {
      return null;
    }
    final spaces = <NodeId>{};
    try {
      for (final item in spacesValue) {
        if (item is! String) return null;
        spaces.add(NodeId.fromHex(item));
      }
    } catch (_) {
      return null;
    }
    final fromMs = value['fromMs'];
    final toMs = value['toMs'];
    if ((fromMs != null && (fromMs is! int || fromMs < 0)) ||
        (toMs != null && (toMs is! int || toMs < 0))) {
      return null;
    }
    if (preset == SpaceFeedTimePreset.custom &&
        (fromMs is! int || toMs is! int || fromMs > toMs)) {
      return null;
    }
    return SpaceFeedFilter(
      types: types,
      mentionsOnly: mentionsOnly,
      timePreset: preset,
      customFromMs: fromMs as int?,
      customToMs: toMs as int?,
      spaceIds: spaces,
    );
  }
}

/// Device-local user preference. It is not membership authority and never
/// grants control/channel/epoch data. A future public-only subscription uses
/// the same record with [publicOnly] set, while membership remains in the
/// signed Space control log.
enum SpaceCommentNotificationMode {
  all,
  replies,
  none;

  static SpaceCommentNotificationMode? fromName(Object? value) =>
      value is String
      ? SpaceCommentNotificationMode.values
            .where((mode) => mode.name == value)
            .firstOrNull
      : null;
}

class SpaceSubscription {
  const SpaceSubscription({
    required this.spaceId,
    required this.feedEnabled,
    required this.notificationsEnabled,
    required this.commentNotifications,
    required this.hiddenFromRecommendations,
    required this.publicOnly,
    required this.updatedAtMs,
  });

  factory SpaceSubscription.memberDefault(NodeId spaceId) => SpaceSubscription(
    spaceId: spaceId,
    feedEnabled: true,
    notificationsEnabled: true,
    commentNotifications: SpaceCommentNotificationMode.replies,
    hiddenFromRecommendations: false,
    publicOnly: false,
    updatedAtMs: 0,
  );

  factory SpaceSubscription.publicDefault(NodeId spaceId) => SpaceSubscription(
    spaceId: spaceId,
    feedEnabled: true,
    notificationsEnabled: true,
    // Public comments are not projected yet. Mentions in owner/author-signed
    // public posts still follow the publication notification policy.
    commentNotifications: SpaceCommentNotificationMode.none,
    hiddenFromRecommendations: false,
    publicOnly: true,
    updatedAtMs: 0,
  );

  final NodeId spaceId;
  final bool feedEnabled;
  final bool notificationsEnabled;
  final SpaceCommentNotificationMode commentNotifications;
  final bool hiddenFromRecommendations;
  final bool publicOnly;
  final int updatedAtMs;

  SpaceSubscription copyWith({
    bool? feedEnabled,
    bool? notificationsEnabled,
    SpaceCommentNotificationMode? commentNotifications,
    bool? hiddenFromRecommendations,
    bool? publicOnly,
    int? updatedAtMs,
  }) => SpaceSubscription(
    spaceId: spaceId,
    feedEnabled: feedEnabled ?? this.feedEnabled,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    commentNotifications: commentNotifications ?? this.commentNotifications,
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
    'commentNotifications': commentNotifications.name,
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
    final commentNotifications = value.containsKey('commentNotifications')
        ? SpaceCommentNotificationMode.fromName(value['commentNotifications'])
        : (value['notifications'] as bool
              ? SpaceCommentNotificationMode.replies
              : SpaceCommentNotificationMode.none);
    if (commentNotifications == null) return null;
    return SpaceSubscription(
      spaceId: expectedSpaceId,
      feedEnabled: value['feed'] as bool,
      notificationsEnabled: value['notifications'] as bool,
      commentNotifications: commentNotifications,
      hiddenFromRecommendations: value['hideRecommendations'] as bool,
      publicOnly: value['publicOnly'] as bool,
      updatedAtMs: value['updated'] as int,
    );
  }
}
