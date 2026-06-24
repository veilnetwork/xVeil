import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hidden_volume/hidden_volume.dart' as hv;

import 'hv_kv_log_store.dart';
import 'hv_native.dart';
import 'kv_log_store.dart';
import 'multi_space_store.dart';

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
  WorkerMultiSpaceBacking(this._path);

  final String _path;
  Isolate? _isolate;
  SendPort? _toWorker;
  Future<SendPort>? _ready;
  bool _closed = false;

  Future<SendPort> _ensure() => _ready ??= _spawn();

  Future<SendPort> _spawn() async {
    final boot = ReceivePort();
    final isolate = await Isolate.spawn<_MOpenConfig>(
      _multiWorkerEntry,
      _MOpenConfig(path: _path, reply: boot.sendPort),
      errorsAreFatal: true,
    );
    final first = await boot.first;
    boot.close();
    switch (first) {
      case _MErr(:final kind, :final message):
        isolate.kill(priority: Isolate.immediate);
        throw hv.HvException(kind, message);
      case _MOk(:final value):
        _isolate = isolate;
        _toWorker = value as SendPort;
        return _toWorker!;
      default:
        isolate.kill(priority: Isolate.immediate);
        throw StateError('multi-space worker sent an unexpected bootstrap reply');
    }
  }

  Future<T> _call<T>(_MReq Function(SendPort reply) build) async {
    if (_closed) throw StateError('WorkerMultiSpaceBacking is closed');
    final port = await _ensure();
    final reply = ReceivePort();
    port.send(build(reply.sendPort));
    final r = await reply.first;
    reply.close();
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
  }) =>
      _call<List<KvLogEntry>>(
          (reply) => _MIter(id, namespace, start, end, limit, reply));
  @override
  Future<int> count(int id, int namespace) =>
      _call<int>((reply) => _MCount(id, namespace, reply));
  @override
  Future<Uint8List> exportKeys(int id) =>
      _call<Uint8List>((reply) => _MExportKeys(id, reply));
  @override
  Future<void> scrub(int id) => _call<void>((reply) => _MScrub(id, reply));

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final port = _toWorker;
    if (port == null) {
      _isolate?.kill(priority: Isolate.immediate); // never finished spawning
      return;
    }
    final reply = ReceivePort();
    try {
      port.send(_MClose(reply.sendPort));
      await reply.first
          .timeout(const Duration(seconds: 5), onTimeout: () => const _MOk(null));
    } finally {
      reply.close();
      _isolate?.kill(priority: Isolate.immediate);
    }
  }
}

// ── Worker isolate protocol ─────────────────────────────────────────────────
// The worker OWNS the sync HvMultiSpaceBacking. It opens the container as its
// first act (off the UI isolate) then serves per-(id, op) requests. All message
// payloads are plain sendable data (ints, byte lists, the sealed value types).

class _MOpenConfig {
  const _MOpenConfig({required this.path, required this.reply});
  final String path;
  final SendPort reply;
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
  const _MIter(this.id, this.namespace, this.start, this.end, this.limit, SendPort reply)
      : super(reply);
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

class _MExportKeys extends _MReq {
  const _MExportKeys(this.id, super.reply);
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
    backing = HvMultiSpaceBacking.open(cfg.path);
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
      case _MIter(:final id, :final namespace, :final start, :final end, :final limit):
        run(() => backing.iterLogRange(id,
            namespace: namespace, start: start, end: end, limit: limit));
      case _MCount(:final id, :final namespace):
        run(() => backing.count(id, namespace));
      case _MExportKeys(:final id):
        run(() => backing.exportKeys(id));
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
