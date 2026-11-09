import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/domain/chat.dart';

import 'timed_native_store.dart';
import 'storage_commit_labels.dart';

enum MessageStorageOperation {
  markStatus,
  adoptOrdering,
  preparedBatch,
  preparedOrderingBatch,
}

/// Passive fixture data. No message key, payload, path or exception is exported.
/// RPC await times can overlap and must not be summed as exclusive disk time.
class MessageApplyCensus {
  MessageApplyCensus({int Function()? nowUs, this.traceStages = false})
    : _nowOverride = nowUs {
    reset();
  }
  final clock = Stopwatch()..start();
  final int Function()? _nowOverride;
  final bool traceStages;
  int _stageSequence = 0;
  int get nowUs => _nowOverride?.call() ?? clock.elapsedMicroseconds;
  late int _epoch;
  int started = 0, completed = 0, failed = 0, duplicates = 0;
  int active = 0, maxActive = 0, awaitUs = 0, maxAwaitUs = 0;
  int completedFromEarlierStarts = 0;
  bool keyLimitReached = false;
  static const maxKeys = 10000;
  final _completedKeys = <(String, String)>{};
  final _rpc = <String, ({int count, int wait, int maxWait, int before})>{};
  // Inclusive per-namespace waits: one atomic commit can touch several kinds.
  // The fixed labels deliberately discard keys and unknown namespace numbers.
  final _rpcNamespaces =
      <String, ({int count, int wait, int maxWait, int before})>{};
  final _rpcStorageOperations =
      <String, ({int count, int wait, int maxWait, int before})>{};
  final _storageOperations =
      <String, ({int count, int wait, int maxWait, int before})>{};
  final _messageOperations =
      <String, ({int count, int wait, int maxWait, int before})>{};
  final _messageChanges = <String, int>{};
  final _messageFailures = <String, int>{};
  final _contexts =
      <String, ({int count, int wait, int maxWait, int before})>{};
  final _rpcContexts =
      <String, ({int count, int wait, int maxWait, int before})>{};
  final _commitClasses =
      <String, ({int count, int wait, int maxWait, int before})>{};
  final _commitComponents =
      <String, ({int count, int wait, int maxWait, int before})>{};
  final _commitFailures = <String, int>{};

  void reset() {
    _epoch = nowUs;
    started = completed = failed = duplicates = 0;
    awaitUs = maxAwaitUs = completedFromEarlierStarts = 0;
    maxActive = active;
    keyLimitReached = false;
    _completedKeys.clear();
    _rpc.clear();
    _rpcNamespaces.clear();
    _rpcStorageOperations.clear();
    _storageOperations.clear();
    _messageOperations.clear();
    _messageChanges.clear();
    _messageFailures.clear();
    _contexts.clear();
    _rpcContexts.clear();
    _commitClasses.clear();
    _commitComponents.clear();
    _commitFailures.clear();
  }

  Future<T> ownDevices<T>(Future<T> Function() body) =>
      _context('ownDevices', body);

  Future<T> historyApply<T>(Future<T> Function() body) =>
      _context('historyApply', body);

  Future<T> historyEncode<T>(Future<T> Function() body) =>
      _context('historyEncode', body);

  Future<T> historyPublish<T>(Future<T> Function() body) =>
      _context('historyPublish', body);

  Future<T> _context<T>(String label, Future<T> Function() body) async {
    final start = nowUs;
    final trace = traceStages ? developer.TimelineTask() : null;
    final sequence = trace == null ? 0 : ++_stageSequence;
    trace?.start(
      'stand.history.stage',
      arguments: {'stage': label, 'sequence': sequence},
    );
    var ok = false;
    try {
      final result = await runZoned(
        body,
        zoneValues: {storageTimingContextKey: label},
      );
      ok = true;
      return result;
    } finally {
      trace?.finish(
        arguments: {'stage': label, 'sequence': sequence, 'ok': ok},
      );
      _record(
        _contexts,
        label,
        math.max<int>(0, nowUs - math.max<int>(start, _epoch)),
        start < _epoch,
      );
    }
  }

  Future<bool> messageOperation(
    MessageStorageOperation operation,
    Future<bool> Function() body,
  ) async {
    final start = nowUs;
    bool? changed;
    try {
      final result = await body();
      changed = result;
      return result;
    } finally {
      final label = operation.name;
      _record(
        _messageOperations,
        label,
        math.max<int>(0, nowUs - math.max<int>(start, _epoch)),
        start < _epoch,
      );
      if (changed == null) {
        _messageFailures.update(label, (value) => value + 1, ifAbsent: () => 1);
      } else if (changed) {
        _messageChanges.update(label, (value) => value + 1, ifAbsent: () => 1);
      }
    }
  }

  Future<T> fileOperation<T>(
    String operation,
    String file,
    Future<T> Function() body,
  ) async {
    final kind = !file.startsWith('group:')
        ? 'other'
        : file.contains(':s:')
        ? 'segment'
        : 'header';
    final label = 'file.$operation.$kind';
    if (!storageTimingOperations.contains(label)) {
      throw StateError('unknown fixture storage operation');
    }
    final start = nowUs;
    try {
      return await runZoned(
        body,
        zoneValues: {storageTimingOperationKey: label},
      );
    } finally {
      _record(
        _storageOperations,
        label,
        math.max<int>(0, nowUs - math.max<int>(start, _epoch)),
        start < _epoch,
      );
    }
  }

  int beginAppend() {
    started++;
    active++;
    maxActive = math.max<int>(maxActive, active);
    return nowUs;
  }

  void endAppend(
    int start,
    String conversation,
    String id, {
    required bool success,
  }) {
    active--;
    final duration = math.max<int>(0, nowUs - math.max<int>(start, _epoch));
    awaitUs += duration;
    maxAwaitUs = math.max<int>(maxAwaitUs, duration);
    if (start < _epoch) completedFromEarlierStarts++;
    if (!success) {
      failed++;
      return;
    }
    completed++;
    final key = (conversation, id);
    if (_completedKeys.contains(key)) {
      duplicates++;
    } else if (_completedKeys.length < maxKeys) {
      _completedKeys.add(key);
    } else {
      keyLimitReached = true;
    }
  }

  void observeRpc(Map<String, Object?> event) {
    final operation = event['operation'];
    const allowed = {
      'kv.commit',
      'kv.get',
      'kv.getBatch',
      'kv.readLog',
      'kv.readLogBatch',
      'kv.readLogGroups',
      'kv.iterLogRange',
      'kv.count',
      'kv.keys',
      'kv.erase',
      'kv.scrub',
      'kv.slots',
      'anchor.sequence',
      'anchor.history',
      'anchor.roots',
    };
    if (operation is! String || !allowed.contains(operation)) return;
    final start = event['start_us'], duration = event['duration_us'];
    if (start is! int ||
        duration is! int ||
        duration < 0 ||
        start + duration < _epoch) {
      return;
    }
    final namespaces = event['namespaces'];
    final message =
        namespaces is List &&
        namespaces.any(
          (ns) =>
              ns is int &&
              (ns == Ns.messageLog ||
                  (ns >= Ns.messageLogShardFirst &&
                      ns <= Ns.messageLogShardLast)),
        );
    final label = operation == 'kv.commit'
        ? 'kv.commit.${message ? 'messageLog' : 'other'}'
        : operation;
    final wait = start + duration - math.max<int>(start, _epoch);
    _record(_rpc, label, wait, start < _epoch);
    if (operation == 'kv.commit') {
      final rawClass = event['commit_class'];
      final category =
          rawClass is String && storageCommitLabels.contains(rawClass)
          ? rawClass
          : 'unclassified';
      _record(_commitClasses, category, wait, start < _epoch);
      if (event['ok'] == false) {
        _commitFailures.update(category, (v) => v + 1, ifAbsent: () => 1);
      }
      final rawComponents = event['commit_components'];
      if (rawComponents is List) {
        for (final component
            in rawComponents
                .take(storageCommitLabels.length)
                .whereType<String>()
                .where(storageCommitLabels.contains)
                .toSet()) {
          _record(_commitComponents, component, wait, start < _epoch);
        }
      }
    }
    final context = event['storage_context'];
    if (context is String && storageTimingContexts.contains(context)) {
      _record(_rpcContexts, '$context/$operation', wait, start < _epoch);
    }
    final storageOperation = event['storage_operation'];
    if (storageOperation is String &&
        storageTimingOperations.contains(storageOperation)) {
      _record(
        _rpcStorageOperations,
        '$storageOperation/$operation',
        wait,
        start < _epoch,
      );
    }
    if (namespaces is List) {
      for (final category
          in namespaces.whereType<int>().map(_namespace).toSet()) {
        _record(_rpcNamespaces, '$operation.$category', wait, start < _epoch);
      }
    }
  }

  static String _namespace(int ns) => switch (ns) {
    Ns.settings => 'settings',
    Ns.contacts => 'contacts',
    Ns.media => 'media',
    Ns.fileChunks => 'fileChunks',
    Ns.outbox => 'outbox',
    Ns.outboxIndex => 'outboxIndex',
    Ns.callLog => 'callLog',
    Ns.ratchet => 'ratchet',
    Ns.messageLog => 'messageLog',
    >= Ns.messageLogShardFirst && <= Ns.messageLogShardLast => 'messageLog',
    _ => 'other',
  };

  static void _record(
    Map<String, ({int count, int wait, int maxWait, int before})> target,
    String label,
    int wait,
    bool before,
  ) {
    final old = target[label];
    target[label] = (
      count: (old?.count ?? 0) + 1,
      wait: (old?.wait ?? 0) + wait,
      maxWait: math.max<int>(old?.maxWait ?? 0, wait),
      before: (old?.before ?? 0) + (before ? 1 : 0),
    );
  }

  static Map<String, Object> _rpcSnapshot(
    Map<String, ({int count, int wait, int maxWait, int before})> source, {
    Map<String, int>? changes,
    Map<String, int>? failures,
  }) => {
    for (final label in source.keys.toList()..sort())
      label: {
        'count': source[label]!.count,
        'awaitUs': source[label]!.wait,
        'maxAwaitUs': source[label]!.maxWait,
        'startedBeforeWindow': source[label]!.before,
        if (changes != null) 'changed': changes[label] ?? 0,
        if (failures != null) 'failed': failures[label] ?? 0,
      },
  };

  Map<String, Object> snapshot() => {
    'schema': 'xveil-test-message-apply-census/1',
    'windowUs': nowUs - _epoch,
    'appendStarted': started,
    'appendCompleted': completed,
    'appendFailed': failed,
    'duplicateCompletedInWindow': duplicates,
    'appendActive': active,
    'appendMaxActive': maxActive,
    'appendAwaitUs': awaitUs,
    'appendMaxAwaitUs': maxAwaitUs,
    'appendCompletedFromEarlierStarts': completedFromEarlierStarts,
    'trackedKeys': _completedKeys.length,
    'keyLimitReached': keyLimitReached,
    'rpcCompleted': _rpcSnapshot(_rpc),
    'rpcNamespacesCompleted': _rpcSnapshot(_rpcNamespaces),
    'storageOperationsCompleted': _rpcSnapshot(_storageOperations),
    'rpcStorageOperationsCompleted': _rpcSnapshot(_rpcStorageOperations),
    'contextsCompleted': _rpcSnapshot(_contexts),
    'rpcContextsCompleted': _rpcSnapshot(_rpcContexts),
    'commitClassesCompleted': _rpcSnapshot(
      _commitClasses,
      failures: _commitFailures,
    ),
    'commitComponentsCompleted': _rpcSnapshot(_commitComponents),
    'messageOperationsCompleted': _rpcSnapshot(
      _messageOperations,
      changes: _messageChanges,
      failures: _messageFailures,
    ),
  };
}

class CountedMessageStorage extends HiddenVolumeStorage {
  CountedMessageStorage(super.opener, this.census) : super.async();
  final MessageApplyCensus census;

  @override
  Future<List<bool>?> adoptMessageOrderingBatch(
    List<MessageOrderingAdoption> requests, {
    required Future<void> Function() beforeCommit,
  }) async {
    List<bool>? result;
    await census.historyPublish(
      () => census.messageOperation(
        MessageStorageOperation.preparedOrderingBatch,
        () async {
          result = await super.adoptMessageOrderingBatch(
            requests,
            beforeCommit: beforeCommit,
          );
          return result?.contains(true) ?? false;
        },
      ),
    );
    return result;
  }

  // Count a prepared publication once, rather than inventing one physical
  // append wait per row. Its suspended historyApply contexts overlap.
  @override
  Future<List<PreparedMessageWrite>?> appendMissingMessageBatch(
    List<Message> messages, {
    required Future<void> Function() beforeCommit,
  }) async {
    List<PreparedMessageWrite>? result;
    await census.historyPublish(
      () => census.messageOperation(
        MessageStorageOperation.preparedBatch,
        () async {
          result = await super.appendMissingMessageBatch(
            messages,
            beforeCommit: beforeCommit,
          );
          return result?.contains(PreparedMessageWrite.appended) ?? false;
        },
      ),
    );
    return result;
  }

  @override
  Future<bool> markMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  ) => census.messageOperation(
    MessageStorageOperation.markStatus,
    () => super.markMessageStatus(conversationId, messageId, status),
  );

  @override
  Future<bool> adoptMessageOrdering(
    String conversationId,
    String messageId, {
    required String provisionalAuthor,
    required int provisionalSeq,
    required String author,
    required int seq,
  }) => census.messageOperation(
    MessageStorageOperation.adoptOrdering,
    () => super.adoptMessageOrdering(
      conversationId,
      messageId,
      provisionalAuthor: provisionalAuthor,
      provisionalSeq: provisionalSeq,
      author: author,
      seq: seq,
    ),
  );

  @override
  Future<void> storeFile(
    String id,
    Uint8List bytes, {
    String? name,
    List<String> retireHints = const [],
  }) => census.fileOperation(
    'store',
    id,
    () => super.storeFile(id, bytes, name: name, retireHints: retireHints),
  );

  @override
  Future<bool> tryStoreFilePair(
    StoredFileWrite first,
    StoredFileWrite second, {
    List<String> retireHints = const [],
  }) => census.fileOperation(
    'storePair',
    second.id,
    () => super.tryStoreFilePair(first, second, retireHints: retireHints),
  );

  @override
  Future<Uint8List?> loadFile(String id, {int? maxBytes}) => census
      .fileOperation('load', id, () => super.loadFile(id, maxBytes: maxBytes));

  @override
  Future<List<Uint8List>?> loadFiles(
    List<String> ids, {
    required int maxBytesPerFile,
  }) => census.fileOperation(
    'loadBatch',
    ids.isEmpty ? '' : ids.first,
    () => super.loadFiles(ids, maxBytesPerFile: maxBytesPerFile),
  );

  @override
  Future<bool> hasFile(String id) =>
      census.fileOperation('has', id, () => super.hasFile(id));

  @override
  Future<List<bool>> hasFiles(List<String> ids) => census.fileOperation(
    'hasBatch',
    ids.isEmpty ? '' : ids.first,
    () => super.hasFiles(ids),
  );

  @override
  Future<void> deleteStoredFile(String id) =>
      census.fileOperation('delete', id, () => super.deleteStoredFile(id));

  @override
  Future<Message> appendMessage(Message message) async {
    final start = census.beginAppend();
    var success = false;
    try {
      final stored = await super.appendMessage(message);
      success = true;
      return stored;
    } finally {
      census.endAppend(
        start,
        message.conversationId,
        message.id,
        success: success,
      );
    }
  }
}
