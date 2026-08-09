import 'kv_log_store.dart';

/// Debug build? Asked WITHOUT `package:flutter/foundation`: the headless daemon
/// imports this storage layer and a test enforces that nothing it reaches
/// touches Flutter. `kDebugMode` cost that invariant for one boolean.
final bool _debugBuild = () {
  var debug = false;
  assert(() {
    debug = true;
    return true;
  }());
  return debug;
}();

/// Debug-only tally of what the app actually commits, by namespace.
///
/// The container may never reuse a freed slot — a second write at one offset
/// is not explicable by a decoy password, so the prohibition is a deniability
/// property, not an oversight. The consequence is that EVERY write is
/// permanent until a repack: a commit that changes nothing still costs its
/// chunks forever. So "what is being written, and by whom" is the question
/// behind both idle growth and per-message cost, and until now nothing could
/// answer it — the file grew and no counter said why.
///
/// Costs nothing outside a debug build: [record] compiles down to a
/// `_debugBuild` check at every call site.
class StorageWriteCensus {
  StorageWriteCensus._();

  static int commits = 0;
  static final Map<int, int> opsByNamespace = {};
  static final Map<int, int> bytesByNamespace = {};

  /// Ratchet flushes by the reason their caller gave.
  ///
  /// The namespace tally says the ratchet is 99% of idle writing; it cannot say
  /// WHICH path asks for it, and that decides whether the churn is even fixable
  /// — the receive path writes before its ack on purpose (the ack stops the
  /// sender retransmitting, so a delayed write can lose a key nobody will send
  /// again), while a serve or a periodic caller carries no such promise.
  static final Map<String, int> ratchetFlushesByReason = {};

  /// Conversations each reason's flushes actually WROTE.
  ///
  /// The flush count alone was misleading: cutting beacon sends 46 → 36 left
  /// the ratchet ops identical to the byte, which means most flushes write
  /// nothing (no conversation was marked) and the volume belongs to whichever
  /// few do. Counting calls and counting work apart is what tells those two
  /// apart.
  static final Map<String, int> ratchetWrittenByReason = {};

  /// Flushes that found nothing to write, by reason — pure overhead.
  static final Map<String, int> ratchetEmptyByReason = {};

  static void noteRatchetFlush(String why) {
    if (!_debugBuild) return;
    since ??= DateTime.now();
    ratchetFlushesByReason[why] = (ratchetFlushesByReason[why] ?? 0) + 1;
  }

  static void noteRatchetWritten(String why, int written) {
    if (!_debugBuild) return;
    if (written == 0) {
      ratchetEmptyByReason[why] = (ratchetEmptyByReason[why] ?? 0) + 1;
      return;
    }
    ratchetWrittenByReason[why] = (ratchetWrittenByReason[why] ?? 0) + written;
  }

  /// Wall-clock of the first record since the last [reset] — turns the totals
  /// into a rate, which is the only form in which idle churn means anything.
  static DateTime? since;

  static void record(List<KvLogOp> ops) {
    if (!_debugBuild) return;
    since ??= DateTime.now();
    commits++;
    for (final op in ops) {
      final (ns, bytes) = switch (op) {
        PutOp(:final namespace, :final key, :final value) => (
          namespace,
          key.length + value.length,
        ),
        DeleteOp(:final namespace, :final key) => (namespace, key.length),
        AppendLogOp(:final namespace, :final payload) => (
          namespace,
          payload.length,
        ),
        DeleteLogOp(:final namespace) => (namespace, 0),
      };
      opsByNamespace[ns] = (opsByNamespace[ns] ?? 0) + 1;
      bytesByNamespace[ns] = (bytesByNamespace[ns] ?? 0) + bytes;
    }
  }

  static void reset() {
    commits = 0;
    opsByNamespace.clear();
    bytesByNamespace.clear();
    ratchetFlushesByReason.clear();
    ratchetWrittenByReason.clear();
    ratchetEmptyByReason.clear();
    since = null;
  }

  /// Human-readable namespace label. The message log is sharded across a whole
  /// byte range, so the shards fold into one line — 86 rows of "shard 41: 1"
  /// would hide the thing being looked for.
  static String label(int ns) => switch (ns) {
    Ns.settings => 'settings',
    Ns.contacts => 'contacts',
    Ns.messageLog => 'messageLog(legacy)',
    Ns.media => 'media',
    Ns.fileChunks => 'fileChunks',
    Ns.outbox => 'outbox',
    Ns.callLog => 'callLog',
    Ns.outboxIndex => 'outboxIndex',
    Ns.ratchet => 'ratchet',
    _ =>
      ns >= Ns.messageLogShardFirst &&
          ns <= Ns.messageLogShardRetiredLast
      ? 'messageLog'
      : 'ns$ns',
  };

  static Map<String, dynamic> snapshot() {
    final ops = <String, int>{};
    final bytes = <String, int>{};
    for (final e in opsByNamespace.entries) {
      final k = label(e.key);
      ops[k] = (ops[k] ?? 0) + e.value;
    }
    for (final e in bytesByNamespace.entries) {
      final k = label(e.key);
      bytes[k] = (bytes[k] ?? 0) + e.value;
    }
    final start = since;
    final seconds = start == null
        ? 0
        : DateTime.now().difference(start).inSeconds;
    return {
      'commits': commits,
      'seconds': seconds,
      'opsByNamespace': ops,
      'payloadBytesByNamespace': bytes,
      'ratchetFlushesByReason': Map<String, int>.from(ratchetFlushesByReason),
      'ratchetWrittenByReason': Map<String, int>.from(ratchetWrittenByReason),
      'ratchetEmptyByReason': Map<String, int>.from(ratchetEmptyByReason),
      'totalOps': ops.values.fold(0, (a, b) => a + b),
      'totalPayloadBytes': bytes.values.fold(0, (a, b) => a + b),
    };
  }
}
