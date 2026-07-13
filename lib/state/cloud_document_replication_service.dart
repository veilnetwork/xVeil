import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../core/ids.dart';
import '../crypto/blake3.dart';
import '../domain/cloud_collection_crdt.dart';
import '../domain/cloud_document.dart';
import '../domain/cloud_document_envelope.dart';
import '../domain/cloud_document_replication.dart';
import '../domain/cloud_document_payload.dart';
import '../domain/cloud_rich_text_crdt.dart';
import 'cloud_document_crypto.dart';
import 'cloud_document_envelope_service.dart';
import 'cloud_document_store.dart';

typedef CloudDocumentFrameSender =
    Future<void> Function(NodeId peer, String documentId, String frameJson);
typedef CloudDocumentAcceptedContact = Future<bool> Function(NodeId peer);

class CloudDocumentView {
  const CloudDocumentView({
    required this.root,
    required this.currentEpoch,
    required this.members,
    required this.localRole,
  });

  final CloudDocumentRoot root;
  final int currentEpoch;
  final Map<String, CloudDocumentRole> members;
  final CloudDocumentRole? localRole;
}

class CloudDocumentMutationResult {
  const CloudDocumentMutationResult({
    required this.documentId,
    this.failedRecipients = const [],
  });

  final String documentId;
  final List<NodeId> failedRecipients;
  bool get fullyQueued => failedRecipients.isEmpty;
}

class CloudRichTextDocumentState {
  const CloudRichTextDocumentState({
    required this.snapshot,
    required this.currentEpoch,
    required this.localRole,
  });

  final CloudRichTextSnapshot snapshot;
  final int currentEpoch;
  final CloudDocumentRole? localRole;

  bool get canEdit =>
      localRole == CloudDocumentRole.owner ||
      localRole == CloudDocumentRole.editor;
}

class CloudCollectionDocumentState {
  const CloudCollectionDocumentState({
    required this.kind,
    required this.snapshot,
    required this.currentEpoch,
    required this.localRole,
  });

  final CloudDocumentKind kind;
  final CloudCollectionSnapshot snapshot;
  final int currentEpoch;
  final CloudDocumentRole? localRole;

  bool get canEdit =>
      localRole == CloudDocumentRole.owner ||
      localRole == CloudDocumentRole.editor;

  List<CloudTask> get tasks {
    if (kind != CloudDocumentKind.taskList) return const [];
    return snapshot.rows.map(CloudTask.fromRow).nonNulls.toList();
  }

  List<CloudCalendarEvent> get events {
    if (kind != CloudDocumentKind.calendar) return const [];
    return snapshot.rows.map(CloudCalendarEvent.fromRow).nonNulls.toList();
  }
}

/// Replicates signed document logs without borrowing group authorization.
/// Transport admission is accepted-contact-only; this layer independently
/// checks document signatures, membership epochs and recipient envelopes.
class CloudDocumentReplicationService {
  factory CloudDocumentReplicationService({
    required NodeId localNodeId,
    required int ourCertVersion,
    required CloudDocumentStore store,
    required CloudDocumentEnvelopeService envelopes,
    required CloudDocumentFrameSender sendFrame,
    CloudDocumentSigner? signer,
    CloudDocumentAcceptedContact? acceptedContact,
    bool Function(CloudDocumentRoot root)? verifyRoot,
    bool Function(CloudDocumentControlEntry entry)? verifyControl,
    bool Function(CloudDocumentOperation operation)? verifyOperation,
    DateTime Function()? now,
    Random? random,
  }) => CloudDocumentReplicationService._(
    localNodeId: localNodeId,
    ourCertVersion: ourCertVersion,
    store: store,
    envelopes: envelopes,
    sendFrame: sendFrame,
    signer: signer,
    acceptedContact: acceptedContact ?? (_) async => true,
    verifyRoot: verifyRoot ?? verifyCloudDocumentRoot,
    verifyControl: verifyControl ?? verifyCloudDocumentControl,
    verifyOperation: verifyOperation ?? verifyCloudDocumentOperation,
    now: now ?? DateTime.now,
    random: random ?? Random.secure(),
  );

  CloudDocumentReplicationService._({
    required this.localNodeId,
    required this.ourCertVersion,
    required this._store,
    required this._envelopes,
    required this._sendFrame,
    required this._signer,
    required this._acceptedContact,
    required this._verifyRoot,
    required this._verifyControl,
    required this._verifyOperation,
    required this._now,
    required this._random,
  });

  final NodeId localNodeId;
  final int ourCertVersion;
  final CloudDocumentStore _store;
  final CloudDocumentEnvelopeService _envelopes;
  final CloudDocumentFrameSender _sendFrame;
  final CloudDocumentSigner? _signer;
  final CloudDocumentAcceptedContact _acceptedContact;
  final bool Function(CloudDocumentRoot root) _verifyRoot;
  final bool Function(CloudDocumentControlEntry entry) _verifyControl;
  final bool Function(CloudDocumentOperation operation) _verifyOperation;
  final DateTime Function() _now;
  final Random _random;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Future<void> _writeTail = Future.value();

  Stream<void> get changes => _changes.stream;

  bool get canMutate => _signer?.selfId == localNodeId;

  /// Opaque row id generated by the same cryptographically secure source as
  /// signed document operation ids. It carries no document or author data.
  String newCollectionEntityId() => _randomHex32();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _writeTail.then((_) => action());
    _writeTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> close() async {
    // Riverpod/widget listeners can still be paused while their container is
    // being torn down. No producer runs after provider disposal, so initiate
    // completion without waiting for those listeners to cancel.
    unawaited(_changes.close());
  }

  CloudDocumentFoldResult _fold(CloudDocumentFrame frame) =>
      foldCloudDocumentLog(
        root: frame.root,
        controls: frame.controls,
        operations: frame.operations,
        verifyRoot: _verifyRoot,
        verifyControl: _verifyControl,
        verifyOperation: _verifyOperation,
      );

  bool _completeAndValid(
    CloudDocumentFrame frame,
    CloudDocumentFoldResult fold,
  ) {
    if (!fold.rootValid ||
        fold.rejectedControls.isNotEmpty ||
        fold.rejectedOperations.isNotEmpty ||
        fold.withheldOperations.isNotEmpty ||
        fold.incompleteEpochs.isNotEmpty) {
      return false;
    }
    final payloads = <String, CloudDocumentEncryptedPayload>{};
    for (final payload in frame.payloads) {
      if (payloads.containsKey(payload.operationId)) return false;
      payloads[payload.operationId] = payload;
    }
    if (payloads.length != fold.acceptedOperations.length) return false;
    for (final operation in fold.acceptedOperations) {
      final payload = payloads[operation.operationId];
      if (payload == null ||
          payload.documentId != operation.documentId ||
          payload.membershipEpoch != operation.membershipEpoch ||
          payload.payloadHash != operation.payloadHash) {
        return false;
      }
    }
    final byEpoch = <int, String>{};
    for (final envelope in frame.envelopes) {
      if (byEpoch.putIfAbsent(envelope.epoch, () => envelope.bundleHash) !=
          envelope.bundleHash) {
        return false;
      }
      final epoch = fold.epochs[envelope.epoch];
      if (epoch == null ||
          epoch.epochKeyCommitment != envelope.keyCommitment ||
          epoch.epochEnvelopeHash != envelope.bundleHash) {
        return false;
      }
    }
    final current = fold.epochs.keys.reduce((a, b) => a > b ? a : b);
    CloudDocumentEpochEnvelopeBundle? currentEnvelope;
    for (final envelope in frame.envelopes) {
      if (envelope.epoch == current) currentEnvelope = envelope;
    }
    return currentEnvelope != null;
  }

  Future<List<CloudDocumentView>> listDocuments() async {
    final result = <CloudDocumentView>[];
    for (final id in await _store.listDocumentIds()) {
      final stored = await _store.load(id);
      if (stored == null) continue;
      try {
        final frame = _frameFromStored(CloudDocumentFrameKind.snapshot, stored);
        final fold = _fold(frame);
        if (!_completeAndValid(frame, fold)) continue;
        final epoch = fold.epochs.keys.reduce((a, b) => a > b ? a : b);
        final members = fold.epochs[epoch]!.members;
        result.add(
          CloudDocumentView(
            root: stored.root,
            currentEpoch: epoch,
            members: Map.unmodifiable(members),
            localRole: members[localNodeId.hex],
          ),
        );
      } finally {
        stored.wipeLocalEpochKeys();
      }
    }
    result.sort((left, right) {
      final byTime = right.root.createdAtMs.compareTo(left.root.createdAtMs);
      return byTime != 0
          ? byTime
          : left.root.documentId.hex.compareTo(right.root.documentId.hex);
    });
    return result;
  }

  Future<CloudRichTextDocumentState?> loadRichText(String documentId) async {
    final stored = await _store.load(documentId);
    if (stored == null ||
        stored.root.kind != CloudDocumentKind.note ||
        stored.root.codec != cloudRichTextCodecV1) {
      stored?.wipeLocalEpochKeys();
      return null;
    }
    try {
      final frame = _frameFromStored(CloudDocumentFrameKind.snapshot, stored);
      final fold = _fold(frame);
      if (!_completeAndValid(frame, fold)) return null;
      final snapshot = await _materializeRichText(stored, fold);
      if (snapshot == null) return null;
      final epoch = fold.epochs.keys.reduce((a, b) => a > b ? a : b);
      return CloudRichTextDocumentState(
        snapshot: snapshot,
        currentEpoch: epoch,
        localRole: fold.epochs[epoch]!.members[localNodeId.hex],
      );
    } finally {
      stored.wipeLocalEpochKeys();
    }
  }

  Future<CloudCollectionDocumentState?> loadCollection(
    String documentId,
  ) async {
    final stored = await _store.load(documentId);
    final expectedCodec = stored == null
        ? null
        : cloudCollectionCodec(stored.root.kind);
    if (stored == null ||
        expectedCodec == null ||
        stored.root.codec != expectedCodec) {
      stored?.wipeLocalEpochKeys();
      return null;
    }
    try {
      final frame = _frameFromStored(CloudDocumentFrameKind.snapshot, stored);
      final fold = _fold(frame);
      if (!_completeAndValid(frame, fold)) return null;
      final snapshot = await _materializeCollection(stored, fold);
      if (snapshot == null) return null;
      final epoch = fold.epochs.keys.reduce((a, b) => a > b ? a : b);
      return CloudCollectionDocumentState(
        kind: stored.root.kind,
        snapshot: snapshot,
        currentEpoch: epoch,
        localRole: fold.epochs[epoch]!.members[localNodeId.hex],
      );
    } finally {
      stored.wipeLocalEpochKeys();
    }
  }

  /// Appends already-planned rich-text operations against an explicit causal
  /// view. Passing the heads shown by an editor is what keeps a remote edit
  /// that arrived later concurrent instead of silently overwriting it.
  Future<CloudDocumentMutationResult?> appendRichTextEdits(
    String documentId,
    List<CloudRichTextEdit> edits, {
    List<String>? parentOperationIds,
  }) => _serialized(() async {
    if (edits.isEmpty) return null;
    final signer = _signer;
    if (signer == null || signer.selfId != localNodeId) return null;
    final stored = await _store.load(documentId);
    if (stored == null ||
        stored.root.kind != CloudDocumentKind.note ||
        stored.root.codec != cloudRichTextCodecV1) {
      stored?.wipeLocalEpochKeys();
      return null;
    }
    final newCleartexts = <String, Uint8List>{};
    try {
      final oldFrame = _frameFromStored(
        CloudDocumentFrameKind.snapshot,
        stored,
      );
      final oldFold = _fold(oldFrame);
      if (!_completeAndValid(oldFrame, oldFold)) return null;
      final epoch = oldFold.epochs.keys.reduce((a, b) => a > b ? a : b);
      final state = oldFold.epochs[epoch]!;
      final role = state.members[localNodeId.hex];
      if (role != CloudDocumentRole.owner && role != CloudDocumentRole.editor) {
        return null;
      }
      final epochKey = stored.localEpochKeys[epoch];
      if (epochKey == null) return null;
      final knownIds = oldFold.acceptedOperations
          .map((operation) => operation.operationId)
          .toSet();
      var heads =
          parentOperationIds == null
                ? _operationHeads(oldFold.acceptedOperations)
                : parentOperationIds.toSet().toList()
            ..sort();
      if (heads.length != heads.toSet().length ||
          heads.any((id) => !knownIds.contains(id))) {
        return null;
      }

      final operations = [...oldFold.acceptedOperations];
      final payloads = [...stored.payloads];
      final authored =
          operations
              .where((operation) => operation.author == localNodeId)
              .toList()
            ..sort((left, right) => left.seq.compareTo(right.seq));
      var nextSeq = authored.isEmpty ? 0 : authored.last.seq + 1;
      var previousAuthorHash = authored.isEmpty ? '' : authored.last.recordHash;

      Future<CloudDocumentOperation> appendOne(
        CloudRichTextEdit edit,
        List<String> parents,
      ) async {
        if (parents.length > 32) {
          throw StateError('too many document operation parents');
        }
        final clear = edit.encode();
        final unsigned = CloudDocumentOperation(
          documentId: stored.root.documentId,
          membershipEpoch: epoch,
          author: localNodeId,
          seq: nextSeq,
          prevAuthorHash: previousAuthorHash,
          operationId: _randomHex32(),
          parentOperationIds: [...parents]..sort(),
          opType: cloudRichTextOperationType,
          // The payload hash is not part of AEAD AAD; encryption computes the
          // final value and withPayloadHash replaces this valid placeholder.
          payloadHash: _randomHex32(),
          createdAtMs: _now().millisecondsSinceEpoch,
          authorPubKey: Uint8List(32),
          signature: Uint8List(64),
        );
        try {
          final encrypted = await encryptCloudDocumentPayload(
            operation: unsigned,
            clearText: clear,
            epochKey: epochKey,
            random: _random,
          );
          final signed = signer.signOperation(
            unsigned.withPayloadHash(encrypted.payloadHash),
          );
          operations.add(signed);
          payloads.add(encrypted);
          newCleartexts[signed.operationId] = Uint8List.fromList(clear);
          nextSeq++;
          previousAuthorHash = signed.recordHash;
          return signed;
        } finally {
          clear.fillRange(0, clear.length, 0);
        }
      }

      // The signed wire permits 32 parents. Fold a pathological set of
      // concurrent heads through authenticated no-op merge records instead of
      // dropping branches or refusing a valid offline document forever.
      while (heads.length > 32) {
        final batch = heads.take(32).toList();
        final merged = await appendOne(const CloudRichTextEdit.merge(), batch);
        heads = [...heads.skip(32), merged.operationId]..sort();
      }
      for (final edit in edits) {
        final operation = await appendOne(edit, heads);
        heads = [operation.operationId];
      }

      final bundle = CloudDocumentStoredBundle(
        root: stored.root,
        controls: oldFold.acceptedControls,
        operations: operations,
        envelopes: stored.envelopes,
        localEpochKeys: stored.localEpochKeys,
        payloads: payloads,
      );
      final frame = _frameFromStored(CloudDocumentFrameKind.snapshot, bundle);
      final fold = _fold(frame);
      if (!_completeAndValid(frame, fold) || !bundle.isStructurallyValid) {
        return null;
      }
      final snapshot = await _materializeRichText(
        bundle,
        fold,
        extraCleartexts: newCleartexts,
      );
      if (snapshot == null ||
          snapshot.invalidOperationIds.any(newCleartexts.containsKey)) {
        return null;
      }
      await _store.save(bundle);
      _emit();
      final failed = <NodeId>[];
      for (final member in state.members.keys) {
        if (member == localNodeId.hex) continue;
        final peer = NodeId.fromHex(member);
        try {
          await sendDelta(peer, bundle);
        } catch (_) {
          failed.add(peer);
        }
      }
      return CloudDocumentMutationResult(
        documentId: documentId,
        failedRecipients: List.unmodifiable(failed),
      );
    } finally {
      for (final clear in newCleartexts.values) {
        clear.fillRange(0, clear.length, 0);
      }
      stored.wipeLocalEpochKeys();
    }
  });

  /// Appends task/calendar map operations against the heads visible to the
  /// editor. The signed epoch log supplies causality; the collection CRDT
  /// resolves independent fields and delete/create conflicts deterministically.
  Future<CloudDocumentMutationResult?> appendCollectionEdits(
    String documentId,
    List<CloudCollectionEdit> edits, {
    List<String>? parentOperationIds,
  }) => _serialized(() async {
    if (edits.isEmpty) return null;
    final signer = _signer;
    if (signer == null || signer.selfId != localNodeId) return null;
    final stored = await _store.load(documentId);
    final expectedCodec = stored == null
        ? null
        : cloudCollectionCodec(stored.root.kind);
    final operationType = stored == null
        ? null
        : cloudCollectionOperationType(stored.root.kind);
    if (stored == null ||
        expectedCodec == null ||
        operationType == null ||
        stored.root.codec != expectedCodec) {
      stored?.wipeLocalEpochKeys();
      return null;
    }
    final newCleartexts = <String, Uint8List>{};
    try {
      final oldFrame = _frameFromStored(
        CloudDocumentFrameKind.snapshot,
        stored,
      );
      final oldFold = _fold(oldFrame);
      if (!_completeAndValid(oldFrame, oldFold)) return null;
      final epoch = oldFold.epochs.keys.reduce((a, b) => a > b ? a : b);
      final state = oldFold.epochs[epoch]!;
      final role = state.members[localNodeId.hex];
      if (role != CloudDocumentRole.owner && role != CloudDocumentRole.editor) {
        return null;
      }
      final epochKey = stored.localEpochKeys[epoch];
      if (epochKey == null) return null;
      final knownIds = oldFold.acceptedOperations
          .map((operation) => operation.operationId)
          .toSet();
      var heads =
          parentOperationIds == null
                ? _operationHeads(oldFold.acceptedOperations)
                : parentOperationIds.toSet().toList()
            ..sort();
      if (heads.length != heads.toSet().length ||
          heads.any((id) => !knownIds.contains(id))) {
        return null;
      }

      final operations = [...oldFold.acceptedOperations];
      final payloads = [...stored.payloads];
      final authored =
          operations
              .where((operation) => operation.author == localNodeId)
              .toList()
            ..sort((left, right) => left.seq.compareTo(right.seq));
      var nextSeq = authored.isEmpty ? 0 : authored.last.seq + 1;
      var previousAuthorHash = authored.isEmpty ? '' : authored.last.recordHash;

      Future<CloudDocumentOperation> appendOne(
        CloudCollectionEdit edit,
        List<String> parents,
      ) async {
        if (parents.length > 32) {
          throw StateError('too many document operation parents');
        }
        final clear = edit.encode();
        final unsigned = CloudDocumentOperation(
          documentId: stored.root.documentId,
          membershipEpoch: epoch,
          author: localNodeId,
          seq: nextSeq,
          prevAuthorHash: previousAuthorHash,
          operationId: _randomHex32(),
          parentOperationIds: [...parents]..sort(),
          opType: operationType,
          payloadHash: _randomHex32(),
          createdAtMs: _now().millisecondsSinceEpoch,
          authorPubKey: Uint8List(32),
          signature: Uint8List(64),
        );
        try {
          final encrypted = await encryptCloudDocumentPayload(
            operation: unsigned,
            clearText: clear,
            epochKey: epochKey,
            random: _random,
          );
          final signed = signer.signOperation(
            unsigned.withPayloadHash(encrypted.payloadHash),
          );
          operations.add(signed);
          payloads.add(encrypted);
          newCleartexts[signed.operationId] = Uint8List.fromList(clear);
          nextSeq++;
          previousAuthorHash = signed.recordHash;
          return signed;
        } finally {
          clear.fillRange(0, clear.length, 0);
        }
      }

      while (heads.length > 32) {
        final batch = heads.take(32).toList();
        final merged = await appendOne(CloudCollectionEdit.merge(), batch);
        heads = [...heads.skip(32), merged.operationId]..sort();
      }
      for (final edit in edits) {
        final operation = await appendOne(edit, heads);
        heads = [operation.operationId];
      }

      final bundle = CloudDocumentStoredBundle(
        root: stored.root,
        controls: oldFold.acceptedControls,
        operations: operations,
        envelopes: stored.envelopes,
        localEpochKeys: stored.localEpochKeys,
        payloads: payloads,
      );
      final frame = _frameFromStored(CloudDocumentFrameKind.snapshot, bundle);
      final fold = _fold(frame);
      if (!_completeAndValid(frame, fold) || !bundle.isStructurallyValid) {
        return null;
      }
      final snapshot = await _materializeCollection(
        bundle,
        fold,
        extraCleartexts: newCleartexts,
      );
      if (snapshot == null ||
          snapshot.invalidOperationIds.any(newCleartexts.containsKey)) {
        return null;
      }
      await _store.save(bundle);
      _emit();
      final failed = <NodeId>[];
      for (final member in state.members.keys) {
        if (member == localNodeId.hex) continue;
        final peer = NodeId.fromHex(member);
        try {
          await sendDelta(peer, bundle);
        } catch (_) {
          failed.add(peer);
        }
      }
      return CloudDocumentMutationResult(
        documentId: documentId,
        failedRecipients: List.unmodifiable(failed),
      );
    } finally {
      for (final clear in newCleartexts.values) {
        clear.fillRange(0, clear.length, 0);
      }
      stored.wipeLocalEpochKeys();
    }
  });

  Future<CloudDocumentMutationResult?> saveRichText(
    String documentId, {
    required CloudRichTextSnapshot base,
    required String text,
    required List<CloudRichTextStyle> styles,
  }) async {
    final desired = text.characters.toList();
    if (desired.length != styles.length) return null;
    final current = base.atoms.map((atom) => atom.value).toList();
    var prefix = 0;
    while (prefix < current.length &&
        prefix < desired.length &&
        current[prefix] == desired[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < current.length - prefix &&
        suffix < desired.length - prefix &&
        current[current.length - 1 - suffix] ==
            desired[desired.length - 1 - suffix]) {
      suffix++;
    }

    final edits = <CloudRichTextEdit>[];
    final removed =
        base.atoms
            .sublist(prefix, current.length - suffix)
            .map((atom) => atom.id)
            .toList()
          ..sort();
    if (removed.isNotEmpty) edits.add(CloudRichTextEdit.delete(removed));
    final inserted = desired.sublist(prefix, desired.length - suffix);
    if (inserted.isNotEmpty) {
      edits.add(
        CloudRichTextEdit.insertStyled(
          afterAtomId: prefix == 0 ? null : base.atoms[prefix - 1].id,
          text: inserted.join(),
          styles: styles.sublist(prefix, desired.length - suffix),
        ),
      );
    }

    final formats = <CloudRichTextStyle, List<String>>{};
    void formatIfChanged(int oldIndex, int desiredIndex) {
      final atom = base.atoms[oldIndex];
      final wanted = styles[desiredIndex];
      if (atom.style != wanted) {
        formats.putIfAbsent(wanted, () => []).add(atom.id);
      }
    }

    for (var index = 0; index < prefix; index++) {
      formatIfChanged(index, index);
    }
    for (var index = 0; index < suffix; index++) {
      formatIfChanged(
        current.length - suffix + index,
        desired.length - suffix + index,
      );
    }
    for (final entry in formats.entries) {
      entry.value.sort();
      edits.add(
        CloudRichTextEdit.format(targetAtomIds: entry.value, style: entry.key),
      );
    }
    if (edits.isEmpty) {
      return CloudDocumentMutationResult(documentId: documentId);
    }
    return appendRichTextEdits(
      documentId,
      edits,
      parentOperationIds: base.headOperationIds,
    );
  }

  Future<CloudDocumentMutationResult?> deleteRichTextDocument(
    String documentId, {
    required List<String> parentOperationIds,
  }) => appendRichTextEdits(documentId, const [
    CloudRichTextEdit.documentDelete(),
  ], parentOperationIds: parentOperationIds);

  Future<CloudRichTextSnapshot?> _materializeRichText(
    CloudDocumentStoredBundle stored,
    CloudDocumentFoldResult fold, {
    Map<String, Uint8List> extraCleartexts = const {},
  }) async {
    final cleartexts = <String, Uint8List>{};
    try {
      for (final operation in fold.acceptedOperations) {
        final supplied = extraCleartexts[operation.operationId];
        if (supplied != null) {
          cleartexts[operation.operationId] = Uint8List.fromList(supplied);
          continue;
        }
        final key = stored.localEpochKeys[operation.membershipEpoch];
        if (key == null) continue;
        final payload = stored.payloads
            .where(
              (candidate) => candidate.operationId == operation.operationId,
            )
            .firstOrNull;
        if (payload == null) return null;
        cleartexts[operation.operationId] = await decryptCloudDocumentPayload(
          operation: operation,
          payload: payload,
          epochKey: key,
        );
      }
      return materializeCloudRichText(
        operations: fold.acceptedOperations,
        cleartextByOperationId: cleartexts,
        checkpointOwner: stored.root.owner,
      );
    } catch (_) {
      return null;
    } finally {
      for (final clear in cleartexts.values) {
        clear.fillRange(0, clear.length, 0);
      }
    }
  }

  Future<CloudCollectionSnapshot?> _materializeCollection(
    CloudDocumentStoredBundle stored,
    CloudDocumentFoldResult fold, {
    Map<String, Uint8List> extraCleartexts = const {},
  }) async {
    final cleartexts = <String, Uint8List>{};
    try {
      for (final operation in fold.acceptedOperations) {
        final supplied = extraCleartexts[operation.operationId];
        if (supplied != null) {
          cleartexts[operation.operationId] = Uint8List.fromList(supplied);
          continue;
        }
        final key = stored.localEpochKeys[operation.membershipEpoch];
        if (key == null) continue;
        final payload = stored.payloads
            .where(
              (candidate) => candidate.operationId == operation.operationId,
            )
            .firstOrNull;
        if (payload == null) return null;
        cleartexts[operation.operationId] = await decryptCloudDocumentPayload(
          operation: operation,
          payload: payload,
          epochKey: key,
        );
      }
      return materializeCloudCollection(
        documentKind: stored.root.kind,
        owner: stored.root.owner,
        operations: fold.acceptedOperations,
        cleartextByOperationId: cleartexts,
      );
    } catch (_) {
      return null;
    } finally {
      for (final clear in cleartexts.values) {
        clear.fillRange(0, clear.length, 0);
      }
    }
  }

  List<String> _operationHeads(List<CloudDocumentOperation> operations) {
    final parents = <String>{
      for (final operation in operations) ...operation.parentOperationIds,
    };
    return operations
        .map((operation) => operation.operationId)
        .where((id) => !parents.contains(id))
        .toList()
      ..sort();
  }

  Future<CloudDocumentMutationResult?> createDocument({
    CloudDocumentKind kind = CloudDocumentKind.note,
    String codec = 'xveil.note.rga.v1',
  }) => _serialized(() async {
    final expectedCodec = switch (kind) {
      CloudDocumentKind.note => cloudRichTextCodecV1,
      CloudDocumentKind.taskList => cloudTaskListCodecV1,
      CloudDocumentKind.calendar => cloudCalendarCodecV1,
    };
    if (codec != expectedCodec) return null;
    final signer = _signer;
    if (signer == null || signer.selfId != localNodeId) return null;
    final documentId = NodeId(_randomBytes(32));
    final epochKey = _randomBytes(32);
    try {
      final envelope = await _envelopes.sealEpoch(
        documentId: documentId,
        epoch: 0,
        epochKey: epochKey,
        recipients: [localNodeId],
      );
      final unsigned = CloudDocumentRoot(
        documentId: documentId,
        owner: localNodeId,
        ownerPubKey: Uint8List(32),
        kind: kind,
        codec: codec,
        epochKeyCommitment: envelope.keyCommitment,
        epochEnvelopeHash: envelope.bundleHash,
        controlLogRoot: _randomHex32(),
        createdAtMs: _now().millisecondsSinceEpoch,
        signature: Uint8List(64),
      );
      final root = signer.signRoot(unsigned);
      final signingNode = NodeId(blake3Hash(root.ownerPubKey));
      final bundle = CloudDocumentStoredBundle(
        root: root,
        controls: const [],
        operations: const [],
        envelopes: [envelope],
        localEpochKeys: {0: epochKey},
      );
      final frame = _frameFromStored(CloudDocumentFrameKind.snapshot, bundle);
      final fold = _fold(frame);
      if (!_completeAndValid(frame, fold) || !bundle.isStructurallyValid) {
        throw StateError(
          'locally generated document failed validation '
          '(root=${fold.rootValid} owner=${localNodeId.short} '
          'signer=${signingNode.short} controls=${fold.rejectedControls.length} '
          'operations=${fold.rejectedOperations.length} '
          'withheld=${fold.withheldOperations.length} '
          'incomplete=${fold.incompleteEpochs.length} '
          'bundle=${bundle.isStructurallyValid})',
        );
      }
      await _store.save(bundle);
      _emit();
      return CloudDocumentMutationResult(documentId: documentId.hex);
    } finally {
      epochKey.fillRange(0, epochKey.length, 0);
    }
  });

  Future<CloudDocumentMutationResult?> grant(
    String documentId,
    NodeId peer,
    CloudDocumentRole role,
  ) => _changeAcl(
    documentId: documentId,
    op: CloudDocumentControlOp.grant,
    target: peer,
    role: role,
  );

  Future<CloudDocumentMutationResult?> setRole(
    String documentId,
    NodeId peer,
    CloudDocumentRole role,
  ) => _changeAcl(
    documentId: documentId,
    op: CloudDocumentControlOp.setRole,
    target: peer,
    role: role,
  );

  Future<CloudDocumentMutationResult?> revoke(String documentId, NodeId peer) =>
      _changeAcl(
        documentId: documentId,
        op: CloudDocumentControlOp.revoke,
        target: peer,
      );

  Future<CloudDocumentMutationResult?> rotateEpoch(String documentId) =>
      _changeAcl(
        documentId: documentId,
        op: CloudDocumentControlOp.rotateEpoch,
      );

  Future<bool> resendInvite(String documentId, NodeId peer) async {
    if (!await _acceptedContact(peer)) return false;
    final stored = await _store.load(documentId);
    if (stored == null || stored.root.owner != localNodeId) return false;
    try {
      final frame = _frameFromStored(CloudDocumentFrameKind.snapshot, stored);
      final fold = _fold(frame);
      if (!_completeAndValid(frame, fold)) return false;
      final latest = fold.epochs.keys.reduce((a, b) => a > b ? a : b);
      if (!fold.epochs[latest]!.members.containsKey(peer.hex)) return false;
      await sendInvite(peer, stored);
      return true;
    } catch (_) {
      return false;
    } finally {
      stored.wipeLocalEpochKeys();
    }
  }

  Future<CloudDocumentMutationResult?> _changeAcl({
    required String documentId,
    required CloudDocumentControlOp op,
    NodeId? target,
    CloudDocumentRole? role,
  }) => _serialized(() async {
    final signer = _signer;
    if (signer == null || signer.selfId != localNodeId) return null;
    if (op == CloudDocumentControlOp.grant &&
        (target == null || !await _acceptedContact(target))) {
      return null;
    }
    final stored = await _store.load(documentId);
    if (stored == null || stored.root.owner != localNodeId) return null;
    try {
      final oldFrame = _frameFromStored(
        CloudDocumentFrameKind.snapshot,
        stored,
      );
      final oldFold = _fold(oldFrame);
      if (!_completeAndValid(oldFrame, oldFold)) return null;
      final currentEpoch = oldFold.epochs.keys.reduce((a, b) => a > b ? a : b);
      final current = oldFold.epochs[currentEpoch]!;
      final nextMembers = Map<String, CloudDocumentRole>.from(current.members);
      switch (op) {
        case CloudDocumentControlOp.grant:
          if (target == localNodeId ||
              nextMembers.containsKey(target!.hex) ||
              (role != CloudDocumentRole.editor &&
                  role != CloudDocumentRole.viewer)) {
            return null;
          }
          nextMembers[target.hex] = role!;
          break;
        case CloudDocumentControlOp.setRole:
          final oldRole = target == null ? null : nextMembers[target.hex];
          if (oldRole == null ||
              oldRole == CloudDocumentRole.owner ||
              oldRole == role ||
              (role != CloudDocumentRole.editor &&
                  role != CloudDocumentRole.viewer)) {
            return null;
          }
          nextMembers[target!.hex] = role!;
          break;
        case CloudDocumentControlOp.revoke:
          final oldRole = target == null ? null : nextMembers[target.hex];
          if (oldRole == null || oldRole == CloudDocumentRole.owner) {
            return null;
          }
          nextMembers.remove(target!.hex);
          break;
        case CloudDocumentControlOp.rotateEpoch:
          if (target != null || role != null) return null;
          break;
      }

      final nextEpoch = currentEpoch + 1;
      final nextKey = _randomBytes(32);
      try {
        final envelope = await _envelopes.sealEpoch(
          documentId: stored.root.documentId,
          epoch: nextEpoch,
          epochKey: nextKey,
          recipients: [
            for (final member in nextMembers.keys) NodeId.fromHex(member),
          ],
        );
        final frontier = <String, CloudDocumentAuthorHead>{};
        for (final operation in oldFold.acceptedOperations) {
          // Closures carry the cumulative per-author head through the epoch,
          // not only records authored inside that one epoch. Otherwise a later
          // key-only rotation would appear to erase the prior signed prefix.
          if (operation.membershipEpoch > currentEpoch) continue;
          final prior = frontier[operation.author.hex];
          if (prior == null || operation.seq > prior.seq) {
            frontier[operation.author.hex] = CloudDocumentAuthorHead(
              seq: operation.seq,
              hash: operation.recordHash,
            );
          }
        }
        final unsigned = CloudDocumentControlEntry(
          documentId: stored.root.documentId,
          author: localNodeId,
          seq: oldFold.acceptedControls.length,
          prevControlHash: oldFold.acceptedControls.isEmpty
              ? stored.root.controlLogRoot
              : oldFold.acceptedControls.last.recordHash,
          controlId: _randomHex32(),
          membershipEpoch: currentEpoch,
          nextEpoch: nextEpoch,
          op: op,
          target: target,
          role: role,
          epochKeyCommitment: envelope.keyCommitment,
          epochEnvelopeHash: envelope.bundleHash,
          closedEpochFrontier: frontier,
          createdAtMs: _now().millisecondsSinceEpoch,
          authorPubKey: Uint8List(32),
          signature: Uint8List(64),
        );
        final control = signer.signControl(unsigned);
        final keys = <int, Uint8List>{
          for (final entry in stored.localEpochKeys.entries)
            entry.key: Uint8List.fromList(entry.value),
          nextEpoch: Uint8List.fromList(nextKey),
        };
        Uint8List? checkpointClear;
        try {
          var operations = oldFold.acceptedOperations;
          var payloads = stored.payloads;
          String? checkpointOperationType;
          if (op == CloudDocumentControlOp.grant) {
            if (stored.root.kind == CloudDocumentKind.note &&
                stored.root.codec == cloudRichTextCodecV1) {
              final snapshot = await _materializeRichText(stored, oldFold);
              if (snapshot == null || snapshot.invalidOperationIds.isNotEmpty) {
                return null;
              }
              checkpointClear = CloudRichTextEdit.checkpoint(
                text: snapshot.text,
                styles: snapshot.atoms.map((atom) => atom.style).toList(),
              ).encode();
              checkpointOperationType = cloudRichTextOperationType;
            } else if (stored.root.codec ==
                cloudCollectionCodec(stored.root.kind)) {
              final snapshot = await _materializeCollection(stored, oldFold);
              if (snapshot == null || snapshot.invalidOperationIds.isNotEmpty) {
                return null;
              }
              checkpointClear = CloudCollectionEdit.checkpoint(
                snapshot.rows,
              ).encode();
              checkpointOperationType = cloudCollectionOperationType(
                stored.root.kind,
              );
            }
          }
          if (checkpointClear != null && checkpointOperationType != null) {
            final authored =
                oldFold.acceptedOperations
                    .where((operation) => operation.author == localNodeId)
                    .toList()
                  ..sort((left, right) => left.seq.compareTo(right.seq));
            final checkpointUnsigned = CloudDocumentOperation(
              documentId: stored.root.documentId,
              membershipEpoch: nextEpoch,
              author: localNodeId,
              seq: authored.isEmpty ? 0 : authored.last.seq + 1,
              prevAuthorHash: authored.isEmpty ? '' : authored.last.recordHash,
              operationId: _randomHex32(),
              parentOperationIds: _operationHeads(
                oldFold.acceptedOperations,
              ).take(32).toList(),
              opType: checkpointOperationType,
              payloadHash: _randomHex32(),
              createdAtMs: _now().millisecondsSinceEpoch,
              authorPubKey: Uint8List(32),
              signature: Uint8List(64),
            );
            final checkpointPayload = await encryptCloudDocumentPayload(
              operation: checkpointUnsigned,
              clearText: checkpointClear,
              epochKey: nextKey,
              random: _random,
            );
            final checkpoint = signer.signOperation(
              checkpointUnsigned.withPayloadHash(checkpointPayload.payloadHash),
            );
            operations = [...operations, checkpoint];
            payloads = [...payloads, checkpointPayload];
          }
          final bundle = CloudDocumentStoredBundle(
            root: stored.root,
            controls: [...oldFold.acceptedControls, control],
            operations: operations,
            envelopes: [...stored.envelopes, envelope],
            localEpochKeys: keys,
            payloads: payloads,
          );
          final frame = _frameFromStored(
            CloudDocumentFrameKind.snapshot,
            bundle,
          );
          final fold = _fold(frame);
          if (!_completeAndValid(frame, fold) || !bundle.isStructurallyValid) {
            return null;
          }
          await _store.save(bundle);
          _emit();
          final failed = await _fanoutAclMutation(
            bundle: bundle,
            oldMembers: current.members,
            newMembers: nextMembers,
            op: op,
            target: target,
          );
          return CloudDocumentMutationResult(
            documentId: documentId,
            failedRecipients: List.unmodifiable(failed),
          );
        } finally {
          checkpointClear?.fillRange(0, checkpointClear.length, 0);
          for (final key in keys.values) {
            key.fillRange(0, key.length, 0);
          }
        }
      } finally {
        nextKey.fillRange(0, nextKey.length, 0);
      }
    } catch (_) {
      return null;
    } finally {
      stored.wipeLocalEpochKeys();
    }
  });

  Future<List<NodeId>> _fanoutAclMutation({
    required CloudDocumentStoredBundle bundle,
    required Map<String, CloudDocumentRole> oldMembers,
    required Map<String, CloudDocumentRole> newMembers,
    required CloudDocumentControlOp op,
    required NodeId? target,
  }) async {
    final recipients = {...oldMembers.keys, ...newMembers.keys}
      ..remove(localNodeId.hex);
    final failed = <NodeId>[];
    for (final id in recipients) {
      final peer = NodeId.fromHex(id);
      try {
        if (op == CloudDocumentControlOp.grant && peer == target) {
          await sendInvite(peer, bundle);
        } else if (newMembers.containsKey(id)) {
          await sendSnapshot(peer, bundle);
        } else if (op == CloudDocumentControlOp.revoke && peer == target) {
          final frame = _frameFromStored(
            CloudDocumentFrameKind.snapshot,
            bundle,
          );
          await _sendFrame(peer, bundle.root.documentId.hex, frame.encode());
        }
      } catch (_) {
        failed.add(peer);
      }
    }
    return failed;
  }

  Uint8List _randomBytes(int count) {
    final bytes = Uint8List(count);
    for (var index = 0; index < count; index++) {
      bytes[index] = _random.nextInt(256);
    }
    return bytes;
  }

  String _randomHex32() => _randomBytes(
    32,
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  Future<List<CloudDocumentPendingInvite>> pendingInvites() async {
    final result = <CloudDocumentPendingInvite>[];
    for (final id in await _store.listPendingInviteIds()) {
      final invite = await _store.loadPendingInvite(id);
      if (invite != null) result.add(invite);
    }
    result.sort((a, b) => b.receivedAtMs.compareTo(a.receivedAtMs));
    return result;
  }

  /// Receive an accepted-contact frame. Invalid/unauthorized input is silently
  /// discarded: the return value is local diagnostics only and never ack data.
  Future<bool> ingest(NodeId sender, String frameJson) =>
      _serialized(() => _ingest(sender, frameJson));

  Future<bool> _ingest(NodeId sender, String frameJson) async {
    final incoming = CloudDocumentFrame.decode(frameJson);
    if (incoming == null) return false;
    if (incoming.kind == CloudDocumentFrameKind.invite) {
      return _ingestInvite(sender, incoming);
    }
    final existing = await _store.load(incoming.root.documentId.hex);
    if (existing == null) return false;
    try {
      final existingFrame = _frameFromStored(
        CloudDocumentFrameKind.snapshot,
        existing,
      );
      final oldFold = _fold(existingFrame);
      if (!_completeAndValid(existingFrame, oldFold)) return false;
      final latestEpoch = oldFold.epochs.keys.reduce((a, b) => a > b ? a : b);
      if (!oldFold.epochs[latestEpoch]!.members.containsKey(sender.hex)) {
        return false;
      }
      final merged = _merge(existingFrame, incoming);
      if (merged == null) return false;
      final fold = _fold(merged);
      if (!_completeAndValid(merged, fold)) return false;
      final keys = <int, Uint8List>{
        for (final entry in existing.localEpochKeys.entries)
          entry.key: Uint8List.fromList(entry.value),
      };
      try {
        await _openMissingKeys(merged, fold, keys);
        if (!await _validateAccessiblePayloads(merged, fold, keys)) {
          return false;
        }
        await _store.save(
          CloudDocumentStoredBundle(
            root: merged.root,
            controls: fold.acceptedControls,
            operations: fold.acceptedOperations,
            envelopes: merged.envelopes,
            localEpochKeys: keys,
            payloads: merged.payloads,
          ),
        );
      } finally {
        for (final key in keys.values) {
          key.fillRange(0, key.length, 0);
        }
      }
      _emit();
      return true;
    } finally {
      existing.wipeLocalEpochKeys();
    }
  }

  Future<bool> _ingestInvite(NodeId sender, CloudDocumentFrame frame) async {
    if (sender != frame.root.owner ||
        await _store.load(frame.root.documentId.hex) != null) {
      return false;
    }
    final fold = _fold(frame);
    if (!_completeAndValid(frame, fold)) return false;
    final latest = fold.epochs.keys.reduce((a, b) => a > b ? a : b);
    if (!fold.epochs[latest]!.members.containsKey(localNodeId.hex)) {
      return false;
    }
    final envelope = frame.envelopes.firstWhere(
      (entry) => entry.epoch == latest,
    );
    if (envelope.envelopeFor(localNodeId) == null) return false;
    await _store.savePendingInvite(
      CloudDocumentPendingInvite(
        sender: sender,
        receivedAtMs: _now().millisecondsSinceEpoch,
        frame: frame,
      ),
    );
    _emit();
    return true;
  }

  Future<bool> adopt(String documentId) =>
      _serialized(() => _adopt(documentId));

  Future<bool> _adopt(String documentId) async {
    final pending = await _store.loadPendingInvite(documentId);
    if (pending == null) return false;
    final frame = pending.frame;
    final fold = _fold(frame);
    if (pending.sender != frame.root.owner || !_completeAndValid(frame, fold)) {
      return false;
    }
    final latest = fold.epochs.keys.reduce((a, b) => a > b ? a : b);
    if (!fold.epochs[latest]!.members.containsKey(localNodeId.hex)) {
      return false;
    }
    final keys = <int, Uint8List>{};
    try {
      await _openMissingKeys(frame, fold, keys);
      if (!keys.containsKey(latest)) return false;
      if (!await _validateAccessiblePayloads(frame, fold, keys)) return false;
      await _store.save(
        CloudDocumentStoredBundle(
          root: frame.root,
          controls: fold.acceptedControls,
          operations: fold.acceptedOperations,
          envelopes: frame.envelopes,
          localEpochKeys: keys,
          payloads: frame.payloads,
        ),
      );
      await _store.removePendingInvite(documentId);
      _emit();
      return true;
    } catch (_) {
      return false;
    } finally {
      for (final key in keys.values) {
        key.fillRange(0, key.length, 0);
      }
    }
  }

  Future<void> dismissInvite(String documentId) => _serialized(() async {
    await _store.removePendingInvite(documentId);
    _emit();
  });

  /// Decrypts one authenticated operation entirely in RAM. The returned bytes
  /// are owned by the caller and must never be written outside the deniable
  /// content store.
  Future<Uint8List?> decryptOperation(
    String documentId,
    String operationId,
  ) async {
    final stored = await _store.load(documentId);
    if (stored == null) return null;
    try {
      CloudDocumentOperation? operation;
      for (final candidate in stored.operations) {
        if (candidate.operationId == operationId) operation = candidate;
      }
      CloudDocumentEncryptedPayload? payload;
      for (final candidate in stored.payloads) {
        if (candidate.operationId == operationId) payload = candidate;
      }
      if (operation == null || payload == null) return null;
      final key = stored.localEpochKeys[operation.membershipEpoch];
      if (key == null) return null;
      return await decryptCloudDocumentPayload(
        operation: operation,
        payload: payload,
        epochKey: key,
      );
    } catch (_) {
      return null;
    } finally {
      stored.wipeLocalEpochKeys();
    }
  }

  Future<void> _openMissingKeys(
    CloudDocumentFrame frame,
    CloudDocumentFoldResult fold,
    Map<int, Uint8List> keys,
  ) async {
    for (final envelope in frame.envelopes) {
      if (keys.containsKey(envelope.epoch) ||
          envelope.envelopeFor(localNodeId) == null ||
          !fold.epochs[envelope.epoch]!.members.containsKey(localNodeId.hex)) {
        continue;
      }
      final opened = await _envelopes.openEpoch(
        bundle: envelope,
        expectedBundleHash: fold.epochs[envelope.epoch]!.epochEnvelopeHash,
        recipient: localNodeId,
        expectedOwner: frame.root.owner,
        ourCertVersion: ourCertVersion,
      );
      keys[envelope.epoch] = Uint8List.fromList(opened.key);
      opened.key.fillRange(0, opened.key.length, 0);
    }
  }

  Future<bool> _validateAccessiblePayloads(
    CloudDocumentFrame frame,
    CloudDocumentFoldResult fold,
    Map<int, Uint8List> keys,
  ) async {
    final byId = {
      for (final payload in frame.payloads) payload.operationId: payload,
    };
    for (final operation in fold.acceptedOperations) {
      final epoch = fold.epochs[operation.membershipEpoch];
      if (epoch == null || !epoch.members.containsKey(localNodeId.hex)) {
        continue;
      }
      final key = keys[operation.membershipEpoch];
      final payload = byId[operation.operationId];
      if (key == null || payload == null) return false;
      Uint8List? clear;
      try {
        clear = await decryptCloudDocumentPayload(
          operation: operation,
          payload: payload,
          epochKey: key,
        );
      } catch (_) {
        return false;
      } finally {
        clear?.fillRange(0, clear.length, 0);
      }
    }
    return true;
  }

  Future<void> sendInvite(NodeId peer, CloudDocumentStoredBundle bundle) async {
    await _send(
      peer,
      CloudDocumentFrameKind.invite,
      bundle,
      requireOwner: true,
    );
  }

  Future<void> sendSnapshot(NodeId peer, CloudDocumentStoredBundle bundle) =>
      _send(peer, CloudDocumentFrameKind.snapshot, bundle);

  Future<void> sendDelta(NodeId peer, CloudDocumentStoredBundle bundle) =>
      _send(peer, CloudDocumentFrameKind.delta, bundle);

  Future<void> _send(
    NodeId peer,
    CloudDocumentFrameKind kind,
    CloudDocumentStoredBundle bundle, {
    bool requireOwner = false,
  }) async {
    final frame = _frameFromStored(kind, bundle);
    final fold = _fold(frame);
    if (!_completeAndValid(frame, fold) ||
        (requireOwner && frame.root.owner != localNodeId)) {
      throw StateError('document frame rejected');
    }
    final latest = fold.epochs.keys.reduce((a, b) => a > b ? a : b);
    if (!fold.epochs[latest]!.members.containsKey(peer.hex)) {
      throw StateError('document recipient is not a current member');
    }
    await _sendFrame(peer, frame.root.documentId.hex, frame.encode());
  }

  CloudDocumentFrame _frameFromStored(
    CloudDocumentFrameKind kind,
    CloudDocumentStoredBundle bundle,
  ) => CloudDocumentFrame(
    kind: kind,
    root: bundle.root,
    controls: bundle.controls,
    operations: bundle.operations,
    envelopes: bundle.envelopes,
    payloads: bundle.payloads,
  );

  CloudDocumentFrame? _merge(
    CloudDocumentFrame existing,
    CloudDocumentFrame incoming,
  ) {
    if (jsonEncode(existing.root.toJson()) !=
        jsonEncode(incoming.root.toJson())) {
      return null;
    }
    final controls = <String, CloudDocumentControlEntry>{};
    for (final entry in [...existing.controls, ...incoming.controls]) {
      controls.putIfAbsent(entry.recordHash, () => entry);
    }
    final operations = <String, CloudDocumentOperation>{};
    for (final entry in [...existing.operations, ...incoming.operations]) {
      operations.putIfAbsent(entry.recordHash, () => entry);
    }
    final envelopes = <int, CloudDocumentEpochEnvelopeBundle>{};
    for (final entry in [...existing.envelopes, ...incoming.envelopes]) {
      final prior = envelopes[entry.epoch];
      if (prior != null && prior.bundleHash != entry.bundleHash) return null;
      envelopes[entry.epoch] = entry;
    }
    final payloads = <String, CloudDocumentEncryptedPayload>{};
    for (final entry in [...existing.payloads, ...incoming.payloads]) {
      final prior = payloads[entry.operationId];
      if (prior != null && prior.payloadHash != entry.payloadHash) return null;
      payloads[entry.operationId] = entry;
    }
    return CloudDocumentFrame(
      kind: CloudDocumentFrameKind.snapshot,
      root: existing.root,
      controls: controls.values.toList(),
      operations: operations.values.toList(),
      envelopes: envelopes.values.toList(),
      payloads: payloads.values.toList(),
    );
  }
}
