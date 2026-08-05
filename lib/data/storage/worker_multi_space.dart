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
class WorkerMultiSpaceBacking implements AsyncMultiSpaceBacking {
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
  bool _closed = false;

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

  /// Spawn a worker and take its result — or take the [close] that landed while
  /// it was coming up. Two awaits sit inside [_bringUp], and both of them are
  /// window enough (see the rollback below).
  Future<SendPort> _spawn() async {
    final hook = debugBringUpWorker;
    final live = await (hook == null
        ? _bringUp()
        : hook(_path, paddingPreset.tag));
    _isolate = live.isolate;
    _watch = live.watch;
    _toWorker = live.port;
    // [close] can have landed during either await in [_bringUp], and until
    // these assignments there was nothing here for it to find: it saw a null
    // port, killed an isolate that had not opened anything yet, and returned.
    // The worker then finished opening the CONTAINER and stayed alive holding
    // its exclusive flock, with no reference to it left anywhere — and every
    // later unlock failed `Busy` until the process died. Same shape as the
    // lock-during-boot window in AppController (audit H-06): a resource
    // published after the teardown that was supposed to reclaim it.
    //
    // Shut it down through the PROTOCOL rather than killing it: by now the
    // container is open, and an isolate kill cannot unwind an FFI frame, so a
    // kill is exactly what strands the native handle (the same reason
    // WorkerKvLogStore.close refuses to kill on timeout).
    if (_closed) {
      await _shutdown(live.port);
      throw StateError('WorkerMultiSpaceBacking is closed');
    }
    return live.port;
  }

  Future<LiveMultiSpaceWorker> _bringUp() async {
    final boot = ReceivePort();
    // Watch the isolate BEFORE it can die (audit XV-07). This is the
    // all-online path: N identities share one worker, so a worker that dies
    // takes every one of their stores with it. Wired at spawn time rather than
    // after, because a worker that fails while opening the container fails
    // FAST — most often on the very first FFI call — and a watcher attached
    // afterwards would miss exactly that case.
    final death = WorkerDeath();
    final isolate = await Isolate.spawn<_MOpenConfig>(
      _multiWorkerEntry,
      _MOpenConfig(
        path: _path,
        paddingPresetTag: paddingPreset.tag,
        reply: boot.sendPort,
      ),
      errorsAreFatal: true,
      onExit: death.exitPort.sendPort,
      onError: death.errorPort.sendPort,
    );
    Object? first;
    try {
      first = await Future.any<Object?>([boot.first, death.future]);
    } catch (e) {
      boot.close();
      death.dispose();
      isolate.kill(priority: Isolate.immediate);
      throw hv.HvException(
        'Internal',
        'multi-space worker died during open: $e',
      );
    }
    boot.close();
    void abandon() {
      death.dispose();
      isolate.kill(priority: Isolate.immediate);
    }

    switch (first) {
      case _MErr(:final kind, :final message):
        abandon();
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
    final port = await _ensure();
    final reply = ReceivePort();
    port.send(build(reply.sendPort));
    // Raced against the worker's death, not awaited alone. `errorsAreFatal`
    // makes a crashed worker die QUIETLY, so `reply.first` on its own stayed
    // pending forever — the all-online unlock showed a spinner no timeout
    // would end, and every later call joined it (audit XV-07).
    final Object? r;
    try {
      r = await Future.any<Object?>([reply.first, _watch!.future]);
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
  Future<void> vacuumOrphans(int id) =>
      _call<void>((reply) => _MVacuumOrphans(id, reply));

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final port = _toWorker;
    if (port == null) {
      // Nothing published yet — but a spawn may be IN FLIGHT and about to
      // publish a worker with the container open. It sees `_closed` and shuts
      // itself down; wait for that to finish rather than returning while a live
      // worker is still on its way up (the flock outlives us otherwise).
      final spawning = _ready;
      if (spawning != null) {
        try {
          await spawning;
        } catch (_) {
          // The rollback throws by design; the teardown it performed is what
          // this await was for.
        }
      }
      _watch?.dispose();
      _isolate?.kill(priority: Isolate.immediate); // never finished spawning
      return;
    }
    await _shutdown(port);
  }

  /// Ask the worker to close the container, then stop watching and kill it.
  ///
  /// Shared by [close] and by the closed-during-spawn rollback in [_spawn], on
  /// purpose: they are the same teardown, and a second hand-rolled copy of it is
  /// how the stranded-flock bug comes back.
  Future<void> _shutdown(SendPort port) async {
    final reply = ReceivePort();
    try {
      port.send(_MClose(reply.sendPort));
      await reply.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => const _MOk(null),
      );
    } finally {
      reply.close();
      // Stop watching BEFORE the kill, or our own teardown reports the worker
      // as having died on us.
      _watch?.dispose();
      _isolate?.kill(priority: Isolate.immediate);
    }
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

void _multiWorkerEntry(_MOpenConfig cfg) {
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

  final rx = ReceivePort();
  cfg.reply.send(_MOk(rx.sendPort));

  rx.listen((dynamic msg) {
    if (msg is! _MReq) return;
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
      case _MClose():
        try {
          backing.close();
          msg.reply.send(const _MOk(null));
        } catch (e) {
          msg.reply.send(_MErr('Internal', e.toString()));
        } finally {
          rx.close();
          Isolate.current.kill(priority: Isolate.immediate);
        }
    }
  });
}
