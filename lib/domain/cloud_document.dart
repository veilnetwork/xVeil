import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';

enum CloudDocumentKind {
  note,
  taskList,
  calendar,

  /// A shared folder: a live collection of file references (name + content id
  /// + size + mime + path) replicated to the member circle by the same
  /// epoch-encrypted operation log. The actual file bytes travel a separate
  /// member-authorized content path, so revoke (which rotates the epoch)
  /// instantly cuts a removed member off from future byte pulls.
  fileCollection;

  static CloudDocumentKind? fromName(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

enum CloudDocumentRole {
  owner,
  editor,
  viewer;

  static CloudDocumentRole? fromName(String? value) {
    for (final role in values) {
      if (role.name == value) return role;
    }
    return null;
  }
}

enum CloudDocumentControlOp {
  grant,
  setRole,
  revoke,
  rotateEpoch;

  static CloudDocumentControlOp? fromName(String? value) {
    for (final op in values) {
      if (op.name == value) return op;
    }
    return null;
  }
}

final RegExp _hex32 = RegExp(r'^[0-9a-f]{64}$');
final RegExp _wireName = RegExp(r'^[a-zA-Z0-9._-]{1,64}$');

bool _isHex32(String value) => _hex32.hasMatch(value);

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// Hash of a complete signed record. Author chains bind this value rather
/// than canonical bytes alone, so replacing either the public key or signature
/// also changes every descendant.
String cloudDocumentRecordHash({
  required String domain,
  required Uint8List canonicalBytes,
  required Uint8List authorPubKey,
  required Uint8List signature,
}) {
  final digest = crypto.sha256.convert([
    ...utf8.encode('xveil.cloud-document.$domain.v1\u0000'),
    ...canonicalBytes,
    ...authorPubKey,
    ...signature,
  ]);
  return _hex(digest.bytes);
}

class CloudDocumentRoot {
  CloudDocumentRoot({
    required this.documentId,
    required this.owner,
    required this.ownerPubKey,
    required this.kind,
    required this.codec,
    required this.epochKeyCommitment,
    required this.epochEnvelopeHash,
    required this.controlLogRoot,
    required this.createdAtMs,
    required this.signature,
    this.version = 1,
    this.generation = 0,
    this.predecessorRootHash = '',
    this.baseEpoch = 0,
    Map<String, CloudDocumentRole>? baseMembers,
    Map<String, CloudDocumentAuthorHead>? baseAuthorFrontier,
    this.baseControlSeq = -1,
    String? baseControlHash,
  }) : baseMembers = Map.unmodifiable(
         baseMembers ?? {owner.hex: CloudDocumentRole.owner},
       ),
       baseAuthorFrontier = Map.unmodifiable(baseAuthorFrontier ?? const {}),
       baseControlHash = baseControlHash ?? controlLogRoot;

  final int version;
  final NodeId documentId;
  final NodeId owner;
  final Uint8List ownerPubKey;
  final CloudDocumentKind kind;
  final String codec;
  final String epochKeyCommitment;
  final String epochEnvelopeHash;
  final String controlLogRoot;
  final int createdAtMs;
  final Uint8List signature;
  final int generation;
  final String predecessorRootHash;
  final int baseEpoch;
  final Map<String, CloudDocumentRole> baseMembers;
  final Map<String, CloudDocumentAuthorHead> baseAuthorFrontier;
  final int baseControlSeq;
  final String baseControlHash;

  Uint8List canonicalBytes() {
    final value = version == 1
        ? <String, dynamic>{
            'v': version,
            'did': documentId.hex,
            'owner': owner.hex,
            'kind': kind.name,
            'codec': codec,
            'epoch': 0,
            'ekc': epochKeyCommitment,
            'ekh': epochEnvelopeHash,
            'control': controlLogRoot,
            'ts': createdAtMs,
          }
        : <String, dynamic>{
            'v': version,
            'did': documentId.hex,
            'owner': owner.hex,
            'kind': kind.name,
            'codec': codec,
            'epoch': baseEpoch,
            'ekc': epochKeyCommitment,
            'ekh': epochEnvelopeHash,
            'control': controlLogRoot,
            'ts': createdAtMs,
            'gen': generation,
            'prevRoot': predecessorRootHash,
            'members': _membersJson(baseMembers),
            'authors': _frontierJson(baseAuthorFrontier),
            'controlSeq': baseControlSeq,
            'controlHash': baseControlHash,
          };
    return Uint8List.fromList(utf8.encode(jsonEncode(value)));
  }

  String get recordHash => cloudDocumentRecordHash(
    domain: 'root',
    canonicalBytes: canonicalBytes(),
    authorPubKey: ownerPubKey,
    signature: signature,
  );

  /// [pubKey] is excluded from canonical bytes like operation author keys;
  /// verification binds it to [owner] as BLAKE3(pubKey), so substitution is
  /// impossible without also changing the signed owner node id.
  CloudDocumentRoot withSignature(Uint8List value, Uint8List pubKey) =>
      CloudDocumentRoot(
        documentId: documentId,
        owner: owner,
        ownerPubKey: pubKey,
        kind: kind,
        codec: codec,
        epochKeyCommitment: epochKeyCommitment,
        epochEnvelopeHash: epochEnvelopeHash,
        controlLogRoot: controlLogRoot,
        createdAtMs: createdAtMs,
        signature: value,
        version: version,
        generation: generation,
        predecessorRootHash: predecessorRootHash,
        baseEpoch: baseEpoch,
        baseMembers: baseMembers,
        baseAuthorFrontier: baseAuthorFrontier,
        baseControlSeq: baseControlSeq,
        baseControlHash: baseControlHash,
      );

  Map<String, dynamic> toJson() => version == 1
      ? {
          'v': version,
          'did': documentId.hex,
          'owner': owner.hex,
          'opk': base64Encode(ownerPubKey),
          'kind': kind.name,
          'codec': codec,
          'epoch': 0,
          'ekc': epochKeyCommitment,
          'ekh': epochEnvelopeHash,
          'control': controlLogRoot,
          'ts': createdAtMs,
          'sig': base64Encode(signature),
        }
      : {
          'v': version,
          'did': documentId.hex,
          'owner': owner.hex,
          'opk': base64Encode(ownerPubKey),
          'kind': kind.name,
          'codec': codec,
          'epoch': baseEpoch,
          'ekc': epochKeyCommitment,
          'ekh': epochEnvelopeHash,
          'control': controlLogRoot,
          'ts': createdAtMs,
          'gen': generation,
          'prevRoot': predecessorRootHash,
          'members': _membersJson(baseMembers),
          'authors': _frontierJson(baseAuthorFrontier),
          'controlSeq': baseControlSeq,
          'controlHash': baseControlHash,
          'sig': base64Encode(signature),
        };

  static CloudDocumentRoot? fromJson(Object? value) {
    if (value is! Map || (value['v'] != 1 && value['v'] != 2)) return null;
    final version = value['v'] as int;
    if (version == 1 && value['epoch'] != 0) return null;
    final did = value['did'];
    final owner = value['owner'];
    final ownerPk = value['opk'];
    final rawKind = value['kind'];
    final kind = CloudDocumentKind.fromName(rawKind is String ? rawKind : null);
    final codec = value['codec'];
    final commitment = value['ekc'];
    final envelopeHash = value['ekh'];
    final controlRoot = value['control'];
    final baseEpoch = value['epoch'];
    final timestamp = value['ts'];
    final signature = value['sig'];
    final generation = version == 1 ? 0 : value['gen'];
    final predecessor = version == 1 ? '' : value['prevRoot'];
    final baseMembers = version == 1 ? null : _parseMembers(value['members']);
    final authorFrontier = version == 1
        ? null
        : _parseFrontier(value['authors']);
    final controlSeq = version == 1 ? -1 : value['controlSeq'];
    final controlHash = version == 1 ? controlRoot : value['controlHash'];
    if (did is! String ||
        owner is! String ||
        ownerPk is! String ||
        kind == null ||
        codec is! String ||
        !_wireName.hasMatch(codec) ||
        commitment is! String ||
        !_isHex32(commitment) ||
        envelopeHash is! String ||
        !_isHex32(envelopeHash) ||
        controlRoot is! String ||
        !_isHex32(controlRoot) ||
        baseEpoch is! int ||
        baseEpoch < 0 ||
        timestamp is! int ||
        timestamp < 0 ||
        generation is! int ||
        generation < 0 ||
        predecessor is! String ||
        (version == 2 && !_isHex32(predecessor)) ||
        (version == 2 && baseMembers == null) ||
        (version == 2 && authorFrontier == null) ||
        controlSeq is! int ||
        controlSeq < -1 ||
        controlHash is! String ||
        !_isHex32(controlHash) ||
        signature is! String) {
      return null;
    }
    try {
      final pk = Uint8List.fromList(base64Decode(ownerPk));
      final sig = Uint8List.fromList(base64Decode(signature));
      if (pk.length != 32 || sig.length != 64) return null;
      final root = CloudDocumentRoot(
        documentId: NodeId.fromHex(did),
        owner: NodeId.fromHex(owner),
        ownerPubKey: pk,
        kind: kind,
        codec: codec,
        epochKeyCommitment: commitment,
        epochEnvelopeHash: envelopeHash,
        controlLogRoot: controlRoot,
        createdAtMs: timestamp,
        signature: sig,
        version: version,
        generation: generation,
        predecessorRootHash: predecessor,
        baseEpoch: baseEpoch,
        baseMembers: baseMembers,
        baseAuthorFrontier: authorFrontier,
        baseControlSeq: controlSeq,
        baseControlHash: controlHash,
      );
      return _validRootShape(root) ? root : null;
    } catch (_) {
      return null;
    }
  }
}

class CloudDocumentAuthorHead {
  const CloudDocumentAuthorHead({required this.seq, required this.hash});

  final int seq;
  final String hash;

  Map<String, dynamic> toJson() => {'seq': seq, 'hash': hash};

  static CloudDocumentAuthorHead? fromJson(Object? value) {
    if (value is! Map) return null;
    final seq = value['seq'];
    final hash = value['hash'];
    if (seq is! int || seq < 0 || hash is! String || !_isHex32(hash)) {
      return null;
    }
    return CloudDocumentAuthorHead(seq: seq, hash: hash);
  }

  @override
  bool operator ==(Object other) =>
      other is CloudDocumentAuthorHead &&
      seq == other.seq &&
      hash == other.hash;

  @override
  int get hashCode => Object.hash(seq, hash);
}

Map<String, dynamic> _membersJson(Map<String, CloudDocumentRole> members) {
  final keys = members.keys.toList()..sort();
  return {for (final key in keys) key: members[key]!.name};
}

Map<String, CloudDocumentRole>? _parseMembers(Object? value) {
  if (value is! Map || value.isEmpty || value.length > 256) return null;
  final result = <String, CloudDocumentRole>{};
  for (final entry in value.entries) {
    if (entry.key is! String || !_isHex32(entry.key as String)) return null;
    final role = CloudDocumentRole.fromName(
      entry.value is String ? entry.value as String : null,
    );
    if (role == null) return null;
    result[entry.key as String] = role;
  }
  return result;
}

Map<String, dynamic> _frontierJson(
  Map<String, CloudDocumentAuthorHead> frontier,
) {
  final keys = frontier.keys.toList()..sort();
  return {for (final key in keys) key: frontier[key]!.toJson()};
}

Map<String, CloudDocumentAuthorHead>? _parseFrontier(Object? value) {
  if (value is! Map || value.length > 256) return null;
  final result = <String, CloudDocumentAuthorHead>{};
  for (final entry in value.entries) {
    if (entry.key is! String || !_isHex32(entry.key as String)) return null;
    final head = CloudDocumentAuthorHead.fromJson(entry.value);
    if (head == null) return null;
    result[entry.key as String] = head;
  }
  return result;
}

class CloudDocumentControlEntry {
  CloudDocumentControlEntry({
    required this.documentId,
    required this.author,
    required this.seq,
    required this.prevControlHash,
    required this.controlId,
    required this.membershipEpoch,
    required this.nextEpoch,
    required this.op,
    required this.target,
    required this.role,
    required this.epochKeyCommitment,
    required this.epochEnvelopeHash,
    required this.closedEpochFrontier,
    required this.createdAtMs,
    required this.authorPubKey,
    required this.signature,
  });

  final NodeId documentId;
  final NodeId author;
  final int seq;
  final String prevControlHash;
  final String controlId;
  final int membershipEpoch;
  final int nextEpoch;
  final CloudDocumentControlOp op;
  final NodeId? target;
  final CloudDocumentRole? role;
  final String epochKeyCommitment;
  final String epochEnvelopeHash;
  final Map<String, CloudDocumentAuthorHead> closedEpochFrontier;
  final int createdAtMs;
  final Uint8List authorPubKey;
  final Uint8List signature;

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'did': documentId.hex,
        'author': author.hex,
        'seq': seq,
        'prev': prevControlHash,
        'id': controlId,
        'epoch': membershipEpoch,
        'next': nextEpoch,
        'op': op.name,
        if (target != null) 'target': target!.hex,
        if (role != null) 'role': role!.name,
        'ekc': epochKeyCommitment,
        'ekh': epochEnvelopeHash,
        'frontier': _frontierJson(closedEpochFrontier),
        'ts': createdAtMs,
      }),
    ),
  );

  CloudDocumentControlEntry withSignature(Uint8List sig, Uint8List pubKey) =>
      CloudDocumentControlEntry(
        documentId: documentId,
        author: author,
        seq: seq,
        prevControlHash: prevControlHash,
        controlId: controlId,
        membershipEpoch: membershipEpoch,
        nextEpoch: nextEpoch,
        op: op,
        target: target,
        role: role,
        epochKeyCommitment: epochKeyCommitment,
        epochEnvelopeHash: epochEnvelopeHash,
        closedEpochFrontier: closedEpochFrontier,
        createdAtMs: createdAtMs,
        authorPubKey: pubKey,
        signature: sig,
      );

  String get recordHash => cloudDocumentRecordHash(
    domain: 'control',
    canonicalBytes: canonicalBytes(),
    authorPubKey: authorPubKey,
    signature: signature,
  );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'did': documentId.hex,
    'author': author.hex,
    'seq': seq,
    'prev': prevControlHash,
    'id': controlId,
    'epoch': membershipEpoch,
    'next': nextEpoch,
    'op': op.name,
    if (target != null) 'target': target!.hex,
    if (role != null) 'role': role!.name,
    'ekc': epochKeyCommitment,
    'ekh': epochEnvelopeHash,
    'frontier': _frontierJson(closedEpochFrontier),
    'ts': createdAtMs,
    'apk': base64Encode(authorPubKey),
    'sig': base64Encode(signature),
  };

  static CloudDocumentControlEntry? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final did = value['did'];
    final author = value['author'];
    final seq = value['seq'];
    final prev = value['prev'];
    final id = value['id'];
    final epoch = value['epoch'];
    final next = value['next'];
    final rawOp = value['op'];
    final op = CloudDocumentControlOp.fromName(rawOp is String ? rawOp : null);
    final commitment = value['ekc'];
    final envelopeHash = value['ekh'];
    final frontier = _parseFrontier(value['frontier']);
    final timestamp = value['ts'];
    final publicKey = value['apk'];
    final signature = value['sig'];
    if (did is! String ||
        author is! String ||
        seq is! int ||
        seq < 0 ||
        prev is! String ||
        (prev.isNotEmpty && !_isHex32(prev)) ||
        id is! String ||
        !_isHex32(id) ||
        epoch is! int ||
        epoch < 0 ||
        next is! int ||
        next != epoch + 1 ||
        op == null ||
        commitment is! String ||
        !_isHex32(commitment) ||
        envelopeHash is! String ||
        !_isHex32(envelopeHash) ||
        frontier == null ||
        timestamp is! int ||
        timestamp < 0 ||
        publicKey is! String ||
        signature is! String) {
      return null;
    }
    try {
      if (value.containsKey('target') && value['target'] is! String) {
        return null;
      }
      if (value.containsKey('role') && value['role'] is! String) return null;
      final target = value['target'] is String
          ? NodeId.fromHex(value['target'] as String)
          : null;
      final rawRole = value['role'];
      final role = CloudDocumentRole.fromName(
        rawRole is String ? rawRole : null,
      );
      final pk = Uint8List.fromList(base64Decode(publicKey));
      final sig = Uint8List.fromList(base64Decode(signature));
      if (pk.length != 32 || sig.length != 64) return null;
      return CloudDocumentControlEntry(
        documentId: NodeId.fromHex(did),
        author: NodeId.fromHex(author),
        seq: seq,
        prevControlHash: prev,
        controlId: id,
        membershipEpoch: epoch,
        nextEpoch: next,
        op: op,
        target: target,
        role: role,
        epochKeyCommitment: commitment,
        epochEnvelopeHash: envelopeHash,
        closedEpochFrontier: frontier,
        createdAtMs: timestamp,
        authorPubKey: pk,
        signature: sig,
      );
    } catch (_) {
      return null;
    }
  }
}

class CloudDocumentOperation {
  CloudDocumentOperation({
    required this.documentId,
    required this.membershipEpoch,
    required this.author,
    required this.seq,
    required this.prevAuthorHash,
    required this.operationId,
    required this.parentOperationIds,
    required this.opType,
    required this.payloadHash,
    required this.createdAtMs,
    required this.authorPubKey,
    required this.signature,
  });

  final NodeId documentId;
  final int membershipEpoch;
  final NodeId author;
  final int seq;
  final String prevAuthorHash;
  final String operationId;
  final List<String> parentOperationIds;
  final String opType;
  final String payloadHash;
  final int createdAtMs;
  final Uint8List authorPubKey;
  final Uint8List signature;

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'did': documentId.hex,
        'epoch': membershipEpoch,
        'author': author.hex,
        'seq': seq,
        'prev': prevAuthorHash,
        'id': operationId,
        'parents': parentOperationIds,
        'op': opType,
        'payload': payloadHash,
        'ts': createdAtMs,
      }),
    ),
  );

  CloudDocumentOperation withSignature(Uint8List sig, Uint8List pubKey) =>
      CloudDocumentOperation(
        documentId: documentId,
        membershipEpoch: membershipEpoch,
        author: author,
        seq: seq,
        prevAuthorHash: prevAuthorHash,
        operationId: operationId,
        parentOperationIds: parentOperationIds,
        opType: opType,
        payloadHash: payloadHash,
        createdAtMs: createdAtMs,
        authorPubKey: pubKey,
        signature: sig,
      );

  /// Used before signing: payload encryption produces the hash that the final
  /// immutable operation must bind.
  CloudDocumentOperation withPayloadHash(String value) =>
      CloudDocumentOperation(
        documentId: documentId,
        membershipEpoch: membershipEpoch,
        author: author,
        seq: seq,
        prevAuthorHash: prevAuthorHash,
        operationId: operationId,
        parentOperationIds: parentOperationIds,
        opType: opType,
        payloadHash: value,
        createdAtMs: createdAtMs,
        authorPubKey: authorPubKey,
        signature: signature,
      );

  String get recordHash => cloudDocumentRecordHash(
    domain: 'operation',
    canonicalBytes: canonicalBytes(),
    authorPubKey: authorPubKey,
    signature: signature,
  );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'did': documentId.hex,
    'epoch': membershipEpoch,
    'author': author.hex,
    'seq': seq,
    'prev': prevAuthorHash,
    'id': operationId,
    'parents': parentOperationIds,
    'op': opType,
    'payload': payloadHash,
    'ts': createdAtMs,
    'apk': base64Encode(authorPubKey),
    'sig': base64Encode(signature),
  };

  static CloudDocumentOperation? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final did = value['did'];
    final epoch = value['epoch'];
    final author = value['author'];
    final seq = value['seq'];
    final prev = value['prev'];
    final id = value['id'];
    final rawParents = value['parents'];
    final op = value['op'];
    final payload = value['payload'];
    final timestamp = value['ts'];
    final publicKey = value['apk'];
    final signature = value['sig'];
    if (did is! String ||
        epoch is! int ||
        epoch < 0 ||
        author is! String ||
        seq is! int ||
        seq < 0 ||
        prev is! String ||
        (prev.isNotEmpty && !_isHex32(prev)) ||
        id is! String ||
        !_isHex32(id) ||
        rawParents is! List ||
        rawParents.length > 32 ||
        op is! String ||
        !_wireName.hasMatch(op) ||
        payload is! String ||
        !_isHex32(payload) ||
        timestamp is! int ||
        timestamp < 0 ||
        publicKey is! String ||
        signature is! String) {
      return null;
    }
    final parents = rawParents.whereType<String>().toList();
    if (parents.length != rawParents.length ||
        parents.any((parent) => !_isHex32(parent) || parent == id) ||
        parents.toSet().length != parents.length) {
      return null;
    }
    final sortedParents = [...parents]..sort();
    for (var index = 0; index < parents.length; index++) {
      if (parents[index] != sortedParents[index]) return null;
    }
    try {
      final pk = Uint8List.fromList(base64Decode(publicKey));
      final sig = Uint8List.fromList(base64Decode(signature));
      if (pk.length != 32 || sig.length != 64) return null;
      return CloudDocumentOperation(
        documentId: NodeId.fromHex(did),
        membershipEpoch: epoch,
        author: NodeId.fromHex(author),
        seq: seq,
        prevAuthorHash: prev,
        operationId: id,
        parentOperationIds: parents,
        opType: op,
        payloadHash: payload,
        createdAtMs: timestamp,
        authorPubKey: pk,
        signature: sig,
      );
    } catch (_) {
      return null;
    }
  }
}

class CloudDocumentEpochState {
  CloudDocumentEpochState({
    required this.epoch,
    required Map<String, CloudDocumentRole> members,
    required this.epochKeyCommitment,
    required this.epochEnvelopeHash,
  }) : members = Map.unmodifiable(members);

  final int epoch;
  final Map<String, CloudDocumentRole> members;
  final String epochKeyCommitment;
  final String epochEnvelopeHash;

  CloudDocumentRole? roleOf(NodeId nodeId) => members[nodeId.hex];
}

class CloudDocumentFoldResult {
  const CloudDocumentFoldResult({
    required this.rootValid,
    required this.epochs,
    required this.acceptedControls,
    required this.rejectedControls,
    required this.acceptedOperations,
    required this.rejectedOperations,
    required this.withheldOperations,
    required this.incompleteEpochs,
  });

  final bool rootValid;
  final Map<int, CloudDocumentEpochState> epochs;
  final List<CloudDocumentControlEntry> acceptedControls;
  final List<CloudDocumentControlEntry> rejectedControls;
  final List<CloudDocumentOperation> acceptedOperations;
  final List<CloudDocumentOperation> rejectedOperations;
  final List<CloudDocumentOperation> withheldOperations;
  final Set<int> incompleteEpochs;
}

bool _sameFrontier(
  Map<String, CloudDocumentAuthorHead> left,
  Map<String, CloudDocumentAuthorHead> right,
) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

bool _validControlShape(CloudDocumentControlEntry entry) {
  if (entry.seq < 0 ||
      entry.membershipEpoch < 0 ||
      entry.createdAtMs < 0 ||
      entry.authorPubKey.length != 32 ||
      entry.signature.length != 64 ||
      entry.nextEpoch != entry.membershipEpoch + 1 ||
      !_isHex32(entry.epochKeyCommitment) ||
      !_isHex32(entry.epochEnvelopeHash) ||
      !_isHex32(entry.controlId) ||
      (entry.prevControlHash.isNotEmpty && !_isHex32(entry.prevControlHash)) ||
      entry.closedEpochFrontier.length > 256 ||
      entry.closedEpochFrontier.entries.any(
        (value) =>
            !_isHex32(value.key) ||
            value.value.seq < 0 ||
            !_isHex32(value.value.hash),
      )) {
    return false;
  }
  switch (entry.op) {
    case CloudDocumentControlOp.grant:
      return entry.target != null &&
          (entry.role == CloudDocumentRole.editor ||
              entry.role == CloudDocumentRole.viewer);
    case CloudDocumentControlOp.setRole:
      return entry.target != null &&
          (entry.role == CloudDocumentRole.editor ||
              entry.role == CloudDocumentRole.viewer);
    case CloudDocumentControlOp.revoke:
      return entry.target != null && entry.role == null;
    case CloudDocumentControlOp.rotateEpoch:
      return entry.target == null && entry.role == null;
  }
}

bool _validRootShape(CloudDocumentRoot root) =>
    (root.version == 1 || root.version == 2) &&
    root.ownerPubKey.length == 32 &&
    root.signature.length == 64 &&
    root.createdAtMs >= 0 &&
    _wireName.hasMatch(root.codec) &&
    _isHex32(root.epochKeyCommitment) &&
    _isHex32(root.epochEnvelopeHash) &&
    _isHex32(root.controlLogRoot) &&
    root.baseEpoch >= 0 &&
    root.baseMembers.isNotEmpty &&
    root.baseMembers.length <= 256 &&
    root.baseMembers[root.owner.hex] == CloudDocumentRole.owner &&
    root.baseMembers.entries.every(
      (entry) =>
          _isHex32(entry.key) &&
          (entry.key == root.owner.hex ||
              entry.value != CloudDocumentRole.owner),
    ) &&
    root.baseAuthorFrontier.length <= 256 &&
    root.baseAuthorFrontier.entries.every(
      (entry) =>
          _isHex32(entry.key) &&
          entry.value.seq >= 0 &&
          _isHex32(entry.value.hash),
    ) &&
    root.baseControlSeq >= -1 &&
    _isHex32(root.baseControlHash) &&
    (root.version == 1
        ? root.generation == 0 &&
              root.predecessorRootHash.isEmpty &&
              root.baseEpoch == 0 &&
              root.baseMembers.length == 1 &&
              root.baseAuthorFrontier.isEmpty &&
              root.baseControlSeq == -1 &&
              root.baseControlHash == root.controlLogRoot
        : root.generation > 0 && _isHex32(root.predecessorRootHash));

/// A compacted root is accepted only as the immediate, owner-signed successor
/// of the locally trusted root. Immutable document identity fields cannot be
/// rewritten during compaction.
bool isDirectCloudDocumentRootTransition(
  CloudDocumentRoot current,
  CloudDocumentRoot next,
) =>
    _validRootShape(current) &&
    _validRootShape(next) &&
    next.version == 2 &&
    next.generation == current.generation + 1 &&
    next.predecessorRootHash == current.recordHash &&
    next.documentId == current.documentId &&
    next.owner == current.owner &&
    _bytesEqual(next.ownerPubKey, current.ownerPubKey) &&
    next.kind == current.kind &&
    next.codec == current.codec &&
    next.controlLogRoot == current.controlLogRoot &&
    next.createdAtMs == current.createdAtMs;

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

bool _validOperationShape(CloudDocumentOperation operation) {
  if (operation.membershipEpoch < 0 ||
      operation.seq < 0 ||
      operation.createdAtMs < 0 ||
      operation.authorPubKey.length != 32 ||
      operation.signature.length != 64 ||
      !_isHex32(operation.operationId) ||
      !_isHex32(operation.payloadHash) ||
      !_wireName.hasMatch(operation.opType) ||
      (operation.prevAuthorHash.isNotEmpty &&
          !_isHex32(operation.prevAuthorHash)) ||
      operation.parentOperationIds.length > 32 ||
      operation.parentOperationIds.toSet().length !=
          operation.parentOperationIds.length ||
      operation.parentOperationIds.any(
        (parent) => !_isHex32(parent) || parent == operation.operationId,
      )) {
    return false;
  }
  final sorted = [...operation.parentOperationIds]..sort();
  for (var index = 0; index < sorted.length; index++) {
    if (sorted[index] != operation.parentOperationIds[index]) return false;
  }
  return true;
}

/// Deterministically validates the immutable root, owner-only epoch control
/// chain and author-chained operations. Every membership/role mutation closes
/// the old epoch with an owner-signed operation frontier. Consequently a
/// removed editor cannot manufacture a newly seen, backdated old-epoch edit:
/// closed history is exposed only when its exact signed frontier is present.
CloudDocumentFoldResult foldCloudDocumentLog({
  required CloudDocumentRoot root,
  required Iterable<CloudDocumentControlEntry> controls,
  required Iterable<CloudDocumentOperation> operations,
  required bool Function(CloudDocumentRoot root) verifyRoot,
  required bool Function(CloudDocumentControlEntry entry) verifyControl,
  required bool Function(CloudDocumentOperation operation) verifyOperation,
}) {
  final allControls = controls.toList();
  final allOperations = operations.toList();
  if (!_validRootShape(root) || !verifyRoot(root)) {
    return CloudDocumentFoldResult(
      rootValid: false,
      epochs: const {},
      acceptedControls: const [],
      rejectedControls: allControls,
      acceptedOperations: const [],
      rejectedOperations: allOperations,
      withheldOperations: const [],
      incompleteEpochs: const {},
    );
  }

  final epochs = <int, CloudDocumentEpochState>{
    root.baseEpoch: CloudDocumentEpochState(
      epoch: root.baseEpoch,
      members: root.baseMembers,
      epochKeyCommitment: root.epochKeyCommitment,
      epochEnvelopeHash: root.epochEnvelopeHash,
    ),
  };
  final closures = <int, Map<String, CloudDocumentAuthorHead>>{};
  final acceptedControls = <CloudDocumentControlEntry>[];
  final rejectedControls = <CloudDocumentControlEntry>[];
  var currentEpoch = root.baseEpoch;
  var expectedSeq = root.baseControlSeq + 1;
  var expectedPrev = root.baseControlHash;
  final eligibleControls = <CloudDocumentControlEntry>[];
  for (final entry in allControls) {
    if (entry.documentId == root.documentId &&
        entry.author == root.owner &&
        _validControlShape(entry) &&
        verifyControl(entry)) {
      eligibleControls.add(entry);
    } else {
      rejectedControls.add(entry);
    }
  }
  final controlSeqCounts = <int, int>{};
  final controlIdCounts = <String, int>{};
  for (final entry in eligibleControls) {
    controlSeqCounts.update(entry.seq, (count) => count + 1, ifAbsent: () => 1);
    controlIdCounts.update(
      entry.controlId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }
  final orderedControls = [...eligibleControls]
    ..sort((left, right) {
      final bySeq = left.seq.compareTo(right.seq);
      if (bySeq != 0) return bySeq;
      return left.controlId.compareTo(right.controlId);
    });
  for (final entry in orderedControls) {
    if (controlSeqCounts[entry.seq] != 1 ||
        controlIdCounts[entry.controlId] != 1) {
      rejectedControls.add(entry);
      continue;
    }
    final state = epochs[currentEpoch]!;
    final targetRole = entry.target == null
        ? null
        : state.members[entry.target!.hex];
    final validTarget = switch (entry.op) {
      CloudDocumentControlOp.grant => targetRole == null,
      CloudDocumentControlOp.setRole =>
        targetRole != null && targetRole != CloudDocumentRole.owner,
      CloudDocumentControlOp.revoke =>
        targetRole != null && targetRole != CloudDocumentRole.owner,
      CloudDocumentControlOp.rotateEpoch => true,
    };
    final valid =
        entry.seq == expectedSeq &&
        entry.prevControlHash == expectedPrev &&
        entry.membershipEpoch == currentEpoch &&
        entry.nextEpoch == currentEpoch + 1 &&
        validTarget;
    if (!valid) {
      rejectedControls.add(entry);
      continue;
    }

    final nextMembers = Map<String, CloudDocumentRole>.from(state.members);
    switch (entry.op) {
      case CloudDocumentControlOp.grant:
      case CloudDocumentControlOp.setRole:
        nextMembers[entry.target!.hex] = entry.role!;
      case CloudDocumentControlOp.revoke:
        nextMembers.remove(entry.target!.hex);
      case CloudDocumentControlOp.rotateEpoch:
        break;
    }
    closures[currentEpoch] = Map.unmodifiable(entry.closedEpochFrontier);
    currentEpoch = entry.nextEpoch;
    epochs[currentEpoch] = CloudDocumentEpochState(
      epoch: currentEpoch,
      members: nextMembers,
      epochKeyCommitment: entry.epochKeyCommitment,
      epochEnvelopeHash: entry.epochEnvelopeHash,
    );
    acceptedControls.add(entry);
    expectedSeq++;
    expectedPrev = entry.recordHash;
  }

  final rejectedOperations = <CloudDocumentOperation>[];
  final candidates = <CloudDocumentOperation>[];
  final byAuthor = <String, List<CloudDocumentOperation>>{};
  for (final operation in allOperations) {
    final state = epochs[operation.membershipEpoch];
    final role = state?.roleOf(operation.author);
    if (operation.documentId == root.documentId &&
        (role == CloudDocumentRole.owner || role == CloudDocumentRole.editor) &&
        _validOperationShape(operation) &&
        verifyOperation(operation)) {
      byAuthor.putIfAbsent(operation.author.hex, () => []).add(operation);
    } else {
      rejectedOperations.add(operation);
    }
  }
  for (final authorEntries in byAuthor.values) {
    authorEntries.sort((left, right) {
      final bySeq = left.seq.compareTo(right.seq);
      if (bySeq != 0) return bySeq;
      return left.operationId.compareTo(right.operationId);
    });
    final duplicateSeqs = <int>{};
    for (var index = 1; index < authorEntries.length; index++) {
      if (authorEntries[index - 1].seq == authorEntries[index].seq) {
        duplicateSeqs.add(authorEntries[index].seq);
      }
    }
    final baseHead = root.baseAuthorFrontier[authorEntries.first.author.hex];
    var expectedOperationSeq = (baseHead?.seq ?? -1) + 1;
    var expectedAuthorHash = baseHead?.hash ?? '';
    var lastEpoch = root.baseEpoch;
    for (final operation in authorEntries) {
      final valid =
          !duplicateSeqs.contains(operation.seq) &&
          operation.seq == expectedOperationSeq &&
          operation.prevAuthorHash == expectedAuthorHash &&
          operation.membershipEpoch >= lastEpoch;
      if (!valid) {
        rejectedOperations.add(operation);
        continue;
      }
      candidates.add(operation);
      expectedOperationSeq++;
      expectedAuthorHash = operation.recordHash;
      lastEpoch = operation.membershipEpoch;
    }
  }

  final operationIdCounts = <String, int>{};
  for (final operation in candidates) {
    operationIdCounts.update(
      operation.operationId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }
  final duplicateIdFromSeq = <String, int>{};
  for (final operation in candidates) {
    if (operationIdCounts[operation.operationId] == 1) continue;
    final previous = duplicateIdFromSeq[operation.author.hex];
    if (previous == null || operation.seq < previous) {
      duplicateIdFromSeq[operation.author.hex] = operation.seq;
    }
  }
  final uniqueCandidates = <CloudDocumentOperation>[];
  for (final operation in candidates) {
    final taintedAt = duplicateIdFromSeq[operation.author.hex];
    if (operationIdCounts[operation.operationId] == 1 &&
        (taintedAt == null || operation.seq < taintedAt)) {
      uniqueCandidates.add(operation);
    } else {
      rejectedOperations.add(operation);
    }
  }

  // Parent links are the causal clock used by every document CRDT. Two
  // authenticated editors can pre-coordinate operation ids, so signature and
  // parent-existence checks alone do not prove that this graph is acyclic.
  // Reject the cycle and every operation causally dependent on it: Kahn's
  // remainder is exactly the subgraph that can never be topologically emitted.
  final cyclicOrDependentIds = _cyclicOrDependentOperationIds(uniqueCandidates);
  if (cyclicOrDependentIds.isNotEmpty) {
    for (final operation in [...uniqueCandidates]) {
      if (!cyclicOrDependentIds.contains(operation.operationId)) continue;
      uniqueCandidates.remove(operation);
      rejectedOperations.add(operation);
    }
  }

  final incompleteEpochs = <int>{};
  final taintedFromSeq = <String, int>{};
  for (final closure in closures.entries) {
    final actual = <String, CloudDocumentAuthorHead>{
      ...root.baseAuthorFrontier,
    };
    final recordsAtSeq = <(String, int), CloudDocumentOperation>{};
    for (final operation in uniqueCandidates) {
      if (operation.membershipEpoch > closure.key) continue;
      actual[operation.author.hex] = CloudDocumentAuthorHead(
        seq: operation.seq,
        hash: operation.recordHash,
      );
      recordsAtSeq[(operation.author.hex, operation.seq)] = operation;
    }
    if (_sameFrontier(actual, closure.value)) continue;
    incompleteEpochs.add(closure.key);
    final authors = {...actual.keys, ...closure.value.keys};
    for (final author in authors) {
      if (actual[author] == closure.value[author]) continue;
      final expected = closure.value[author];
      var firstUntrustedSeq = 0;
      if (expected != null) {
        final signedHead = recordsAtSeq[(author, expected.seq)];
        final baseHead = root.baseAuthorFrontier[author];
        if ((signedHead != null && signedHead.recordHash == expected.hash) ||
            baseHead == expected) {
          // Preserve the exact history the owner signed into the closure;
          // only a newly supplied suffix is backdated/untrusted.
          firstUntrustedSeq = expected.seq + 1;
        }
      }
      final previous = taintedFromSeq[author];
      if (previous == null || firstUntrustedSeq < previous) {
        taintedFromSeq[author] = firstUntrustedSeq;
      }
    }
  }

  final withheld = <CloudDocumentOperation>[];
  final accepted = <CloudDocumentOperation>[];
  final candidateIds = uniqueCandidates
      .map((entry) => entry.operationId)
      .toSet();
  for (final operation in uniqueCandidates) {
    final firstUntrustedSeq = taintedFromSeq[operation.author.hex];
    final hasUnknownParent = operation.parentOperationIds.any(
      (parent) => !candidateIds.contains(parent),
    );
    if ((firstUntrustedSeq != null && operation.seq >= firstUntrustedSeq) ||
        hasUnknownParent) {
      withheld.add(operation);
    } else {
      accepted.add(operation);
    }
  }
  // A child of a withheld parent is withheld too, regardless of author.
  var changed = true;
  while (changed) {
    changed = false;
    final withheldIds = withheld.map((entry) => entry.operationId).toSet();
    for (final operation in [...accepted]) {
      if (operation.parentOperationIds.any(withheldIds.contains)) {
        accepted.remove(operation);
        withheld.add(operation);
        changed = true;
      }
    }
  }
  accepted.sort((left, right) => left.operationId.compareTo(right.operationId));
  withheld.sort((left, right) => left.operationId.compareTo(right.operationId));

  return CloudDocumentFoldResult(
    rootValid: true,
    epochs: Map.unmodifiable(epochs),
    acceptedControls: List.unmodifiable(acceptedControls),
    rejectedControls: List.unmodifiable(rejectedControls),
    acceptedOperations: List.unmodifiable(accepted),
    rejectedOperations: List.unmodifiable(rejectedOperations),
    withheldOperations: List.unmodifiable(withheld),
    incompleteEpochs: Set.unmodifiable(incompleteEpochs),
  );
}

Set<String> _cyclicOrDependentOperationIds(
  List<CloudDocumentOperation> operations,
) {
  final byId = {
    for (final operation in operations) operation.operationId: operation,
  };
  final indegree = <String, int>{};
  final children = <String, List<String>>{};
  for (final operation in operations) {
    var count = 0;
    for (final parent in operation.parentOperationIds) {
      if (!byId.containsKey(parent)) continue;
      count++;
      children.putIfAbsent(parent, () => []).add(operation.operationId);
    }
    indegree[operation.operationId] = count;
  }
  final ready = indegree.entries
      .where((entry) => entry.value == 0)
      .map((entry) => entry.key)
      .toList();
  var cursor = 0;
  while (cursor < ready.length) {
    final id = ready[cursor++];
    for (final child in children[id] ?? const []) {
      final next = indegree[child]! - 1;
      indegree[child] = next;
      if (next == 0) ready.add(child);
    }
  }
  return {
    for (final entry in indegree.entries)
      if (entry.value > 0) entry.key,
  };
}
