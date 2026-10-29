import 'dart:async';
import 'dart:collection';

/// Bounded transport work for already committed effects. Receipts default to
/// serial execution. Source work may use independent recipient lanes without
/// overlapping two jobs in one lane. Dropped work retains its durable retry.
class PostReceiptQueue {
  PostReceiptQueue({
    this.maxJobs = 128,
    this.maxBytes = 128 * 1024,
    this.maxConcurrent = 1,
    this.onError,
  }) : assert(maxConcurrent > 0);

  final int maxJobs, maxBytes, maxConcurrent;
  final void Function(Object, StackTrace)? onError;
  final _jobs = <String, _ReceiptJob>{};
  final _waiting = Queue<_ReceiptJob>();
  final _active = <String, _ReceiptJob>{};
  bool _closed = false;
  int _bytes = 0;
  int dropped = 0, coalesced = 0, failed = 0;
  int get pendingJobs => _jobs.length;
  int get pendingBytes => _bytes;

  Future<void> submit({
    required String key,
    String lane = '',
    required int bytes,
    required Future<void> Function() send,
  }) {
    if (bytes < 0) throw ArgumentError.value(bytes, 'bytes');
    if (_closed) {
      dropped++;
      return Future<void>.value();
    }
    final previous = _jobs[key];
    if (previous != null) {
      coalesced++;
      return previous.done.future;
    }
    if (_jobs.length >= maxJobs || _bytes + bytes > maxBytes) {
      dropped++;
      return Future<void>.value();
    }
    final job = _ReceiptJob(key, lane, bytes, send);
    _jobs[key] = job;
    _bytes += bytes;
    _waiting.add(job);
    _pump();
    return job.done.future;
  }

  void _pump() {
    while (!_closed && _active.length < maxConcurrent && _waiting.isNotEmpty) {
      _ReceiptJob? ready;
      for (final candidate in _waiting) {
        if (!_active.containsKey(candidate.lane)) {
          ready = candidate;
          break;
        }
      }
      final job = ready;
      if (job == null) return;
      _waiting.remove(job);
      _active[job.lane] = job;
      Future<void>.sync(job.send).then<void>(
        (_) => _finish(job),
        onError: (Object error, StackTrace stack) {
          failed++;
          try {
            onError?.call(error, stack);
          } catch (_) {
            // A diagnostic callback cannot poison receipt processing.
          }
          _finish(job);
        },
      );
    }
  }

  void _release(_ReceiptJob job) {
    _jobs.remove(job.key);
    _bytes -= job.bytes;
    job.done.complete();
  }

  void _finish(_ReceiptJob job) {
    _active.remove(job.lane);
    _release(job);
    _pump();
  }

  /// Pending work retains durable recovery. Join every active send before the
  /// owner's final ratchet snapshot and before closing its native transport.
  Future<void> close() {
    _closed = true;
    while (_waiting.isNotEmpty) {
      _release(_waiting.removeFirst());
    }
    return Future.wait(
      _active.values.map((job) => job.done.future),
    ).then((_) {});
  }
}

class _ReceiptJob {
  _ReceiptJob(this.key, this.lane, this.bytes, this.send);
  final String key, lane;
  final int bytes;
  final Future<void> Function() send;
  final done = Completer<void>();
}
