import 'dart:async';
import 'dart:collection';

/// Serial best-effort receipts for already committed effects. A dropped job is
/// repaired by the sender's durable retry, never by acknowledging early.
class PostReceiptQueue {
  PostReceiptQueue({
    this.maxJobs = 128,
    this.maxBytes = 128 * 1024,
    this.onError,
  });

  final int maxJobs, maxBytes;
  final void Function(Object, StackTrace)? onError;
  final _jobs = <String, _ReceiptJob>{};
  final _waiting = Queue<_ReceiptJob>();
  _ReceiptJob? _active;
  bool _closed = false;
  int _bytes = 0;
  int dropped = 0, coalesced = 0, failed = 0;
  int get pendingJobs => _jobs.length;
  int get pendingBytes => _bytes;

  Future<void> submit({
    required String key,
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
    final job = _ReceiptJob(key, bytes, send);
    _jobs[key] = job;
    _bytes += bytes;
    _waiting.add(job);
    _pump();
    return job.done.future;
  }

  void _pump() {
    if (_closed || _active != null || _waiting.isEmpty) return;
    final job = _active = _waiting.removeFirst();
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

  void _release(_ReceiptJob job) {
    _jobs.remove(job.key);
    _bytes -= job.bytes;
    job.done.complete();
  }

  void _finish(_ReceiptJob job) {
    _active = null;
    _release(job);
    _pump();
  }

  /// Pending ACKs can be lost safely. Join the one active send before the
  /// owner's final ratchet snapshot and before closing its native transport.
  Future<void> close() {
    _closed = true;
    while (_waiting.isNotEmpty) {
      _release(_waiting.removeFirst());
    }
    return _active?.done.future ?? Future<void>.value();
  }
}

class _ReceiptJob {
  _ReceiptJob(this.key, this.bytes, this.send);
  final String key;
  final int bytes;
  final Future<void> Function() send;
  final done = Completer<void>();
}
