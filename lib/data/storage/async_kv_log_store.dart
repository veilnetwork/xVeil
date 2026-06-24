import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hidden_volume/hidden_volume.dart' as hv;

import 'hv_kv_log_store.dart';
import 'hv_native.dart';
import 'kv_log_store.dart';

/// Async, OFF-UI-isolate facade over a single unlocked hidden-volume space.
///
/// Every hidden-volume call (`open`, and each `get`/`commit`/`iterLogRange`/…)
/// is SYNCHRONOUS FFI that blocks whichever isolate runs it. On the Flutter UI
/// isolate that freezes the app for the call's duration — and on Android a >5s
/// main-thread block is a fatal ANR. This interface mirrors [KvLogStore] but
/// returns `Future`s; the production implementation ([WorkerKvLogStore]) runs
/// the real [KvLogStore] inside a dedicated long-lived WORKER ISOLATE and serves
/// each op over a [SendPort], so the UI isolate only ever awaits.
///
/// `HiddenVolumeStorage` already exposes a `Future`-returning public API and its
/// callers already `await`, so swapping its backing store from [KvLogStore] to
/// this changes nothing above it — it just stops blocking the UI thread.
abstract interface class AsyncKvLogStore {
  Future<int> commit(List<KvLogOp> ops);
  Future<Uint8List?> get(int namespace, Uint8List key);
  Future<Uint8List?> readLog(int namespace, int logId);
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  });
  Future<int> count(int namespace);
  Future<int> eraseNamespace(int namespace);
  Future<void> scrub();
  Future<Uint8List> exportKeys();
  Future<void> close();
}

/// Adapts a SYNCHRONOUS [KvLogStore] to [AsyncKvLogStore] WITHOUT moving it off
/// the calling isolate — every call still runs the blocking FFI inline, just
/// wrapped in a resolved `Future`. Used for the in-memory fake (no FFI, nothing
/// to offload) and as the not-yet-off-isolated fallback for the master /
/// all-online multi-space + keys paths (a follow-up will give those their own
/// worker). Keeps those paths compiling against the async interface.
class SyncWrappedAsyncKvLogStore implements AsyncKvLogStore {
  SyncWrappedAsyncKvLogStore(this._inner);

  final KvLogStore _inner;

  @override
  Future<int> commit(List<KvLogOp> ops) async => _inner.commit(ops);
  @override
  Future<Uint8List?> get(int namespace, Uint8List key) async =>
      _inner.get(namespace, key);
  @override
  Future<Uint8List?> readLog(int namespace, int logId) async =>
      _inner.readLog(namespace, logId);
  @override
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) async =>
      _inner.iterLogRange(
          namespace: namespace, start: start, end: end, limit: limit);
  @override
  Future<int> count(int namespace) async => _inner.count(namespace);
  @override
  Future<int> eraseNamespace(int namespace) async =>
      _inner.eraseNamespace(namespace);
  @override
  Future<void> scrub() async => _inner.scrub();
  @override
  Future<Uint8List> exportKeys() async => _inner.exportKeys();
  @override
  Future<void> close() async => _inner.close();
}

// ── Worker isolate protocol ─────────────────────────────────────────────────
// The worker OWNS the sync HvKvLogStore. It opens the space as its first act
// (so the Argon2 KDF + open-scan run off the UI isolate too) and then serves
// per-op requests. All message payloads are plain sendable data (ints, byte
// lists, the sealed KvLogOp/KvLogEntry value types).

class _OpenConfig {
  const _OpenConfig({
    required this.path,
    required this.password,
    required this.create,
    required this.reply,
  });
  final String path;
  final Uint8List password;
  final bool create;
  final SendPort reply;
}

sealed class _Req {
  const _Req(this.reply);
  final SendPort reply;
}

class _CommitReq extends _Req {
  const _CommitReq(this.ops, super.reply);
  final List<KvLogOp> ops;
}

class _GetReq extends _Req {
  const _GetReq(this.namespace, this.key, super.reply);
  final int namespace;
  final Uint8List key;
}

class _ReadLogReq extends _Req {
  const _ReadLogReq(this.namespace, this.logId, super.reply);
  final int namespace;
  final int logId;
}

class _IterReq extends _Req {
  const _IterReq(this.namespace, this.start, this.end, this.limit, SendPort reply)
      : super(reply);
  final int namespace;
  final int? start;
  final int? end;
  final int limit;
}

class _CountReq extends _Req {
  const _CountReq(this.namespace, super.reply);
  final int namespace;
}

class _EraseReq extends _Req {
  const _EraseReq(this.namespace, super.reply);
  final int namespace;
}

class _ScrubReq extends _Req {
  const _ScrubReq(super.reply);
}

class _ExportKeysReq extends _Req {
  const _ExportKeysReq(super.reply);
}

class _CloseReq extends _Req {
  const _CloseReq(super.reply);
}

/// Replies. `_Ok(value)` carries the result; `_Null` is a distinct "open found
/// no matching space" (hidden-volume `AuthFailed`, which conflates
/// wrong-password and no-such-space — the deniability invariant); `_Err`
/// re-raises an [hv.HvException] on the caller side.
sealed class _Reply {
  const _Reply();
}

class _Ok extends _Reply {
  const _Ok(this.value);
  final Object? value;
}

class _Null extends _Reply {
  const _Null();
}

class _Err extends _Reply {
  const _Err(this.kind, this.message);
  final String kind;
  final String message;
}

void _workerEntry(_OpenConfig cfg) {
  // The hidden-volume symbols are process-global once the main isolate's
  // startup preload (hv_native.ensureHiddenVolumeLoaded) ran — a spawned
  // isolate shares the process image, so `DynamicLibrary.process()` resolves on
  // desktop; on Android the plugin opens by soname per isolate. Call the
  // idempotent loader anyway so the worker is self-sufficient.
  ensureHiddenVolumeLoaded();

  final KvLogStore store;
  try {
    final opened =
        hvSpaceOpener(cfg.path)(password: cfg.password, create: cfg.create);
    if (opened == null) {
      cfg.reply.send(const _Null()); // AuthFailed → no/ wrong space
      return;
    }
    store = opened;
  } on hv.HvException catch (e) {
    cfg.reply.send(_Err(e.kind, e.message));
    return;
  } catch (e) {
    cfg.reply.send(_Err('Internal', e.toString()));
    return;
  }

  final rx = ReceivePort();
  cfg.reply.send(_Ok(rx.sendPort));

  rx.listen((dynamic msg) {
    if (msg is! _Req) return;
    void run<T>(T Function() body) {
      try {
        msg.reply.send(_Ok(body()));
      } on hv.HvException catch (e) {
        msg.reply.send(_Err(e.kind, e.message));
      } catch (e) {
        msg.reply.send(_Err('Internal', e.toString()));
      }
    }

    switch (msg) {
      case _CommitReq(:final ops):
        run(() => store.commit(ops));
      case _GetReq(:final namespace, :final key):
        run(() => store.get(namespace, key));
      case _ReadLogReq(:final namespace, :final logId):
        run(() => store.readLog(namespace, logId));
      case _IterReq(:final namespace, :final start, :final end, :final limit):
        run(() => store.iterLogRange(
            namespace: namespace, start: start, end: end, limit: limit));
      case _CountReq(:final namespace):
        run(() => store.count(namespace));
      case _EraseReq(:final namespace):
        run(() => store.eraseNamespace(namespace));
      case _ScrubReq():
        run<Object?>(() {
          store.scrub();
          return null;
        });
      case _ExportKeysReq():
        run(() => store.exportKeys());
      case _CloseReq():
        try {
          store.close();
          msg.reply.send(const _Ok(null));
        } catch (e) {
          msg.reply.send(_Err('Internal', e.toString()));
        } finally {
          rx.close();
          Isolate.current.kill(priority: Isolate.immediate);
        }
    }
  });
}

/// Off-UI-isolate [AsyncKvLogStore] backed by a dedicated worker isolate that
/// owns the real [HvKvLogStore]. One instance == one worker == one container
/// handle. Drop with [close].
class WorkerKvLogStore implements AsyncKvLogStore {
  WorkerKvLogStore._(this._isolate, this._toWorker);

  final Isolate _isolate;
  final SendPort _toWorker;
  bool _closed = false;

  /// Spawn a worker that opens (or, with [create], opens-or-adds) the space at
  /// [path] for [password]. Returns null when no space matches the password
  /// (hidden-volume `AuthFailed` — kept indistinguishable from wrong-password,
  /// the deniability invariant). Throws [hv.HvException] on any other failure.
  static Future<WorkerKvLogStore?> open({
    required String path,
    required Uint8List password,
    required bool create,
  }) async {
    final boot = ReceivePort();
    final isolate = await Isolate.spawn<_OpenConfig>(
      _workerEntry,
      _OpenConfig(
          path: path, password: password, create: create, reply: boot.sendPort),
      errorsAreFatal: true,
    );
    final first = await boot.first;
    boot.close();
    switch (first) {
      case _Null():
        isolate.kill(priority: Isolate.immediate);
        return null;
      case _Err(:final kind, :final message):
        isolate.kill(priority: Isolate.immediate);
        throw hv.HvException(kind, message);
      case _Ok(:final value):
        return WorkerKvLogStore._(isolate, value as SendPort);
      default:
        isolate.kill(priority: Isolate.immediate);
        throw StateError('worker sent an unexpected bootstrap reply');
    }
  }

  Future<T> _call<T>(_Req Function(SendPort reply) build) async {
    if (_closed) throw StateError('WorkerKvLogStore is closed');
    final reply = ReceivePort();
    _toWorker.send(build(reply.sendPort));
    final r = await reply.first;
    reply.close();
    if (r is _Err) throw hv.HvException(r.kind, r.message);
    return (r as _Ok).value as T;
  }

  @override
  Future<int> commit(List<KvLogOp> ops) =>
      _call<int>((reply) => _CommitReq(ops, reply));
  @override
  Future<Uint8List?> get(int namespace, Uint8List key) =>
      _call<Uint8List?>((reply) => _GetReq(namespace, key, reply));
  @override
  Future<Uint8List?> readLog(int namespace, int logId) =>
      _call<Uint8List?>((reply) => _ReadLogReq(namespace, logId, reply));
  @override
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) =>
      _call<List<KvLogEntry>>(
          (reply) => _IterReq(namespace, start, end, limit, reply));
  @override
  Future<int> count(int namespace) =>
      _call<int>((reply) => _CountReq(namespace, reply));
  @override
  Future<int> eraseNamespace(int namespace) =>
      _call<int>((reply) => _EraseReq(namespace, reply));
  @override
  Future<void> scrub() => _call<void>((reply) => _ScrubReq(reply));
  @override
  Future<Uint8List> exportKeys() =>
      _call<Uint8List>((reply) => _ExportKeysReq(reply));

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final reply = ReceivePort();
    try {
      _toWorker.send(_CloseReq(reply.sendPort));
      await reply.first
          .timeout(const Duration(seconds: 5), onTimeout: () => const _Ok(null));
    } finally {
      reply.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

/// Opens (or creates) the space for [password] OFF the UI isolate. The async
/// analogue of [SpaceOpener] — production wiring spawns a [WorkerKvLogStore].
typedef AsyncSpaceOpener = Future<AsyncKvLogStore?> Function({
  required Uint8List password,
  required bool create,
});

/// Builds an [AsyncSpaceOpener] over the hidden-volume container at [path] whose
/// open + every operation run on a worker isolate (UI thread never blocks).
AsyncSpaceOpener workerSpaceOpener(String path) {
  return ({required Uint8List password, required bool create}) =>
      WorkerKvLogStore.open(path: path, password: password, create: create);
}

/// Async analogue of [KeysSpaceOpener] — opens a space directly from its
/// pre-derived 64-byte `SpaceKeys` (master mode), off the UI isolate.
typedef AsyncKeysSpaceOpener = Future<AsyncKvLogStore?> Function(Uint8List keys);

/// Lifts a synchronous [SpaceOpener] to an [AsyncSpaceOpener] by running it
/// INLINE (no worker) and wrapping the result in a [SyncWrappedAsyncKvLogStore].
/// For the in-memory fake (nothing to offload) and any path not yet given its
/// own worker.
AsyncSpaceOpener syncWrappedSpaceOpener(SpaceOpener inner) {
  return ({required Uint8List password, required bool create}) async {
    final s = inner(password: password, create: create);
    return s == null ? null : SyncWrappedAsyncKvLogStore(s);
  };
}

/// Lifts a synchronous [KeysSpaceOpener] to an [AsyncKeysSpaceOpener] the same
/// way (inline + sync-wrapped). The master/keys path is not yet offloaded to a
/// worker; this keeps it compiling against the async surface with no behaviour
/// change.
AsyncKeysSpaceOpener syncWrappedKeysOpener(KeysSpaceOpener inner) {
  return (Uint8List keys) async {
    final s = inner(keys);
    return s == null ? null : SyncWrappedAsyncKvLogStore(s);
  };
}
