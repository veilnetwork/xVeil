import 'dart:typed_data';

import 'hv_kv_log_store.dart';
import 'kv_log_store.dart';
import 'managed_anchor_state.dart';
import 'managed_keybox.dart';
import 'managed_metadata_blob.dart';
import 'managed_store_tag.dart';
import 'rollback_anchor.dart';

/// Consumes the data adapter after both payload handles close. The admitted
/// file owner now owns this still-open keybox and the exact source witness.
/// This token stays on the owning worker; it is never an IPC payload.
final class ManagedRepackTransfer {
  ManagedRepackTransfer._(this.keybox, this.state, this.source);
  final ManagedKeybox keybox;
  final ManagedAnchorState state;
  final ManagedAnchorSnapshot source;
}

/// Native encrypted application-data port for one enumerable identity.
///
/// All three handles transfer ownership on entry, including failed opens.
/// The future file owner must admit their paths, open content/maintenance with
/// the keybox's internal passwords, and serialize this port off the UI isolate.
/// This class does not create paths, discover spaces or select a storage mode.
final class ManagedEncryptedKvLogStore
    implements
        KvLogStore,
        SyncCommitAnchorSource,
        SyncLogGroupReader,
        SyncInitializationNamespaceSource {
  ManagedEncryptedKvLogStore._(this._keybox, this._content, this._maintenance);

  factory ManagedEncryptedKvLogStore.openOwned({
    required ManagedKeybox keybox,
    required HvKvLogStore content,
    required HvKvLogStore maintenance,
  }) => _adopt(keybox, content, maintenance, initialize: false);

  /// For unpublished, newly admitted files only. Failed creation must not be
  /// retried as initialization over written files. No open-error fallback.
  factory ManagedEncryptedKvLogStore.initializeOwned({
    required ManagedKeybox keybox,
    required HvKvLogStore content,
    required HvKvLogStore maintenance,
  }) => _adopt(keybox, content, maintenance, initialize: true);

  static ManagedEncryptedKvLogStore _adopt(
    ManagedKeybox keybox,
    HvKvLogStore content,
    HvKvLogStore maintenance, {
    required bool initialize,
  }) {
    final store = ManagedEncryptedKvLogStore._(keybox, content, maintenance);
    try {
      // Validate that the transferred keybox is still open before any write.
      final probe = keybox.exportKeys();
      probe.fillRange(0, probe.length, 0);
      if (initialize) store._initializeNew();
      store._load();
      return store;
    } catch (_) {
      store.close();
      rethrow;
    }
  }

  final ManagedKeybox _keybox;
  final HvKvLogStore _content;
  final HvKvLogStore _maintenance;
  ManagedAnchorState? _state;
  bool _closing = false;
  bool _closed = false;
  bool _contentClosed = false;
  bool _maintenanceClosed = false;
  bool _keyboxClosed = false;

  void _initializeNew() {
    // Native fresh spaces have only bootstrap sequence 1. Check both BEFORE
    // publishing anything; this is not proof of filesystem creation ownership.
    if (_content.commitSeq() != 1 || _maintenance.commitSeq() != 1) {
      throw StateError('Managed content is not an unpublished new space');
    }
    final identity = _keybox.identity;
    final marker = ManagedGeneration.fresh(innerFloor: 2, offset: 0).marker;
    final floor = _content.commit([
      ManagedStoreTag(
        identity: identity,
        role: ManagedStoreRole.content,
        generation: marker,
      ).putOp(),
    ]);
    _maintenance.commit([
      ManagedStoreTag(
        identity: identity,
        role: ManagedStoreRole.maintenance,
      ).putOp(),
    ]);
    final state = ManagedAnchorState.initial(
      identity: identity,
      generation: ManagedGeneration(
        marker: marker,
        innerFloor: floor,
        offset: 0,
      ),
    );
    ManagedMetadataBlob(_maintenance).write(state.encode(), initialize: true);
  }

  void _load() {
    ManagedStoreTag.read(
      _maintenance,
      identity: _keybox.identity,
      role: ManagedStoreRole.maintenance,
    );
    final blob = ManagedMetadataBlob(_maintenance);
    _state = ManagedAnchorState.decode(blob.read());
    final observed = _anchor();
    if (_state!.prepared != null) {
      // Persist recovery before exposing an application-data handle. If the
      // response is lost, a later open reads whichever complete state won.
      final settled = _state!.settle(observed);
      blob.write(settled.encode());
      _state = settled;
      _anchor();
    }
  }

  void _requireOpen() {
    if (_closing || _closed || _state == null) {
      throw StateError('Managed encrypted store is closed');
    }
  }

  @override
  int initializationNamespaceLimit() {
    _requireOpen();
    // The ordinary application port intentionally cannot read these. Verify
    // them on the owner, without exposing their bytes or weakening that port.
    _anchor();
    if (_content.count(ManagedStoreTag.namespace) != 1 ||
        _content.kvKeys(ManagedStoreTag.namespace).length != 1 ||
        _content.count(255) != 0) {
      throw StateError('Unexpected initialization metadata');
    }
    return ManagedStoreTag.namespace;
  }

  static void _namespace(int value) {
    if (value < 1 || value >= ManagedStoreTag.namespace) {
      throw ArgumentError('Storage namespace is reserved or invalid');
    }
  }

  ManagedAnchorSnapshot _anchor() {
    final tag = ManagedStoreTag.read(
      _content,
      identity: _keybox.identity,
      role: ManagedStoreRole.content,
    );
    return _state!.resolve(
      contentIdentity: tag.identity,
      contentMarker: tag.generation!,
      innerSequence: _content.commitSeq(),
      innerRoots: _content.commitRoots(),
    );
  }

  int _logical(int inner) {
    final state = _state!;
    final logical = state.active.project(inner);
    if (logical < state.checkpoint) {
      throw StateError('Managed content is behind its checkpoint');
    }
    return logical;
  }

  void _canWrite() {
    _requireOpen();
    final inner = _content.commitSeq();
    if (inner == 0x7fffffffffffffff || _logical(inner) == 0x7fffffffffffffff) {
      throw StateError('Managed content commit sequence exhausted');
    }
  }

  @override
  int commit(List<KvLogOp> ops) {
    _canWrite();
    // Validate the entire batch before native mutation, never a prefix of it.
    for (final op in ops) {
      switch (op) {
        case PutOp(:final namespace) ||
            DeleteOp(:final namespace) ||
            AppendLogOp(:final namespace) ||
            DeleteLogOp(:final namespace):
          _namespace(namespace);
      }
    }
    return _logical(_content.commit(ops));
  }

  @override
  Uint8List? get(int namespace, Uint8List key) {
    _requireOpen();
    _namespace(namespace);
    return _content.get(namespace, key);
  }

  @override
  Uint8List? readLog(int namespace, int logId) {
    _requireOpen();
    _namespace(namespace);
    return _content.readLog(namespace, logId);
  }

  @override
  List<Uint8List>? readLogGroups(int namespace, List<LogReadGroup> groups) {
    _requireOpen();
    _namespace(namespace);
    return _content.readLogGroups(namespace, groups);
  }

  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) {
    _requireOpen();
    _namespace(namespace);
    return _content.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    );
  }

  @override
  int count(int namespace) {
    _requireOpen();
    _namespace(namespace);
    return _content.count(namespace);
  }

  @override
  List<Uint8List> kvKeys(int namespace) {
    _requireOpen();
    _namespace(namespace);
    return _content.kvKeys(namespace);
  }

  @override
  int eraseNamespace(int namespace) {
    _canWrite();
    _namespace(namespace);
    return _content.eraseNamespace(namespace);
  }

  @override
  void scrub() {
    _canWrite();
    _content.scrub();
  }

  @override
  Uint8List exportKeys() {
    _requireOpen();
    return _keybox.exportKeys();
  }

  @override
  int commitSeq() {
    _requireOpen();
    return _logical(_content.commitSeq());
  }

  @override
  List<int> commitHistory() {
    _requireOpen();
    return _anchor().history;
  }

  @override
  Map<int, String> commitRoots() {
    _requireOpen();
    return _anchor().roots;
  }

  @override
  SlotUtilization? slotUtilization() {
    _requireOpen();
    final keybox = _keybox.slotUtilization();
    final content = _content.slotUtilization();
    final maintenance = _maintenance.slotUtilization();
    if (keybox == null || content == null || maintenance == null) return null;
    return SlotUtilization(
      ownedChunks:
          keybox.ownedChunks + content.ownedChunks + maintenance.ownedChunks,
      totalSlots:
          keybox.totalSlots + content.totalSlots + maintenance.totalSlots,
    );
  }

  @override
  String? hardeningWarning() {
    _requireOpen();
    final warnings = [
      if (_keybox.hardeningWarning() case final String value) 'keybox: $value',
      if (_content.hardeningWarning() case final String value)
        'content: $value',
      if (_maintenance.hardeningWarning() case final String value)
        'maintenance: $value',
    ];
    return warnings.isEmpty ? null : warnings.join('\n');
  }

  @override
  void acknowledgeHardeningWarning() {
    _requireOpen();
    _content.acknowledgeHardeningWarning();
    _maintenance.acknowledgeHardeningWarning();
    _keybox.acknowledgeHardeningWarning();
  }

  /// The caller retains its identity lease throughout maintenance and must
  /// reattach payloads or close [ManagedRepackTransfer.keybox]. A failed close
  /// leaves this adapter closing and retryable via [close], without transfer.
  ManagedRepackTransfer releasePayloadsForRepack() {
    _requireOpen();
    final state = _state!;
    final source = _anchor();
    _closing = true;
    _content.close();
    _contentClosed = true;
    _maintenance.close();
    _maintenanceClosed = true;
    _keyboxClosed = true; // ownership transfers; native keybox remains open
    _closed = true;
    _state = null;
    return ManagedRepackTransfer._(_keybox, state, source);
  }

  @override
  void close() {
    if (_closed) return;
    _closing = true;
    _state = null;
    Object? failure;
    StackTrace? trace;
    void attempt(void Function() work) {
      try {
        work();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }

    if (!_contentClosed) {
      attempt(() {
        _content.close();
        _contentClosed = true;
      });
    }
    if (!_maintenanceClosed) {
      attempt(() {
        _maintenance.close();
        _maintenanceClosed = true;
      });
    }
    if (!_keyboxClosed) {
      attempt(() {
        _keybox.close();
        _keyboxClosed = true;
      });
    }
    _closed = _contentClosed && _maintenanceClosed && _keyboxClosed;
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }
}
