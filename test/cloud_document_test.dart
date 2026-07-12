import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/cloud_document.dart';

String _hash(int byte) => List.filled(
  32,
  byte,
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

NodeId _id(int byte) => NodeId.fromHex(_hash(byte));
Uint8List _pk(int byte) => Uint8List.fromList(List.filled(32, byte));
Uint8List _sig(int byte) => Uint8List.fromList(List.filled(64, byte));

CloudDocumentRoot _root() => CloudDocumentRoot(
  documentId: _id(10),
  owner: _id(1),
  ownerPubKey: _pk(1),
  kind: CloudDocumentKind.note,
  codec: 'xveil.note.rga.v1',
  epochKeyCommitment: _hash(40),
  epochEnvelopeHash: _hash(41),
  controlLogRoot: _hash(42),
  createdAtMs: 1000,
  signature: _sig(1),
);

CloudDocumentControlEntry _control({
  required int seq,
  required String prev,
  required int epoch,
  required CloudDocumentControlOp op,
  NodeId? target,
  CloudDocumentRole? role,
  Map<String, CloudDocumentAuthorHead> frontier = const {},
  NodeId? author,
}) => CloudDocumentControlEntry(
  documentId: _id(10),
  author: author ?? _id(1),
  seq: seq,
  prevControlHash: prev,
  controlId: _hash(50 + seq),
  membershipEpoch: epoch,
  nextEpoch: epoch + 1,
  op: op,
  target: target,
  role: role,
  epochKeyCommitment: _hash(60 + epoch),
  epochEnvelopeHash: _hash(70 + epoch),
  closedEpochFrontier: frontier,
  createdAtMs: 2000 + seq,
  authorPubKey: _pk(1),
  signature: _sig(1),
);

CloudDocumentOperation _operation({
  required NodeId author,
  required int seq,
  required int epoch,
  required String id,
  String prev = '',
  List<String> parents = const [],
  int payloadByte = 90,
}) => CloudDocumentOperation(
  documentId: _id(10),
  membershipEpoch: epoch,
  author: author,
  seq: seq,
  prevAuthorHash: prev,
  operationId: id,
  parentOperationIds: parents,
  opType: 'insert',
  payloadHash: _hash(payloadByte),
  createdAtMs: 3000 + seq,
  authorPubKey: _pk(author.bytes.first),
  signature: _sig(author.bytes.first),
);

CloudDocumentFoldResult _fold({
  List<CloudDocumentControlEntry> controls = const [],
  List<CloudDocumentOperation> operations = const [],
  bool rootValid = true,
  bool Function(CloudDocumentControlEntry)? verifyControl,
  bool Function(CloudDocumentOperation)? verifyOperation,
}) => foldCloudDocumentLog(
  root: _root(),
  controls: controls,
  operations: operations,
  verifyRoot: (_) => rootValid,
  verifyControl: verifyControl ?? (_) => true,
  verifyOperation: verifyOperation ?? (_) => true,
);

void main() {
  test(
    'root/control/operation canonical bytes survive strict JSON roundtrip',
    () {
      final root = _root();
      final parsedRoot = CloudDocumentRoot.fromJson(root.toJson());
      expect(parsedRoot, isNotNull);
      expect(parsedRoot!.canonicalBytes(), root.canonicalBytes());

      final control = _control(
        seq: 0,
        prev: root.controlLogRoot,
        epoch: 0,
        op: CloudDocumentControlOp.grant,
        target: _id(2),
        role: CloudDocumentRole.editor,
      );
      final parsedControl = CloudDocumentControlEntry.fromJson(
        control.toJson(),
      );
      expect(parsedControl, isNotNull);
      expect(parsedControl!.canonicalBytes(), control.canonicalBytes());
      expect(parsedControl.recordHash, control.recordHash);

      final operation = _operation(
        author: _id(2),
        seq: 0,
        epoch: 1,
        id: _hash(80),
      );
      final parsedOperation = CloudDocumentOperation.fromJson(
        operation.toJson(),
      );
      expect(parsedOperation, isNotNull);
      expect(parsedOperation!.canonicalBytes(), operation.canonicalBytes());
      expect(parsedOperation.recordHash, operation.recordHash);
    },
  );

  test('operation parser rejects noncanonical parents and self-parenting', () {
    final operation = _operation(
      author: _id(2),
      seq: 0,
      epoch: 1,
      id: _hash(80),
      parents: [_hash(81), _hash(82)],
    );
    final reversed = Map<String, dynamic>.from(operation.toJson())
      ..['parents'] = [_hash(82), _hash(81)];
    expect(CloudDocumentOperation.fromJson(reversed), isNull);
    final self = Map<String, dynamic>.from(operation.toJson())
      ..['parents'] = [_hash(80)];
    expect(CloudDocumentOperation.fromJson(self), isNull);
  });

  test('strict parsers return null rather than throw on wrong wire types', () {
    final badRoot = Map<String, dynamic>.from(_root().toJson())..['kind'] = 7;
    expect(() => CloudDocumentRoot.fromJson(badRoot), returnsNormally);
    expect(CloudDocumentRoot.fromJson(badRoot), isNull);

    final control = _control(
      seq: 0,
      prev: _root().controlLogRoot,
      epoch: 0,
      op: CloudDocumentControlOp.rotateEpoch,
    );
    final badControl = Map<String, dynamic>.from(control.toJson())
      ..['op'] = const [];
    expect(
      () => CloudDocumentControlEntry.fromJson(badControl),
      returnsNormally,
    );
    expect(CloudDocumentControlEntry.fromJson(badControl), isNull);
  });

  test('invalid root fails closed before controls or operations', () {
    final operation = _operation(
      author: _id(1),
      seq: 0,
      epoch: 0,
      id: _hash(80),
    );
    final result = _fold(operations: [operation], rootValid: false);
    expect(result.rootValid, isFalse);
    expect(result.epochs, isEmpty);
    expect(result.acceptedOperations, isEmpty);
    expect(result.rejectedOperations, [operation]);
  });

  test('owner grant creates a new epoch and editor may author operations', () {
    final grant = _control(
      seq: 0,
      prev: _root().controlLogRoot,
      epoch: 0,
      op: CloudDocumentControlOp.grant,
      target: _id(2),
      role: CloudDocumentRole.editor,
    );
    final edit = _operation(author: _id(2), seq: 0, epoch: 1, id: _hash(80));
    final result = _fold(controls: [grant], operations: [edit]);
    expect(result.acceptedControls, [grant]);
    expect(result.epochs[0]!.roleOf(_id(2)), isNull);
    expect(result.epochs[1]!.roleOf(_id(2)), CloudDocumentRole.editor);
    expect(result.acceptedOperations, [edit]);
  });

  test('viewer cannot mutate and non-owner cannot change ACL', () {
    final grantViewer = _control(
      seq: 0,
      prev: _root().controlLogRoot,
      epoch: 0,
      op: CloudDocumentControlOp.grant,
      target: _id(3),
      role: CloudDocumentRole.viewer,
    );
    final viewerEdit = _operation(
      author: _id(3),
      seq: 0,
      epoch: 1,
      id: _hash(80),
    );
    final forgedGrant = _control(
      seq: 1,
      prev: grantViewer.recordHash,
      epoch: 1,
      op: CloudDocumentControlOp.grant,
      target: _id(4),
      role: CloudDocumentRole.editor,
      author: _id(3),
    );
    final result = _fold(
      controls: [grantViewer, forgedGrant],
      operations: [viewerEdit],
    );
    expect(result.rejectedControls, contains(forgedGrant));
    expect(result.rejectedOperations, contains(viewerEdit));
    expect(result.epochs.containsKey(2), isFalse);
  });

  test('revoke keeps signed history but withholds a backdated suffix', () {
    final grant = _control(
      seq: 0,
      prev: _root().controlLogRoot,
      epoch: 0,
      op: CloudDocumentControlOp.grant,
      target: _id(2),
      role: CloudDocumentRole.editor,
    );
    final acceptedEdit = _operation(
      author: _id(2),
      seq: 0,
      epoch: 1,
      id: _hash(80),
    );
    final revoke = _control(
      seq: 1,
      prev: grant.recordHash,
      epoch: 1,
      op: CloudDocumentControlOp.revoke,
      target: _id(2),
      frontier: {
        _id(2).hex: CloudDocumentAuthorHead(
          seq: 0,
          hash: acceptedEdit.recordHash,
        ),
      },
    );
    final lateBackdated = _operation(
      author: _id(2),
      seq: 1,
      epoch: 1,
      prev: acceptedEdit.recordHash,
      id: _hash(81),
      parents: [_hash(80)],
    );
    final result = _fold(
      controls: [grant, revoke],
      operations: [acceptedEdit, lateBackdated],
    );
    expect(result.epochs[2]!.roleOf(_id(2)), isNull);
    expect(result.acceptedOperations, contains(acceptedEdit));
    expect(result.withheldOperations, contains(lateBackdated));
    expect(result.incompleteEpochs, contains(1));
  });

  test('removed editor cannot author in the new epoch', () {
    final grant = _control(
      seq: 0,
      prev: _root().controlLogRoot,
      epoch: 0,
      op: CloudDocumentControlOp.grant,
      target: _id(2),
      role: CloudDocumentRole.editor,
    );
    final acceptedEdit = _operation(
      author: _id(2),
      seq: 0,
      epoch: 1,
      id: _hash(80),
    );
    final revoke = _control(
      seq: 1,
      prev: grant.recordHash,
      epoch: 1,
      op: CloudDocumentControlOp.revoke,
      target: _id(2),
      frontier: {
        _id(2).hex: CloudDocumentAuthorHead(
          seq: 0,
          hash: acceptedEdit.recordHash,
        ),
      },
    );
    final afterRevoke = _operation(
      author: _id(2),
      seq: 1,
      epoch: 2,
      prev: acceptedEdit.recordHash,
      id: _hash(81),
      parents: [_hash(80)],
    );
    final result = _fold(
      controls: [grant, revoke],
      operations: [acceptedEdit, afterRevoke],
    );
    expect(result.acceptedOperations, [acceptedEdit]);
    expect(result.rejectedOperations, contains(afterRevoke));
    expect(result.incompleteEpochs, isEmpty);
  });

  test('unknown parent is withheld until its immutable dependency arrives', () {
    final operation = _operation(
      author: _id(1),
      seq: 0,
      epoch: 0,
      id: _hash(80),
      parents: [_hash(99)],
    );
    final result = _fold(operations: [operation]);
    expect(result.rejectedOperations, isEmpty);
    expect(result.acceptedOperations, isEmpty);
    expect(result.withheldOperations, [operation]);
  });

  test('duplicate author sequence fails closed instead of choosing a fork', () {
    final left = _operation(
      author: _id(1),
      seq: 0,
      epoch: 0,
      id: _hash(80),
      payloadByte: 90,
    );
    final right = _operation(
      author: _id(1),
      seq: 0,
      epoch: 0,
      id: _hash(81),
      payloadByte: 91,
    );
    final result = _fold(operations: [left, right]);
    expect(result.acceptedOperations, isEmpty);
    expect(result.rejectedOperations, containsAll([left, right]));
  });

  test('invalid-signature sequence poison cannot block a valid operation', () {
    final valid = _operation(author: _id(1), seq: 0, epoch: 0, id: _hash(80));
    final poison = _operation(author: _id(1), seq: 0, epoch: 0, id: _hash(81));
    final result = _fold(
      operations: [poison, valid],
      verifyOperation: (operation) => operation.operationId != _hash(81),
    );
    expect(result.acceptedOperations, [valid]);
    expect(result.rejectedOperations, [poison]);
  });

  test('invalid-signature control poison cannot block the owner chain', () {
    final valid = _control(
      seq: 0,
      prev: _root().controlLogRoot,
      epoch: 0,
      op: CloudDocumentControlOp.grant,
      target: _id(2),
      role: CloudDocumentRole.editor,
    );
    final poison = CloudDocumentControlEntry(
      documentId: valid.documentId,
      author: valid.author,
      seq: valid.seq,
      prevControlHash: valid.prevControlHash,
      controlId: _hash(49),
      membershipEpoch: valid.membershipEpoch,
      nextEpoch: valid.nextEpoch,
      op: valid.op,
      target: valid.target,
      role: valid.role,
      epochKeyCommitment: valid.epochKeyCommitment,
      epochEnvelopeHash: valid.epochEnvelopeHash,
      closedEpochFrontier: valid.closedEpochFrontier,
      createdAtMs: valid.createdAtMs,
      authorPubKey: valid.authorPubKey,
      signature: valid.signature,
    );
    final result = _fold(
      controls: [poison, valid],
      verifyControl: (entry) => entry.controlId != _hash(49),
    );
    expect(result.acceptedControls, [valid]);
    expect(result.rejectedControls, [poison]);
  });

  test(
    'two valid owner controls at one sequence fail closed as equivocation',
    () {
      final left = _control(
        seq: 0,
        prev: _root().controlLogRoot,
        epoch: 0,
        op: CloudDocumentControlOp.grant,
        target: _id(2),
        role: CloudDocumentRole.editor,
      );
      final right = CloudDocumentControlEntry(
        documentId: left.documentId,
        author: left.author,
        seq: left.seq,
        prevControlHash: left.prevControlHash,
        controlId: _hash(49),
        membershipEpoch: left.membershipEpoch,
        nextEpoch: left.nextEpoch,
        op: left.op,
        target: _id(3),
        role: CloudDocumentRole.viewer,
        epochKeyCommitment: left.epochKeyCommitment,
        epochEnvelopeHash: left.epochEnvelopeHash,
        closedEpochFrontier: left.closedEpochFrontier,
        createdAtMs: left.createdAtMs,
        authorPubKey: left.authorPubKey,
        signature: left.signature,
      );
      final result = _fold(controls: [left, right]);
      expect(result.acceptedControls, isEmpty);
      expect(result.rejectedControls, containsAll([left, right]));
      expect(result.epochs.keys, [0]);
    },
  );

  test('fold rejects an unsorted direct-constructor parent list', () {
    final malformed = _operation(
      author: _id(1),
      seq: 0,
      epoch: 0,
      id: _hash(80),
      parents: [_hash(82), _hash(81)],
    );
    final result = _fold(operations: [malformed]);
    expect(result.acceptedOperations, isEmpty);
    expect(result.rejectedOperations, [malformed]);
  });

  test('canonical bytes bind epoch, frontier, parents and payload hash', () {
    final base = _operation(author: _id(1), seq: 0, epoch: 0, id: _hash(80));
    final changedPayload = _operation(
      author: _id(1),
      seq: 0,
      epoch: 0,
      id: _hash(80),
      payloadByte: 91,
    );
    expect(base.canonicalBytes(), isNot(changedPayload.canonicalBytes()));

    final decoded = jsonDecode(utf8.decode(base.canonicalBytes())) as Map;
    expect(decoded.keys, containsAll(['did', 'epoch', 'prev', 'parents']));
  });
}
