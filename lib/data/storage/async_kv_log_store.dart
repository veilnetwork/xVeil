import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hidden_volume/hidden_volume.dart' as hv;

import 'hv_kv_log_store.dart';
import 'hv_native.dart';
import 'kv_log_store.dart';
import 'worker_death.dart';
import 'package:xveil/core/log.dart';

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
  Future<List<Uint8List>> kvKeys(int namespace);
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
  }) async => _inner.iterLogRange(
    namespace: namespace,
    start: start,
    end: end,
    limit: limit,
  );
  @override
  Future<int> count(int namespace) async => _inner.count(namespace);

  @override
  Future<List<Uint8List>> kvKeys(int namespace) async =>
      _inner.kvKeys(namespace);
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

/// What the worker opens as its first act. Two ways in, one worker:
/// a password-derived space, or a child space from its pre-derived `SpaceKeys`
/// (master mode). Both are the same synchronous FFI and both were blocking
/// whichever isolate ran them — the keys one was still running on the UI
/// isolate (audit XV-14).
sealed class _OpenConfig {
  const _OpenConfig({
    required this.path,
    required this.paddingPresetTag,
    required this.reply,
  });
  final String path;
  final int paddingPresetTag;
  final SendPort reply;
}

class _OpenByPassword extends _OpenConfig {
  const _OpenByPassword({
    required super.path,
    required super.paddingPresetTag,
    required super.reply,
    required this.password,
    required this.create,
  });
  final Uint8List password;
  final bool create;
}

class _OpenByKeys extends _OpenConfig {
  const _OpenByKeys({
    required super.path,
    required super.paddingPresetTag,
    required super.reply,
    required this.keys,
  });
  final Uint8List keys;
}

hv.PaddingPreset _paddingPresetFromTag(int tag) {
  for (final preset in hv.PaddingPreset.values) {
    if (preset.tag == tag) return preset;
  }
  return hv.PaddingPreset.bucket256KiB;
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
  const _IterReq(
    this.namespace,
    this.start,
    this.end,
    this.limit,
    SendPort reply,
  ) : super(reply);
  final int namespace;
  final int? start;
  final int? end;
  final int limit;
}

class _KvKeysReq extends _Req {
  const _KvKeysReq(this.namespace, super.reply);
  final int namespace;
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
    final preset = _paddingPresetFromTag(cfg.paddingPresetTag);
    final opened = switch (cfg) {
      _OpenByPassword(:final password, :final create) => hvSpaceOpener(
        cfg.path,
        paddingPreset: preset,
      )(password: password, create: create),
      _OpenByKeys(:final keys) => hvKeysSpaceOpener(
        cfg.path,
        paddingPreset: preset,
      )(keys),
    };
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
        run(
          () => store.iterLogRange(
            namespace: namespace,
            start: start,
            end: end,
            limit: limit,
          ),
        );
      case _CountReq(:final namespace):
        run(() => store.count(namespace));
      case _KvKeysReq(:final namespace):
        run(() => store.kvKeys(namespace));
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
  WorkerKvLogStore._(this._isolate, this._toWorker, this._watch);

  final Isolate _isolate;
  final SendPort _toWorker;

  /// Completes with an error when the worker isolate dies (audit XV-07).
  ///
  /// Every RPC used to `await reply.first` with nothing watching the isolate,
  /// so a worker that crashed — an FFI fault, an uncaught error, an OOM kill —
  /// left that future pending FOREVER. The UI showed a spinner that no timeout
  /// would ever end, and every later call joined it. `errorsAreFatal: true`
  /// made the isolate die quietly; nothing was listening for the death.
  ///
  /// Racing each wait against this turns an invisible hang into an error the
  /// caller can report and recover from.
  final WorkerDeath _watch;
  Future<Never> get _death => _watch.future;
  bool _closed = false;

  /// Spawn a worker that opens (or, with [create], opens-or-adds) the space at
  /// [path] for [password]. Returns null when no space matches the password
  /// (hidden-volume `AuthFailed` — kept indistinguishable from wrong-password,
  /// the deniability invariant). Throws [hv.HvException] on any other failure.
  static Future<WorkerKvLogStore?> open({
    required String path,
    required Uint8List password,
    required bool create,
    required hv.PaddingPreset paddingPreset,
  }) => _spawn(
    (reply) => _OpenByPassword(
      path: path,
      paddingPresetTag: paddingPreset.tag,
      reply: reply,
      password: password,
      create: create,
    ),
  );

  /// Spawn a worker that opens the child space [keys] belongs to (master mode,
  /// no password). Same null/throw contract as [open].
  ///
  /// This path used to run INLINE on the caller — which in production is the
  /// Flutter UI isolate. `open_with_keys` skips the KDF but still opens the
  /// container and scans it, and that scan grows with the container: on a large
  /// one it is jank on desktop and a >5s main-thread block, i.e. a fatal ANR,
  /// on Android. Every caller (unlock into an identity, identity switch, roster
  /// edit) already awaited, so nothing above needed to change (audit XV-14).
  static Future<WorkerKvLogStore?> openWithKeys({
    required String path,
    required Uint8List keys,
    required hv.PaddingPreset paddingPreset,
  }) => _spawn(
    (reply) => _OpenByKeys(
      path: path,
      paddingPresetTag: paddingPreset.tag,
      reply: reply,
      keys: keys,
    ),
  );

  /// One supervised spawn for both open flavours. Deliberately shared: the
  /// death-watch wiring below is exactly the bug XV-07 was, and a second
  /// hand-rolled copy of it for the keys path is how that bug would come back.
  static Future<WorkerKvLogStore?> _spawn(
    _OpenConfig Function(SendPort reply) build,
  ) async {
    final boot = ReceivePort();
    // Watch the isolate BEFORE it can die (audit XV-07). Wired at spawn time
    // rather than after, because a worker that fails while opening the
    // container fails FAST — most often on the very first FFI call — and a
    // watcher attached afterwards would miss exactly that case.
    final death = WorkerDeath();
    final isolate = await Isolate.spawn<_OpenConfig>(
      _workerEntry,
      build(boot.sendPort),
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
      throw hv.HvException('Internal', 'storage worker died during open: $e');
    }
    boot.close();
    void abandon() {
      death.dispose();
      isolate.kill(priority: Isolate.immediate);
    }

    switch (first) {
      case _Null():
        abandon();
        return null;
      case _Err(:final kind, :final message):
        abandon();
        throw hv.HvException(kind, message);
      case _Ok(:final value):
        return WorkerKvLogStore._(isolate, value as SendPort, death);
      default:
        abandon();
        throw StateError('worker sent an unexpected bootstrap reply');
    }
  }

  Future<T> _call<T>(_Req Function(SendPort reply) build) async {
    if (_closed) throw StateError('WorkerKvLogStore is closed');
    final reply = ReceivePort();
    try {
      _toWorker.send(build(reply.sendPort));
      // Raced against the worker's death (audit XV-07): without it a crashed
      // worker leaves this pending forever, and every later call joins it.
      final r = await Future.any<Object?>([reply.first, _death]);
      if (r is _Err) throw hv.HvException(r.kind, r.message);
      return (r as _Ok).value as T;
    } finally {
      reply.close();
    }
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
  }) => _call<List<KvLogEntry>>(
    (reply) => _IterReq(namespace, start, end, limit, reply),
  );
  @override
  Future<int> count(int namespace) =>
      _call<int>((reply) => _CountReq(namespace, reply));

  @override
  Future<List<Uint8List>> kvKeys(int namespace) =>
      _call<List<Uint8List>>((reply) => _KvKeysReq(namespace, reply));
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
    final done = reply.first; // single-subscription: capture exactly once
    _toWorker.send(_CloseReq(reply.sendPort));
    final r = await done.timeout(
      const Duration(seconds: 5),
      // The worker never replies a bare null (_Ok/_Err are objects), so null
      // unambiguously means the timeout fired.
      onTimeout: () => null,
    );
    if (r != null) {
      reply.close();
      // Stop watching BEFORE the kill: an expected shutdown is not a death to
      // report, and leaving the watcher armed turns every clean close into an
      // error future with nobody listening (audit XV-07).
      _watch.dispose();
      _isolate.kill(priority: Isolate.immediate);
      return;
    }
    // Timed out — the worker is almost certainly blocked inside a long
    // synchronous FFI op (a big commit/scan) with our close queued behind it.
    // KILLING IT HERE WOULD LEAK THE NATIVE CONTAINER HANDLE: an isolate kill
    // cannot interrupt or unwind an FFI frame, so the store would never close,
    // the container's exclusive flock would stay held by THIS PROCESS, and
    // every later open of the container would fail Busy until an app restart —
    // the "correct password but won't unlock" trap. Return now so the caller
    // (lock/switch) isn't stuck, but let the worker drain and close in the
    // background; it kills itself after serving _CloseReq.
    devLog(
      () =>
          'xVeil[storage]: worker close timed out (>5s) — waiting in '
          'background for the store to finish closing (flock still held)',
    );
    unawaited(
      done
          .then(
            (_) => devLog(
              () =>
                  'xVeil[storage]: late worker close completed — container '
                  'handle released',
            ),
          )
          .catchError((Object e) {
            devLog(() => 'xVeil[storage]: late worker close failed: $e');
          })
          .whenComplete(() {
            reply.close();
            // The worker is finally gone, on its own terms. Stop watching now
            // rather than at the timeout: until this lands the isolate is still
            // live and a real crash in the meantime is still worth reporting.
            _watch.dispose();
          }),
    );
  }
}

/// Opens (or creates) the space for [password] OFF the UI isolate. The async
/// analogue of [SpaceOpener] — production wiring spawns a [WorkerKvLogStore].
typedef AsyncSpaceOpener =
    Future<AsyncKvLogStore?> Function({
      required Uint8List password,
      required bool create,
    });

/// Once the worker isolate is proven unable to open a space (e.g. a spawned
/// isolate that can't load the native lib — observed on Android), stop spawning
/// it for the rest of the process and open INLINE instead. Process-global so a
/// single failure flips every space to the safe path.
bool _workerOpenUsable = true;

/// Builds an [AsyncSpaceOpener] over the hidden-volume container at [path] whose
/// open + every operation run on a worker isolate (UI thread never blocks).
///
/// SELF-HEALING: if the worker itself fails to open (a THROW from
/// [WorkerKvLogStore.open] — a genuine wrong-password/no-space comes back as
/// `null`, NOT a throw), fall back to opening the space INLINE on the calling
/// isolate, where the native lib was already loaded at startup
/// (`ensureHiddenVolumeLoaded`). Off-isolate is forfeited for the rest of the
/// run, but the user can still UNLOCK — critical: a worker that can't load the
/// lib otherwise surfaces as "wrong password" and locks the user out.
AsyncSpaceOpener workerSpaceOpener(
  String path, {
  hv.PaddingPreset paddingPreset = hv.PaddingPreset.bucket256KiB,
}) {
  return ({required Uint8List password, required bool create}) async {
    if (_workerOpenUsable) {
      try {
        return await WorkerKvLogStore.open(
          path: path,
          password: password,
          create: create,
          paddingPreset: paddingPreset,
        );
      } on hv.HvException catch (e) {
        devLog(
          () =>
              'xVeil[storage]: worker open FAILED (${e.kind}: ${e.message}) — '
              'trying INLINE open',
        );
        // A CONTAINER-level failure (Busy from a still-held flock, a corrupt
        // file) hits the inline path identically — it throws out of here to the
        // caller (which must surface it, not report "wrong password"), and the
        // worker path stays enabled for the next attempt. Only when the inline
        // open SUCCEEDS where the worker failed is the worker itself proven
        // defective (e.g. a spawned isolate that can't load the native lib —
        // observed on Android) — then disable it for the rest of the run.
        final inline = hvSpaceOpener(path, paddingPreset: paddingPreset)(
          password: password,
          create: create,
        );
        _workerOpenUsable = false;
        devLog(
          () =>
              'xVeil[storage]: INLINE open worked where the worker failed — '
              'off-isolate storage disabled for the rest of this run',
        );
        return inline == null ? null : SyncWrappedAsyncKvLogStore(inline);
      }
    }
    final inline = hvSpaceOpener(path, paddingPreset: paddingPreset)(
      password: password,
      create: create,
    );
    return inline == null ? null : SyncWrappedAsyncKvLogStore(inline);
  };
}

/// Async analogue of [KeysSpaceOpener] — opens a space directly from its
/// pre-derived 64-byte `SpaceKeys` (master mode), off the UI isolate.
typedef AsyncKeysSpaceOpener =
    Future<AsyncKvLogStore?> Function(Uint8List keys);

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

/// Lifts a synchronous [KeysSpaceOpener] to an [AsyncKeysSpaceOpener] by running
/// it INLINE on the calling isolate. For the in-memory fake, where there is
/// nothing to offload.
///
/// ⛔ Not for a real container. Inline means the caller is the isolate that
/// executes `open_with_keys`, and in production that caller is the UI isolate —
/// see [workerKeysSpaceOpener] (audit XV-14).
AsyncKeysSpaceOpener syncWrappedKeysOpener(KeysSpaceOpener inner) {
  return (Uint8List keys) async {
    final s = inner(keys);
    return s == null ? null : SyncWrappedAsyncKvLogStore(s);
  };
}

/// Builds an [AsyncKeysSpaceOpener] over the container at [path] whose open —
/// and every operation after it — runs on a worker isolate.
///
/// The keys/master path was the last real-container opener still lifted with
/// [syncWrappedKeysOpener], i.e. still opening on the UI isolate long after the
/// password path had moved off it. There was no constraint keeping it there:
/// every caller already awaits, and every flow closes the previous space before
/// opening the next (`_closeStaleStoreBeforeOpen`, and `IdentityManager` opens
/// master and child strictly one at a time), so the container's exclusive flock
/// is never wanted by two isolates at once (audit XV-14).
///
/// SELF-HEALING, and deliberately the same rule as [workerSpaceOpener]: a THROW
/// from the worker (not `null`, which is the "these keys match no space"
/// answer) is retried INLINE, and only an inline open that SUCCEEDS where the
/// worker failed proves the worker itself defective — then off-isolate is
/// forfeited for the rest of the run, for both openers, via the shared
/// [_workerOpenUsable]. A container-level failure (a still-held flock, a
/// corrupt file) fails the same way inline and propagates to the caller.
AsyncKeysSpaceOpener workerKeysSpaceOpener(
  String path, {
  hv.PaddingPreset paddingPreset = hv.PaddingPreset.bucket256KiB,
}) {
  AsyncKvLogStore? inlineOpen(Uint8List keys) {
    final inline = hvKeysSpaceOpener(path, paddingPreset: paddingPreset)(keys);
    return inline == null ? null : SyncWrappedAsyncKvLogStore(inline);
  }

  return (Uint8List keys) async {
    if (_workerOpenUsable) {
      try {
        return await WorkerKvLogStore.openWithKeys(
          path: path,
          keys: keys,
          paddingPreset: paddingPreset,
        );
      } on hv.HvException catch (e) {
        devLog(
          () =>
              'xVeil[storage]: worker keys-open FAILED (${e.kind}: ${e.message})'
              ' — trying INLINE open',
        );
        final inline = inlineOpen(keys);
        _workerOpenUsable = false;
        devLog(
          () =>
              'xVeil[storage]: INLINE keys-open worked where the worker failed '
              '— off-isolate storage disabled for the rest of this run',
        );
        return inline;
      }
    }
    return inlineOpen(keys);
  };
}
