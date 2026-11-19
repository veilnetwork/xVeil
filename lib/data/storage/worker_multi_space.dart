import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hidden_volume/hidden_volume.dart' as hv;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'hv_kv_log_store.dart';
import 'hv_native.dart';
import 'kv_log_store.dart';
import 'multi_space_store.dart';
import 'worker_death.dart';
import 'async_kv_log_store.dart' show AsyncKvRequestFrontier;
import 'package:xveil/core/log.dart';

/// A worker that is up and has answered its bootstrap: the isolate, the port
/// that serves requests on it, and the watcher armed on its death.
typedef LiveMultiSpaceWorker = ({
  Isolate isolate,
  SendPort port,
  WorkerDeath watch,
});

/// Off-UI-isolate [AsyncMultiSpaceBacking] backed by a dedicated WORKER ISOLATE
/// that owns the real synchronous [HvMultiSpaceBacking] (one native
/// `HvMultiSpace` handle hosting every always-online identity's space). Each
/// `(id, op)` is served over a [SendPort]; the UI isolate only ever awaits, so
/// the fsync'ing hidden-volume FFI never blocks the UI thread.
///
/// The worker is spawned LAZILY on the first op (typically `openSpace`), so the
/// synchronous `SessionBuilder` can construct this without awaiting — the open
/// (and any error) surfaces on the first `await` instead. Drop with [close].
class WorkerMultiSpaceBacking
    implements AsyncMultiSpaceBacking, AsyncKvRequestFrontier {
  WorkerMultiSpaceBacking(
    this._path, {
    this.paddingPreset = hv.PaddingPreset.bucket256KiB,
  });

  final String _path;
  final hv.PaddingPreset paddingPreset;
  Isolate? _isolate;
  SendPort? _toWorker;

  /// Completes with an error when the worker isolate dies. Every RPC races it.
  WorkerDeath? _watch;
  Future<SendPort>? _ready;
  bool _closed = false; // ordinary I/O admission, not a release witness
  bool _closeSucceeded = false;
  bool _bootstrapFailedCleanly = false;
  hv.HvException? _closeDeathError;
  Future<void>? _closeAttempt;
  Future<void>? _closeWait;
  Future<void>? _lateCloseSource;
  int _requestFrontier = 0;

  @override
  int get requestFrontier => _requestFrontier;

  Future<SendPort> _ensure() => _ready ??= _spawn();

  /// How a worker is brought up — spawned, then waited on for its bootstrap
  /// reply. Overridden in tests ONLY, where the hidden-volume native library is
  /// not loadable at all (a spawned worker dies on `dlsym` before it can open
  /// anything), so the decision below — publish, or roll back because a [close]
  /// landed meanwhile — has no other way to be exercised.
  @visibleForTesting
  static Future<LiveMultiSpaceWorker> Function(
    String path,
    int paddingPresetTag,
  )?
  debugBringUpWorker;

  @visibleForTesting
  static Object debugSuccessReply([Object? value]) => _MOk(value);

  @visibleForTesting
  static Object debugFailureReply(String kind, String message) =>
      _MErr(kind, message);

  @visibleForTesting
  static Object debugCountRequest(int id, SendPort reply) =>
      _MCount(id, 1, reply);

  /// The disposable backing must be constructed inside the test worker.
  @visibleForTesting
  static SendPort debugServeBacking(MultiSpaceBacking backing) =>
      _serveMultiWorker(backing);

  /// Spawn a worker and take its result — or take the [close] that landed while
  /// it was coming up. Two awaits sit inside [_bringUp], and both of them are
  /// window enough (see the rollback below).
  Future<SendPort> _spawn() async {
    final hook = debugBringUpWorker;
    final LiveMultiSpaceWorker live;
    try {
      live = await (hook == null ? _bringUp() : hook(_path, paddingPreset.tag));
    } on StorageWorkerSpawnFailure {
      _bootstrapFailedCleanly = true;
      rethrow;
    }
    _isolate = live.isolate;
    _watch = live.watch;
    _toWorker = live.port;
    // A close accepted during bootstrap owns the cleanup attempt and is
    // waiting for this future to settle. Do not recursively await it here:
    // that would deadlock bootstrap against its own rollback. Publish the
    // capability to that owner, and refuse the triggering ordinary request.
    if (_closed) throw StateError('WorkerMultiSpaceBacking is closed');
    return live.port;
  }

  Future<LiveMultiSpaceWorker> _bringUp() async {
    final (
      isolate: isolate,
      watch: death,
      reply: first,
    ) = await WorkerDeath.spawn<(Isolate, _MOpenConfig)>(
      _multiWorkerEntry,
      (reply) => (
        Isolate.current,
        _MOpenConfig(
          path: _path,
          paddingPresetTag: paddingPreset.tag,
          reply: reply,
        ),
      ),
      worker: 'multi-space worker',
    );
    void abandon() {
      death.dispose();
      isolate.kill(priority: Isolate.immediate);
    }

    switch (first) {
      case _MErr(:final kind, :final message):
        // The production bootstrap reports this before handing out a backing:
        // opening failed, so let the worker unregister its listener and exit.
        _bootstrapFailedCleanly = true;
        death.dispose();
        throw hv.HvException(kind, message);
      case _MOk(:final value):
        return (isolate: isolate, port: value as SendPort, watch: death);
      default:
        abandon();
        throw StateError(
          'multi-space worker sent an unexpected bootstrap reply',
        );
    }
  }

  Future<T> _call<T>(_MReq Function(SendPort reply) build) async {
    if (_closed) throw StateError('WorkerMultiSpaceBacking is closed');
    // Admission is synchronous even while worker startup is still awaited.
    _requestFrontier++;
    final port = await _ensure();
    // Asked AGAIN, after the await. `_ensure` suspends, and `close` can run to
    // completion in that gap: it sets `_closed`, sends `_MClose`, and disposes
    // the death watcher. The resumed call then sent its request to a worker
    // that had shut its receive path, and waited on a race nothing could win —
    // no reply, and no death to report either, because the watcher was gone.
    // The future never completed, and it was holding the caller's payload and
    // the screen that asked (report15 X15-M5).
    //
    // Nothing runs between this check and the `send` below: within one isolate
    // there is no gap for `close` to slip into.
    //
    // Note what this alone does NOT buy: `WorkerDeath.dispose` now releases
    // such a call anyway, so no test can tell the two apart. This is here to
    // avoid sending to a worker already on its way out and waiting for an
    // answer that was never coming — a clearer error, sooner.
    if (_closed) throw StateError('WorkerMultiSpaceBacking is closed');
    final reply = ReceivePort();
    port.send(build(reply.sendPort));
    // Raced against the worker's death, not awaited alone. `errorsAreFatal`
    // makes a crashed worker die QUIETLY, so `reply.first` on its own stayed
    // pending forever — the all-online unlock showed a spinner no timeout
    // would end, and every later call joined it (audit XV-07).
    final Object? r;
    try {
      // The other half of the same window — a close landing while this is
      // already in flight — is handled by `WorkerDeath.dispose`, which
      // releases whatever is still registered. NOT with another
      // `Future.any` here: that attaches a listener per call to a shared
      // future and cancels none of them, and each listener holds the completer
      // carrying the reply, which here is a KV value. That is report14
      // HV14-H1, and the guard that watches for it caught this on the way in.
      r = await _watch!.race(reply.first);
    } finally {
      reply.close();
    }
    if (r is _MErr) throw hv.HvException(r.kind, r.message);
    return (r as _MOk).value as T;
  }

  @override
  Future<int> openSpace(Uint8List keys) =>
      _call<int>((reply) => _MOpenSpace(keys, reply));
  @override
  Future<int> commit(int id, List<KvLogOp> ops) =>
      _call<int>((reply) => _MCommit(id, ops, reply));
  @override
  Future<Uint8List?> get(int id, int namespace, Uint8List key) =>
      _call<Uint8List?>((reply) => _MGet(id, namespace, key, reply));
  @override
  Future<Uint8List?> readLog(int id, int namespace, int logId) =>
      _call<Uint8List?>((reply) => _MReadLog(id, namespace, logId, reply));
  @override
  Future<List<KvLogEntry>> iterLogRange(
    int id, {
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) => _call<List<KvLogEntry>>(
    (reply) => _MIter(id, namespace, start, end, limit, reply),
  );
  @override
  Future<int> count(int id, int namespace) =>
      _call<int>((reply) => _MCount(id, namespace, reply));
  @override
  Future<List<Uint8List>> kvKeys(int id, int namespace) =>
      _call<List<Uint8List>>((reply) => _MKvKeys(id, namespace, reply));
  @override
  Future<Uint8List> exportKeys(int id) =>
      _call<Uint8List>((reply) => _MExportKeys(id, reply));
  @override
  Future<void> scrub(int id) => _call<void>((reply) => _MScrub(id, reply));
  @override
  Future<SlotUtilization?> slotUtilization(int id) =>
      _call<SlotUtilization?>((reply) => _MSlotUtilization(id, reply));
  @override
  Future<String?> hardeningWarning(int id) =>
      _call<String?>((reply) => _MHardeningWarning(id, reply));
  @override
  Future<void> acknowledgeHardeningWarning(int id) =>
      _call<void>((reply) => _MAckHardening(id, reply));
  @override
  Future<void> vacuumOrphans(int id) =>
      _call<void>((reply) => _MVacuumOrphans(id, reply));

  @override
  Future<void> close() {
    if (_closeSucceeded) return Future.value();
    final death = _closeDeathError;
    if (death != null) return Future.error(death);
    _closed = true;
    final waiting = _closeWait;
    if (waiting != null) return waiting;
    final attempt = _closeAttempt ??= _sendClose();
    late final Future<void> next;
    next = _waitForClose(attempt).whenComplete(() {
      if (identical(_closeWait, next)) _closeWait = null;
    });
    _closeWait = next;
    return next;
  }

  @visibleForTesting
  static Duration closeTimeout = const Duration(seconds: 5);

  Future<void>? _lateClose;
  @visibleForTesting
  Future<void>? get debugLateClose => _lateClose;

  Future<void> _sendClose() async {
    ReceivePort? reply;
    try {
      // Startup may still acquire a native handle. Its future must settle
      // before "never opened" can be distinguished from "opened late".
      if (_toWorker == null && _ready != null) {
        try {
          await _ready;
        } catch (error) {
          if (_toWorker == null) {
            if (_bootstrapFailedCleanly) {
              _closeSucceeded = true;
              return;
            }
            final failure = hv.HvException(
              'Internal',
              'multi-space bootstrap ended without a release witness: $error',
            );
            _closeDeathError = failure;
            throw failure;
          }
          // _spawn refuses the ordinary request when closed, but hands its
          // actual worker capability to this sole cleanup owner first.
        }
      }
      final port = _toWorker;
      if (port == null) {
        _closeSucceeded = true; // no spawn was ever admitted
        return;
      }
      _requestFrontier++;
      reply = ReceivePort();
      final done = reply.first;
      port.send(_MClose(reply.sendPort));
      final Object? result;
      try {
        result = await _watch!.race(done);
      } catch (error) {
        final failure = hv.HvException(
          'Internal',
          'multi-space worker died during close: $error',
        );
        _closeDeathError = failure;
        _watch?.dispose();
        _isolate?.kill(priority: Isolate.immediate);
        throw failure;
      }
      if (result is _MErr) {
        // The backing may still own its lock. Keep it supervised and retryable
        // instead of killing it or treating an error as a release witness.
        throw hv.HvException(result.kind, result.message);
      }
      if (result is! _MOk || result.value != null) {
        throw hv.HvException(
          'Internal',
          'invalid multi-space close acknowledgement',
        );
      }
      _closeSucceeded = true;
      _watch?.dispose();
      _isolate?.kill(priority: Isolate.immediate);
    } finally {
      reply?.close();
      _closeAttempt = null;
    }
  }

  Future<void> _waitForClose(Future<void> attempt) async {
    final completed = await attempt
        .then((_) => true)
        .timeout(closeTimeout, onTimeout: () => false);
    if (completed) return;
    // Bound only this wait. Keep the ONE attempt across timeouts, including
    // bootstrap; retries join it rather than queueing duplicate native closes.
    if (!identical(_lateCloseSource, attempt)) {
      _lateCloseSource = attempt;
      _lateClose = attempt.then(
        (_) => devLog(() => 'xVeil[storage]: late multi-space close confirmed'),
        onError: (Object error, StackTrace stack) {
          devLog(() => 'xVeil[storage]: late multi-space close failed: $error');
        },
      );
      unawaited(_lateClose!);
    }
    throw hv.HvException(
      'Busy',
      'multi-space worker did not close within ${closeTimeout.inMilliseconds}ms; '
          'native release is not confirmed',
    );
  }
}

// ── Worker isolate protocol ─────────────────────────────────────────────────
// The worker OWNS the sync HvMultiSpaceBacking. It opens the container as its
// first act (off the UI isolate) then serves per-(id, op) requests. All message
// payloads are plain sendable data (ints, byte lists, the sealed value types).

class _MOpenConfig {
  const _MOpenConfig({
    required this.path,
    required this.paddingPresetTag,
    required this.reply,
  });
  final String path;
  final int paddingPresetTag;
  final SendPort reply;
}

hv.PaddingPreset _paddingPresetFromTag(int tag) {
  for (final preset in hv.PaddingPreset.values) {
    if (preset.tag == tag) return preset;
  }
  return hv.PaddingPreset.bucket256KiB;
}

sealed class _MReq {
  const _MReq(this.reply);
  final SendPort reply;
}

class _MOpenSpace extends _MReq {
  const _MOpenSpace(this.keys, super.reply);
  final Uint8List keys;
}

class _MCommit extends _MReq {
  const _MCommit(this.id, this.ops, super.reply);
  final int id;
  final List<KvLogOp> ops;
}

class _MGet extends _MReq {
  const _MGet(this.id, this.namespace, this.key, super.reply);
  final int id;
  final int namespace;
  final Uint8List key;
}

class _MReadLog extends _MReq {
  const _MReadLog(this.id, this.namespace, this.logId, super.reply);
  final int id;
  final int namespace;
  final int logId;
}

class _MIter extends _MReq {
  const _MIter(
    this.id,
    this.namespace,
    this.start,
    this.end,
    this.limit,
    SendPort reply,
  ) : super(reply);
  final int id;
  final int namespace;
  final int? start;
  final int? end;
  final int limit;
}

class _MCount extends _MReq {
  const _MCount(this.id, this.namespace, super.reply);
  final int id;
  final int namespace;
}

class _MKvKeys extends _MReq {
  const _MKvKeys(this.id, this.namespace, super.reply);
  final int id;
  final int namespace;
}

class _MExportKeys extends _MReq {
  const _MExportKeys(this.id, super.reply);
  final int id;
}

class _MVacuumOrphans extends _MReq {
  const _MVacuumOrphans(this.id, super.reply);
  final int id;
}

class _MScrub extends _MReq {
  const _MScrub(this.id, super.reply);
  final int id;
}

class _MSlotUtilization extends _MReq {
  const _MSlotUtilization(this.id, super.reply);
  final int id;
}

class _MHardeningWarning extends _MReq {
  const _MHardeningWarning(this.id, super.reply);
  final int id;
}

class _MAckHardening extends _MReq {
  const _MAckHardening(this.id, super.reply);
  final int id;
}

class _MClose extends _MReq {
  const _MClose(super.reply);
}

sealed class _MReply {
  const _MReply();
}

class _MOk extends _MReply {
  const _MOk(this.value);
  final Object? value;
}

class _MErr extends _MReply {
  const _MErr(this.kind, this.message);
  final String kind;
  final String message;
}

Future<void> _multiWorkerEntry((Isolate, _MOpenConfig) launch) async {
  final (owner, config) = launch;
  final inbox = StorageWorkerInbox(owner);
  try {
    if (!await inbox.confirmOwner()) {
      config.reply.send(const _MErr('Internal', 'storage owner unavailable'));
      return;
    }
    _openAndServeMultiWorker(config, inbox);
  } finally {
    inbox.closeIfUnserved();
  }
}

void _openAndServeMultiWorker(_MOpenConfig cfg, StorageWorkerInbox inbox) {
  // hidden-volume symbols are process-global once the main isolate preloaded
  // them; call the idempotent loader so the worker is self-sufficient (Android
  // opens by soname per isolate).
  ensureHiddenVolumeLoaded();

  final MultiSpaceBacking backing;
  try {
    backing = HvMultiSpaceBacking.open(
      cfg.path,
      paddingPreset: _paddingPresetFromTag(cfg.paddingPresetTag),
    );
  } on hv.HvException catch (e) {
    cfg.reply.send(_MErr(e.kind, e.message));
    return;
  } catch (e) {
    cfg.reply.send(_MErr('Internal', e.toString()));
    return;
  }

  cfg.reply.send(
    _MOk(
      _serveMultiWorker(backing, inbox: inbox, ownerExit: _MClose(cfg.reply)),
    ),
  );
}

SendPort _serveMultiWorker(
  MultiSpaceBacking backing, {
  StorageWorkerInbox? inbox,
  _MClose? ownerExit,
}) {
  final requests = inbox ?? StorageWorkerInbox();
  var closing = false;

  requests.listen(ownerExit, (dynamic msg) {
    if (msg is! _MReq) return;
    if (closing && msg is! _MClose) {
      msg.reply.send(const _MErr('Internal', 'storage worker is closing'));
      return;
    }
    void run<T>(T Function() body) {
      try {
        msg.reply.send(_MOk(body()));
      } on hv.HvException catch (e) {
        msg.reply.send(_MErr(e.kind, e.message));
      } catch (e) {
        msg.reply.send(_MErr('Internal', e.toString()));
      }
    }

    switch (msg) {
      case _MOpenSpace(:final keys):
        run(() => backing.openSpace(keys));
      case _MCommit(:final id, :final ops):
        run(() => backing.commit(id, ops));
      case _MGet(:final id, :final namespace, :final key):
        run(() => backing.get(id, namespace, key));
      case _MReadLog(:final id, :final namespace, :final logId):
        run(() => backing.readLog(id, namespace, logId));
      case _MIter(
        :final id,
        :final namespace,
        :final start,
        :final end,
        :final limit,
      ):
        run(
          () => backing.iterLogRange(
            id,
            namespace: namespace,
            start: start,
            end: end,
            limit: limit,
          ),
        );
      case _MCount(:final id, :final namespace):
        run(() => backing.count(id, namespace));
      case _MKvKeys(:final id, :final namespace):
        run(() => backing.kvKeys(id, namespace));
      case _MExportKeys(:final id):
        run(() => backing.exportKeys(id));
      case _MVacuumOrphans(:final id):
        run<Object?>(() {
          backing.vacuumOrphans(id);
          return null;
        });
      case _MScrub(:final id):
        run<Object?>(() {
          backing.scrub(id);
          return null;
        });
      case _MSlotUtilization(:final id):
        run(() => backing.slotUtilization(id));
      case _MHardeningWarning(:final id):
        run(() => backing.hardeningWarning(id));
      case _MAckHardening(:final id):
        run(() {
          backing.acknowledgeHardeningWarning(id);
          return null;
        });
      case _MClose():
        closing = true;
        try {
          backing.close();
          msg.reply.send(const _MOk(null));
          requests.close();
          Isolate.current.kill(priority: Isolate.immediate);
        } on hv.HvException catch (e) {
          msg.reply.send(_MErr(e.kind, e.message));
        } catch (e) {
          // Close-only serving remains available while native ownership is
          // unconfirmed. The host must not lose this resource on an error.
          msg.reply.send(_MErr('Internal', e.toString()));
        }
    }
  });
  return requests.sendPort;
}
