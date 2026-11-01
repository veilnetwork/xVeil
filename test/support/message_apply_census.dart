import 'dart:math' as math;

import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';

/// Passive fixture data. No message key, payload, path or exception is exported.
/// RPC await times can overlap and must not be summed as exclusive disk time.
class MessageApplyCensus {
  MessageApplyCensus({int Function()? nowUs}) : _nowOverride = nowUs {
    reset();
  }
  final clock = Stopwatch()..start();
  final int Function()? _nowOverride;
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

  void reset() {
    _epoch = nowUs;
    started = completed = failed = duplicates = 0;
    awaitUs = maxAwaitUs = completedFromEarlierStarts = 0;
    maxActive = active;
    keyLimitReached = false;
    _completedKeys.clear();
    _rpc.clear();
    _rpcNamespaces.clear();
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
    Map<String, ({int count, int wait, int maxWait, int before})> source,
  ) => {
    for (final label in source.keys.toList()..sort())
      label: {
        'count': source[label]!.count,
        'awaitUs': source[label]!.wait,
        'maxAwaitUs': source[label]!.maxWait,
        'startedBeforeWindow': source[label]!.before,
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
  };
}

class CountedMessageStorage extends HiddenVolumeStorage {
  CountedMessageStorage(super.opener, this.census) : super.async();
  final MessageApplyCensus census;

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
