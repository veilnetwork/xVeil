import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import '../domain/cloud_document.dart';
import '../domain/cloud_document_envelope.dart';
import '../domain/cloud_document_replication.dart';
import 'cloud_document_crypto.dart';
import 'cloud_document_envelope_service.dart';
import 'cloud_document_store.dart';

typedef CloudDocumentFrameSender =
    Future<void> Function(NodeId peer, String documentId, String frameJson);

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
    bool Function(CloudDocumentRoot root)? verifyRoot,
    bool Function(CloudDocumentControlEntry entry)? verifyControl,
    bool Function(CloudDocumentOperation operation)? verifyOperation,
    DateTime Function()? now,
  }) => CloudDocumentReplicationService._(
    localNodeId: localNodeId,
    ourCertVersion: ourCertVersion,
    store: store,
    envelopes: envelopes,
    sendFrame: sendFrame,
    verifyRoot: verifyRoot ?? verifyCloudDocumentRoot,
    verifyControl: verifyControl ?? verifyCloudDocumentControl,
    verifyOperation: verifyOperation ?? verifyCloudDocumentOperation,
    now: now ?? DateTime.now,
  );

  CloudDocumentReplicationService._({
    required this.localNodeId,
    required this.ourCertVersion,
    required this._store,
    required this._envelopes,
    required this._sendFrame,
    required this._verifyRoot,
    required this._verifyControl,
    required this._verifyOperation,
    required this._now,
  });

  final NodeId localNodeId;
  final int ourCertVersion;
  final CloudDocumentStore _store;
  final CloudDocumentEnvelopeService _envelopes;
  final CloudDocumentFrameSender _sendFrame;
  final bool Function(CloudDocumentRoot root) _verifyRoot;
  final bool Function(CloudDocumentControlEntry entry) _verifyControl;
  final bool Function(CloudDocumentOperation operation) _verifyOperation;
  final DateTime Function() _now;

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
  Future<bool> ingest(NodeId sender, String frameJson) async {
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
        await _store.save(
          CloudDocumentStoredBundle(
            root: merged.root,
            controls: fold.acceptedControls,
            operations: fold.acceptedOperations,
            envelopes: merged.envelopes,
            localEpochKeys: keys,
          ),
        );
      } finally {
        for (final key in keys.values) {
          key.fillRange(0, key.length, 0);
        }
      }
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
    return true;
  }

  Future<bool> adopt(String documentId) async {
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
      await _store.save(
        CloudDocumentStoredBundle(
          root: frame.root,
          controls: fold.acceptedControls,
          operations: fold.acceptedOperations,
          envelopes: frame.envelopes,
          localEpochKeys: keys,
        ),
      );
      await _store.removePendingInvite(documentId);
      return true;
    } catch (_) {
      return false;
    } finally {
      for (final key in keys.values) {
        key.fillRange(0, key.length, 0);
      }
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
    return CloudDocumentFrame(
      kind: CloudDocumentFrameKind.snapshot,
      root: existing.root,
      controls: controls.values.toList(),
      operations: operations.values.toList(),
      envelopes: envelopes.values.toList(),
    );
  }
}
