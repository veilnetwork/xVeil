import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// The ABI contract is GENERATED from `veil_ffi.h` and lives with the bindings
// it describes. Reaching into the plugin's `lib/src` for it is deliberate and
// is the lesser evil by a wide margin: the alternative is restating a hash and
// a reader in this package, where they would drift from the header the moment
// it changed — which is the exact class of divergence this check exists to
// catch, reintroduced by the check itself.
// ignore: implementation_imports
import 'package:veil_flutter/src/abi_contract.dart' show veilAbiContractHash;
// ignore: implementation_imports
import 'package:veil_flutter/src/native.dart'
    show VeilAbiContractMismatch, readAbiContractHash;

import '../../core/log.dart';
import '../../core/secret_wipe.dart';
import '../native_libs.dart' show processLibFor;
import '../storage/storage.dart'
    show kRatchetKeyLen, kRatchetMaxStateLen, RatchetStateEntry, Storage;

/// The one thing in veil that cannot be rebuilt from anything public.
///
/// A Double Ratchet IS state: chain keys that advance one way, message keys
/// banked for frames that arrived out of order, an outstanding key
/// encapsulation. veil holds it in memory and keeps none of it — its only
/// database belongs to the mailbox and is reachable from neither the send path
/// nor the frame dispatcher. This is the door the host reaches it through.
///
/// An interface rather than the FFI class directly, because everything that
/// matters about the persistence contract — WHEN the host writes, and WHAT —
/// has to be provable without a native node in the loop.
/// A point in a conversation's sending chain: which chain, and the index the
/// next sealed message will carry.
///
/// Small on purpose. A host records this durably before it publishes, and the
/// whole reason it is not the state itself is that the state is too big to
/// write on the send path.
class RatchetSendPosition {
  const RatchetSendPosition(this.chain, this.next);

  /// The sending DH public key. A sending chain lives and dies with it, so it
  /// says whether a recorded position still refers to the chain in hand.
  final Uint8List chain;

  /// The index the next sealed message will carry.
  final int next;

  @override
  String toString() => 'RatchetSendPosition(next: $next)';
}

abstract interface class RatchetStateHandle {
  /// Ratchet operations this node has COMMITTED since it started.
  ///
  /// Monotonic and moved only by work that actually completed: a forged frame
  /// that failed its tag moves nothing. Lets a caller tell "no conversation
  /// changed" from "one changed and I read it twice", which a dirty list alone
  /// cannot say.
  int stateVersion();

  /// Up to [maxKeys] conversations waiting to be persisted, how many are still
  /// waiting beyond them, and the generation to acknowledge them at.
  ///
  /// CONSUMES NOTHING. Reading the list is not what discharges the obligation:
  /// between here and a durable write there is an export, a worker hop and a
  /// commit, and a failure at any of them would otherwise lose the only notice
  /// these conversations get — along with the rest of their batch — until they
  /// change again. The marks stand until [ackDirty].
  ///
  /// Whatever did not fit stays marked too, so a caller with a small buffer
  /// loops until `remaining` reads zero.
  ({List<Uint8List> keys, int remaining, int generation}) peekDirty(
    int maxKeys,
  );

  /// Clear the marks of [keys] whose state is now DURABLE, as of [generation].
  ///
  /// Called after the write lands and never before. A conversation that changed
  /// since the peek was re-marked at a later generation and keeps its mark: the
  /// bytes just written do not contain that change, and clearing it would throw
  /// away the only notice it gets. Returns how many marks were cleared, which
  /// is how a caller sees that one moved under it.
  int ackDirty(List<Uint8List> keys, int generation);

  /// Every conversation held, consuming nothing — for a full save at shutdown.
  List<Uint8List> list();

  /// One conversation's whole state, or null when the key names nothing held.
  ///
  /// EVERY BYTE IS KEY MATERIAL: never log it, never copy it to a temporary
  /// file, never put it in an error report.
  Uint8List? export(Uint8List conversationKey);

  /// Restore one conversation from bytes [export] produced.
  ///
  /// A STARTUP step, not a lazy one: a frame that arrives for a conversation
  /// not yet restored cannot be opened, and — unlike a lost packet — the sender
  /// has already advanced its chain, so nothing will re-send it in a form this
  /// node can read. Returns false when veil refuses the blob.
  bool import(Uint8List conversationKey, Uint8List blob);

  /// Where a conversation's sending chain stands, or null when the key names
  /// nothing held or nothing with a sending chain yet.
  ///
  /// 36 bytes, which is what makes it affordable to write durably BEFORE a
  /// ciphertext is published. The state itself runs to kilobytes and is
  /// written after — and that ordering is what lets a failed write plus a
  /// restart re-derive a key already spent on the wire (report12 X-H5).
  RatchetSendPosition? sendPosition(Uint8List conversationKey);

  /// Step a conversation's sending chain past every index that might already
  /// have been spent, and return how many keys were burned.
  ///
  /// The recovery half of [sendPosition], run at startup against the last
  /// position recorded. A position naming a chain the conversation is no
  /// longer on, or an index it has already passed, burns nothing and is not an
  /// error. Returns 0 when the key names nothing held.
  int skipSendTo(Uint8List conversationKey, RatchetSendPosition to);

  /// Drop one conversation. IRREVERSIBLE — nothing public can rebuild the
  /// chain, so every message the peer has already sealed to it is unreadable
  /// from here on. Returns false when nothing was held.
  bool forget(Uint8List conversationKey);

  /// Age out every conversation this device has never spoken on and that has
  /// gone unused past veil's time-to-live. Returns how many went.
  ///
  /// For a timer or a return to the foreground. Without a caller the sweep only
  /// runs when the store hits its ceiling, so a device flooded once carries the
  /// wreckage until something else needs the room.
  ///
  /// Only unproven conversations age out. One that has carried traffic is never
  /// dropped by time at any age: the peer cannot restart its copy from anything
  /// on the wire, so aging one out would wedge both ends permanently. Those are
  /// [forget]'s business, on a user's decision.
  ///
  /// veil reads its own clock for this. There is deliberately no parameter —
  /// nothing that arrived over the network gets to decide what is old enough to
  /// disappear.
  ///
  /// Each conversation dropped is MARKED, so the stored blob is deleted by the
  /// next [RatchetPersistence.flush] rather than resurrected at the next launch.
  int expire();

  /// Release whatever this door is holding open. Idempotent.
  ///
  /// On the interface rather than only on the FFI class because the teardown
  /// leg that calls it runs against whatever a stack was built with, and a
  /// leaked IPC connection is a node whose shutdown waits on nothing.
  void close();
}

// C ABI from veilclient-ffi (node-embedded feature). See veil_ffi.h.
typedef _VersionNative =
    Int32 Function(Pointer<Void>, Pointer<Uint64>, Pointer<Pointer<Utf8>>);
typedef _VersionDart =
    int Function(Pointer<Void>, Pointer<Uint64>, Pointer<Pointer<Utf8>>);
// `size_t` is UNSIGNED, and `Size` is the only Dart type that says so. `IntPtr`
// happens to be the right WIDTH on every ABI here, which is exactly why the
// mismatch survives: on 64-bit nothing observable differs, and on a 32-bit ABI
// (Android armeabi-v7a, x86) a length above 2 GiB reads back NEGATIVE and every
// bound check downstream compares against the wrong sign.
typedef _PeekDirtyNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Size,
      Pointer<Size>,
      Pointer<Size>,
      Pointer<Uint64>,
      Pointer<Pointer<Utf8>>,
    );
typedef _PeekDirtyDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Size>,
      Pointer<Size>,
      Pointer<Uint64>,
      Pointer<Pointer<Utf8>>,
    );
typedef _AckDirtyNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Size,
      Uint64,
      Pointer<Size>,
      Pointer<Pointer<Utf8>>,
    );
typedef _AckDirtyDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      int,
      Pointer<Size>,
      Pointer<Pointer<Utf8>>,
    );
typedef _ListNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Size,
      Pointer<Size>,
      Pointer<Pointer<Utf8>>,
    );
typedef _ListDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Size>,
      Pointer<Pointer<Utf8>>,
    );
typedef _ExportNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Size,
      Pointer<Size>,
      Pointer<Pointer<Utf8>>,
    );
typedef _ExportDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Size>,
      Pointer<Pointer<Utf8>>,
    );
typedef _SendPositionNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint32>,
      Pointer<Pointer<Utf8>>,
    );
typedef _SendPositionDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint32>,
      Pointer<Pointer<Utf8>>,
    );
typedef _SkipSendNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Pointer<Utf8>>,
    );
typedef _SkipSendDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Uint32>,
      Pointer<Pointer<Utf8>>,
    );
typedef _ImportNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Utf8>>,
    );
typedef _ImportDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Utf8>>,
    );
typedef _ForgetNative =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Utf8>>);
typedef _ForgetDart =
    int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Utf8>>);
// `Size`, not `IntPtr`: the C parameter is `size_t *`, and getting that wrong
// is how the ratchet's state came to be never written at all.
typedef _ExpireNative =
    Int32 Function(Pointer<Void>, Pointer<Size>, Pointer<Pointer<Utf8>>);
typedef _ExpireDart =
    int Function(Pointer<Void>, Pointer<Size>, Pointer<Pointer<Utf8>>);
typedef _FreeStrNative = Void Function(Pointer<Utf8>);
typedef _FreeStrDart = void Function(Pointer<Utf8>);
// VeilHandle *veil_connect(const uint8_t*, uintptr_t, char** err_out);
// void        veil_close(VeilHandle*);
typedef _ConnectNative =
    Pointer<Void> Function(Pointer<Uint8>, IntPtr, Pointer<Pointer<Utf8>>);
typedef _ConnectDart =
    Pointer<Void> Function(Pointer<Uint8>, int, Pointer<Pointer<Utf8>>);
typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

/// Read `veil_ratchet_peek_dirty`'s answer out of the buffer it filled.
///
/// [writtenKeys] is a COUNT OF KEYS. The C contract says so — "`*out_written`
/// receives how many keys were written" — and veil bounds it by
/// `out_buf_cap / VEIL_RATCHET_KEY_LEN`. Reading it as a BYTE LENGTH is silent
/// and total: at the standard batch of 32 every non-empty answer is at most 32,
/// one key is [kRatchetKeyLen] = 64 bytes, so the split yields ZERO keys on a
/// call that has ALREADY cleared their dirty marks. The flush then sees an
/// empty list and `remaining == 0`, reports success, and the next launch
/// re-imports the state from before the send — which on an established
/// conversation re-derives a sending-chain message key that was already spent.
///
/// Its own function, and public, because that arithmetic is the whole defect
/// and a `Pointer` is not something a test can hand to anything. The bound
/// check is the other half: a count that cannot be right must not be turned
/// into a number of keys read out of the buffer.
List<Uint8List> dirtyKeysFrom(Uint8List buffer, int writtenKeys, int maxKeys) {
  if (writtenKeys < 0 || writtenKeys > maxKeys) {
    throw StateError(
      'veil_ratchet_peek_dirty wrote $writtenKeys keys for a buffer of '
      '$maxKeys',
    );
  }
  final bytes = writtenKeys * kRatchetKeyLen;
  if (bytes > buffer.length) {
    throw StateError(
      'veil_ratchet_peek_dirty wrote $bytes bytes into ${buffer.length}',
    );
  }
  // `i + kRatchetKeyLen <= bytes`, not `i < bytes`: [bytes] is an exact
  // multiple of the key length whenever the count is right, so the two agree —
  // and when it is NOT right, this one yields no key at all rather than a
  // 64-byte read off the end of a one-byte answer.
  return [
    for (var i = 0; i + kRatchetKeyLen <= bytes; i += kRatchetKeyLen)
      Uint8List.fromList(buffer.sublist(i, i + kRatchetKeyLen)),
  ];
}

/// `VEIL_ERR_RATCHET_NO_CONVERSATION` — the key names nothing this node holds.
const int kVeilErrRatchetNoConversation = -20;

/// `VEIL_ERR_RATCHET_BUFFER_TOO_SMALL` — nothing written, nothing consumed, and
/// the required length was reported instead.
const int kVeilErrRatchetBufferTooSmall = -21;

/// Refuse [dl] unless its C ABI is the one these bindings were generated
/// against — BEFORE any other symbol on it is looked up.
///
/// The guard existed, but only inside the veil_flutter plugin's own loader, and
/// nothing in this file goes through that loader: it resolves its own handle
/// with [processLibFor]. So the ratchet door — the one part of veil whose state
/// cannot be rebuilt from anything public — was the one door reached over an
/// UNVERIFIED ABI.
///
/// The failure this guards is not a missing symbol (that fails loudly on its
/// own). It is a symbol that still exists and no longer means the same thing: a
/// parameter inserted into the middle of a list, a `size_t` that changed width.
/// One call through that is memory corruption, so the check has to come before
/// the first one — which is why [ratchetStateAvailable] can no longer answer
/// from a lookup alone.
///
/// [expectedAbiHash] is a parameter rather than a constant read inline for the
/// same reason the plugin's loader takes one: so the refusal itself is testable
/// against a REAL library. There is no mocking a [DynamicLibrary].
void assertRatchetAbiContract(
  DynamicLibrary dl, {
  String expectedAbiHash = veilAbiContractHash,
}) {
  final actual = readAbiContractHash(dl);
  if (actual != expectedAbiHash) {
    throw VeilAbiContractMismatch(expected: expectedAbiHash, actual: actual);
  }
}

/// True when the loaded dylib exposes the ratchet door (built
/// `--features node-embedded` against a veil new enough to have it).
///
/// Answered by a symbol lookup rather than a version check: a build without
/// the feature is not a broken build, it is one whose one-to-one messages are
/// not ratcheted, and it must still run.
///
/// The ABI contract is checked FIRST, and its failure is NOT folded into the
/// `false` below. The two are different facts and collapsing them is what the
/// bug was: `veil_ratchet_state_version` exists in the outdated library too, so
/// a mismatched native answered "available" here and then failed later, on some
/// newer symbol, with a message about the wrong thing entirely. "This build has
/// no ratchet" is a state to run in; "this library is not the one these
/// bindings describe" is not.
bool ratchetStateAvailable({
  DynamicLibrary? lib,
  String expectedAbiHash = veilAbiContractHash,
}) {
  final dl = lib ?? processLibFor('veilclient_ffi');
  assertRatchetAbiContract(dl, expectedAbiHash: expectedAbiHash);
  try {
    dl.lookup<NativeFunction<_VersionNative>>('veil_ratchet_state_version');
    return true;
  } catch (_) {
    return false;
  }
}

/// [RatchetStateHandle] over a `VeilHandle` — an IPC CLIENT connection to the
/// node, not the node handle.
///
/// This is not a detail. The store lives in the frame dispatcher's crypto, and
/// the FFI reaches it through the runtime bundle behind a connected handle; a
/// `VeilNode*` from `veil_node_start_deferred` is a different type and the
/// handle table rejects it outright ("use-after-close or unknown handle"). The
/// first version of this file passed the node handle, every call failed, and
/// nothing but a live node could have said so — a Dart model of the store
/// cannot be wrong about which pointer it is given.
///
/// Every call is synchronous and short: the store is an in-memory map behind a
/// lock, and the alternative — doing this off-isolate — would put the write
/// that must land BEFORE a send completes on the far side of a message queue.
class FfiRatchetStateHandle implements RatchetStateHandle {
  FfiRatchetStateHandle(this._handle, this._dl);

  /// Open a connection to the node's IPC socket and take the ratchet door on
  /// it. Null when this dylib has no ratchet door; throws when the node is not
  /// answering yet, and throws [VeilAbiContractMismatch] when the library is
  /// not the one these bindings were generated against — the contract check
  /// runs inside [ratchetStateAvailable], ahead of `veil_connect`, so no call
  /// is ever made through a mismatched ABI.
  ///
  /// [socketPath] is an ANCHOR, exactly as `VeilClient.connect` takes it: when
  /// its directory holds `ipc.port` / `ipc.token` sidecars the native side uses
  /// authenticated loopback TCP instead (the iOS path, where the sandbox's
  /// paths are longer than `sockaddr_un` allows).
  static FfiRatchetStateHandle? connect(
    String socketPath, {
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? processLibFor('veilclient_ffi');
    if (!ratchetStateAvailable(lib: dl)) return null;
    final connectFn = dl.lookupFunction<_ConnectNative, _ConnectDart>(
      'veil_connect',
    );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final bytes = utf8.encode(socketPath);
    final pathPtr = calloc<Uint8>(bytes.length);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      pathPtr.asTypedList(bytes.length).setAll(0, bytes);
      final handle = connectFn(pathPtr, bytes.length, errOut);
      if (handle == nullptr) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_connect (ratchet) failed: $msg');
      }
      return FfiRatchetStateHandle(handle, dl);
    } finally {
      calloc.free(pathPtr);
      calloc.free(errOut);
    }
  }

  final Pointer<Void> _handle;
  final DynamicLibrary _dl;
  bool _closed = false;

  /// Release the IPC connection. Idempotent.
  ///
  /// Its own connection rather than one borrowed from the transport, so it is
  /// closed on the way down like any other: the alternative was reaching into
  /// `VeilClient`'s private handle, and a borrowed handle whose owner closes
  /// first is a use-after-free on the send path.
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _dl.lookupFunction<_CloseNative, _CloseDart>('veil_close')(_handle);
  }

  String _takeErr(Pointer<Pointer<Utf8>> errOut) {
    final err = errOut.value;
    if (err == nullptr) return 'unknown error';
    final msg = err.toDartString();
    _dl.lookupFunction<_FreeStrNative, _FreeStrDart>('veil_free_string')(err);
    return msg;
  }

  @override
  int stateVersion() {
    final fn = _dl.lookupFunction<_VersionNative, _VersionDart>(
      'veil_ratchet_state_version',
    );
    final out = calloc<Uint64>();
    final errOut = calloc<Pointer<Utf8>>();
    try {
      final rc = fn(_handle, out, errOut);
      if (rc != 0) {
        throw StateError(
          'veil_ratchet_state_version failed: ${_takeErr(errOut)}',
        );
      }
      return out.value;
    } finally {
      calloc.free(out);
      calloc.free(errOut);
    }
  }

  @override
  ({List<Uint8List> keys, int remaining, int generation}) peekDirty(
    int maxKeys,
  ) {
    if (maxKeys <= 0) {
      throw ArgumentError.value(maxKeys, 'maxKeys', 'must be positive');
    }
    final fn = _dl.lookupFunction<_PeekDirtyNative, _PeekDirtyDart>(
      'veil_ratchet_peek_dirty',
    );
    final cap = maxKeys * kRatchetKeyLen;
    final buf = calloc<Uint8>(cap);
    final written = calloc<Size>();
    final remaining = calloc<Size>();
    final generation = calloc<Uint64>();
    final errOut = calloc<Pointer<Utf8>>();
    try {
      final rc = fn(_handle, buf, cap, written, remaining, generation, errOut);
      if (rc != 0) {
        throw StateError('veil_ratchet_peek_dirty failed: ${_takeErr(errOut)}');
      }
      return (
        keys: dirtyKeysFrom(buf.asTypedList(cap), written.value, maxKeys),
        remaining: remaining.value,
        generation: generation.value,
      );
    } finally {
      calloc.free(buf);
      calloc.free(written);
      calloc.free(remaining);
      calloc.free(generation);
      calloc.free(errOut);
    }
  }

  @override
  int ackDirty(List<Uint8List> keys, int generation) {
    if (keys.isEmpty) return 0;
    for (final key in keys) {
      _checkKey(key);
    }
    final fn = _dl.lookupFunction<_AckDirtyNative, _AckDirtyDart>(
      'veil_ratchet_ack_dirty',
    );
    final buf = calloc<Uint8>(keys.length * kRatchetKeyLen);
    final cleared = calloc<Size>();
    final errOut = calloc<Pointer<Utf8>>();
    try {
      final view = buf.asTypedList(keys.length * kRatchetKeyLen);
      for (var i = 0; i < keys.length; i++) {
        view.setAll(i * kRatchetKeyLen, keys[i]);
      }
      final rc = fn(_handle, buf, keys.length, generation, cleared, errOut);
      if (rc != 0) {
        throw StateError('veil_ratchet_ack_dirty failed: ${_takeErr(errOut)}');
      }
      return cleared.value;
    } finally {
      calloc.free(buf);
      calloc.free(cleared);
      calloc.free(errOut);
    }
  }

  @override
  List<Uint8List> list() {
    final fn = _dl.lookupFunction<_ListNative, _ListDart>('veil_ratchet_list');
    final total = calloc<Size>();
    final errOut = calloc<Pointer<Utf8>>();
    // Two passes when the first buffer is short. `list` consumes nothing, so
    // asking twice is free — unlike `take_dirty`, where a re-read would be a
    // second notice for conversations already accounted for.
    var cap = 64 * kRatchetKeyLen;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final buf = calloc<Uint8>(cap);
        try {
          final rc = fn(_handle, buf, cap, total, errOut);
          if (rc != 0) {
            throw StateError('veil_ratchet_list failed: ${_takeErr(errOut)}');
          }
          // A COUNT, like `take_dirty`'s — and used as one here, which is why
          // this call was never broken the way that one was.
          final held = total.value;
          if (held < 0) {
            throw StateError('veil_ratchet_list reported $held conversations');
          }
          if (held * kRatchetKeyLen <= cap) {
            return _splitKeys(buf, held * kRatchetKeyLen);
          }
          cap = held * kRatchetKeyLen;
        } finally {
          calloc.free(buf);
        }
      }
      throw StateError('veil_ratchet_list grew between two sizing passes');
    } finally {
      calloc.free(total);
      calloc.free(errOut);
    }
  }

  @override
  RatchetSendPosition? sendPosition(Uint8List conversationKey) {
    _checkKey(conversationKey);
    final fn = _dl.lookupFunction<_SendPositionNative, _SendPositionDart>(
      'veil_ratchet_send_position',
    );
    final keyPtr = calloc<Uint8>(kRatchetKeyLen);
    final chainPtr = calloc<Uint8>(32);
    final nextPtr = calloc<Uint32>();
    final errOut = calloc<Pointer<Utf8>>();
    try {
      keyPtr.asTypedList(kRatchetKeyLen).setAll(0, conversationKey);
      final rc = fn(_handle, keyPtr, chainPtr, nextPtr, errOut);
      if (rc == kVeilErrRatchetNoConversation) {
        // Nothing held, or nothing sealed yet. Either way there is no position
        // to record and nothing has been published under one.
        _takeErr(errOut);
        return null;
      }
      if (rc != 0) {
        throw StateError(
          'veil_ratchet_send_position failed: ${_takeErr(errOut)}',
        );
      }
      return RatchetSendPosition(
        Uint8List.fromList(chainPtr.asTypedList(32)),
        nextPtr.value,
      );
    } finally {
      calloc.free(keyPtr);
      // The chain is our own PUBLIC key, not key material — no wipe owed.
      calloc.free(chainPtr);
      calloc.free(nextPtr);
      calloc.free(errOut);
    }
  }

  @override
  int skipSendTo(Uint8List conversationKey, RatchetSendPosition to) {
    _checkKey(conversationKey);
    if (to.chain.length != 32) {
      throw ArgumentError.value(
        to.chain.length,
        'to.chain',
        'a sending chain is exactly 32 bytes',
      );
    }
    final fn = _dl.lookupFunction<_SkipSendNative, _SkipSendDart>(
      'veil_ratchet_skip_send_to',
    );
    final keyPtr = calloc<Uint8>(kRatchetKeyLen);
    final chainPtr = calloc<Uint8>(32);
    final burnedPtr = calloc<Uint32>();
    final errOut = calloc<Pointer<Utf8>>();
    try {
      keyPtr.asTypedList(kRatchetKeyLen).setAll(0, conversationKey);
      chainPtr.asTypedList(32).setAll(0, to.chain);
      final rc = fn(_handle, keyPtr, chainPtr, to.next, burnedPtr, errOut);
      if (rc == kVeilErrRatchetNoConversation) {
        // A recorded position for a conversation that is gone — deleted, or
        // never restored. Nothing to step, and nothing wrong.
        _takeErr(errOut);
        return 0;
      }
      if (rc != 0) {
        throw StateError(
          'veil_ratchet_skip_send_to failed: ${_takeErr(errOut)}',
        );
      }
      return burnedPtr.value;
    } finally {
      calloc.free(keyPtr);
      calloc.free(chainPtr);
      calloc.free(burnedPtr);
      calloc.free(errOut);
    }
  }

  @override
  Uint8List? export(Uint8List conversationKey) {
    _checkKey(conversationKey);
    final fn = _dl.lookupFunction<_ExportNative, _ExportDart>(
      'veil_ratchet_export',
    );
    final keyPtr = calloc<Uint8>(kRatchetKeyLen);
    // BYTES here, unlike `take_dirty` and `list` — `veil_ratchet_export`
    // documents `*out_len` as a length, and it is used as one.
    final outLen = calloc<Size>();
    final errOut = calloc<Pointer<Utf8>>();
    Pointer<Uint8> buf = nullptr;
    var cap = 4096;
    try {
      keyPtr.asTypedList(kRatchetKeyLen).setAll(0, conversationKey);
      for (var attempt = 0; attempt < 2; attempt++) {
        buf = calloc<Uint8>(cap);
        final rc = fn(_handle, keyPtr, buf, cap, outLen, errOut);
        if (rc == kVeilErrRatchetNoConversation) {
          _takeErr(errOut);
          return null;
        }
        if (rc == kVeilErrRatchetBufferTooSmall) {
          _takeErr(errOut);
          // `*out_len` carries the size required, and nothing was written or
          // consumed, so the retry sees the same state.
          cap = outLen.value;
          if (cap <= 0 || cap > kRatchetMaxStateLen) {
            throw StateError('veil_ratchet_export asked for $cap bytes');
          }
          // Nothing was written into this one, so there is nothing to wipe.
          calloc.free(buf);
          buf = nullptr;
          continue;
        }
        if (rc != 0) {
          throw StateError('veil_ratchet_export failed: ${_takeErr(errOut)}');
        }
        final len = outLen.value;
        if (len < 0 || len > cap) {
          throw StateError('veil_ratchet_export wrote $len into $cap bytes');
        }
        return Uint8List.fromList(buf.asTypedList(len));
      }
      throw StateError('veil_ratchet_export grew between two sizing passes');
    } finally {
      // The buffer held a whole session. Zero it before the allocator can hand
      // the block on (audit XV-22) — this is the largest plaintext copy of that
      // key material in the process.
      if (buf != nullptr) {
        wipeNativeSecret(buf, cap);
        calloc.free(buf);
      }
      calloc.free(keyPtr);
      calloc.free(outLen);
      calloc.free(errOut);
    }
  }

  @override
  bool import(Uint8List conversationKey, Uint8List blob) {
    _checkKey(conversationKey);
    if (blob.isEmpty || blob.length > kRatchetMaxStateLen) return false;
    final fn = _dl.lookupFunction<_ImportNative, _ImportDart>(
      'veil_ratchet_import',
    );
    final keyPtr = calloc<Uint8>(kRatchetKeyLen);
    final blobPtr = calloc<Uint8>(blob.length);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      keyPtr.asTypedList(kRatchetKeyLen).setAll(0, conversationKey);
      blobPtr.asTypedList(blob.length).setAll(0, blob);
      final rc = fn(_handle, keyPtr, blobPtr, blob.length, errOut);
      if (rc != 0) {
        // The message names the conversation, never the bytes — veil's own
        // wording is "ratchet state rejected", with no blob in it.
        _takeErr(errOut);
        return false;
      }
      return true;
    } finally {
      wipeNativeSecret(blobPtr, blob.length);
      calloc.free(blobPtr);
      calloc.free(keyPtr);
      calloc.free(errOut);
    }
  }

  @override
  bool forget(Uint8List conversationKey) {
    _checkKey(conversationKey);
    final fn = _dl.lookupFunction<_ForgetNative, _ForgetDart>(
      'veil_ratchet_forget',
    );
    final keyPtr = calloc<Uint8>(kRatchetKeyLen);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      keyPtr.asTypedList(kRatchetKeyLen).setAll(0, conversationKey);
      final rc = fn(_handle, keyPtr, errOut);
      if (rc == kVeilErrRatchetNoConversation) {
        _takeErr(errOut);
        return false;
      }
      if (rc != 0) {
        throw StateError('veil_ratchet_forget failed: ${_takeErr(errOut)}');
      }
      return true;
    } finally {
      calloc.free(keyPtr);
      calloc.free(errOut);
    }
  }

  @override
  int expire() {
    final fn = _dl.lookupFunction<_ExpireNative, _ExpireDart>(
      'veil_ratchet_expire',
    );
    final droppedOut = calloc<Size>();
    final errOut = calloc<Pointer<Utf8>>();
    try {
      final rc = fn(_handle, droppedOut, errOut);
      if (rc != 0) {
        throw StateError('veil_ratchet_expire failed: ${_takeErr(errOut)}');
      }
      return droppedOut.value;
    } finally {
      calloc.free(droppedOut);
      calloc.free(errOut);
    }
  }

  static void _checkKey(Uint8List key) {
    if (key.length != kRatchetKeyLen) {
      throw ArgumentError.value(
        key.length,
        'conversationKey',
        'a conversation key is exactly $kRatchetKeyLen bytes',
      );
    }
  }

  static List<Uint8List> _splitKeys(Pointer<Uint8> buf, int bytes) {
    final view = buf.asTypedList(bytes);
    return [
      for (var i = 0; i + kRatchetKeyLen <= bytes; i += kRatchetKeyLen)
        Uint8List.fromList(view.sublist(i, i + kRatchetKeyLen)),
    ];
  }
}

/// Read every stored conversation out of [storage].
///
/// Split from [importRatchetStates] because the boot cannot do them together:
/// the read is async and the import has to happen inside the synchronous window
/// where the node exists and nothing can reach it yet.
Future<List<RatchetStateEntry>> loadStoredRatchetStates(Storage storage) async {
  final out = <RatchetStateEntry>[];
  for (final key in await storage.ratchetConversationKeys()) {
    final blob = await storage.loadRatchetState(key);
    // Nothing complete under that key. Reported as rejected below so the dead
    // records go, rather than being re-read on every launch forever.
    if (blob == null) {
      out.add(RatchetStateEntry(key, Uint8List(0)));
      continue;
    }
    out.add(RatchetStateEntry(key, blob));
  }
  return out;
}

/// Hand [entries] back to veil. Returns the keys it would not take.
///
/// A null [handle] means this build has no ratchet door at all, which is not a
/// failure — it is a build whose one-to-one messages are not ratcheted. Nothing
/// is rejected in that case, because nothing was offered.
List<Uint8List> importRatchetStates(
  RatchetStateHandle? handle,
  List<RatchetStateEntry> entries,
) {
  if (handle == null || entries.isEmpty) return const [];
  final rejected = <Uint8List>[];
  for (final entry in entries) {
    if (entry.blob.isEmpty ||
        !handle.import(entry.conversationKey, entry.blob)) {
      rejected.add(entry.conversationKey);
    }
  }
  // COUNTS only. The keys are not secret in themselves, but a log line naming
  // which conversations this device holds is a contact list written somewhere
  // the container was supposed to keep it out of.
  devLog(
    () =>
        'xVeil[ratchet]: restored ${entries.length - rejected.length} '
        'conversation(s), ${rejected.length} unusable',
  );
  return rejected;
}

/// Remove state veil refused. It can never open a frame again, and keeping
/// unusable key material is the opposite of what this store is for.
Future<void> dropRejectedRatchetStates(
  Storage storage,
  List<Uint8List> rejected,
) async {
  if (rejected.isEmpty) return;
  await storage.forgetRatchetStates(rejected);
}

/// Load, import, and drop whatever veil refused. Returns how many were
/// The settings key a conversation's send reservation is written under.
///
/// Lives beside the reader rather than the writer: the startup recovery reads
/// what the send path writes, and a format known in two places is a format
/// that drifts.
String ratchetReservationKey(Uint8List conversationKey) =>
    'ratchet_reserve:${[for (final b in conversationKey) b.toRadixString(16).padLeft(2, '0')].join()}';

/// Step every restored conversation past the indices its last reservation
/// allowed, and report how many keys were burned in total.
///
/// A STARTUP step, run after the stored states are handed back to veil and
/// before this app's traffic starts. A conversation whose state reached disk
/// is already at or past its reservation and moves nothing; one whose last
/// write never landed is fast-forwarded over every index it might already have
/// spent on the wire (report12 X-H5).
///
/// Free-standing rather than a method because the one caller that matters runs
/// where the stack is built — the same place [importRatchetStates] runs — and
/// has the node handle and the storage but no [RatchetPersistence] yet.
Future<int> recoverReservedSendPositions(
  RatchetStateHandle native,
  Storage storage,
) async {
  var burned = 0;
  for (final key in native.list()) {
    final raw = await storage.getSetting(
      ratchetReservationKey(key),
    );
    if (raw == null) continue;
    final at = raw.lastIndexOf(':');
    if (at <= 0) continue;
    final chain = _unhexChain(raw.substring(0, at));
    final next = int.tryParse(raw.substring(at + 1));
    if (chain == null || next == null) continue;
    burned += native.skipSendTo(key, RatchetSendPosition(chain, next));
  }
  if (burned > 0) {
    devLog(
      () =>
          'xVeil[ratchet]: burned $burned send key(s) a reservation says may '
          'already be on the wire',
    );
  }
  return burned;
}

Uint8List? _unhexChain(String hex) {
  if (hex.length != 64) return null;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    final b = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}

/// restored.
Future<int> restoreRatchetStates(
  RatchetStateHandle handle,
  Storage storage,
) async {
  final entries = await loadStoredRatchetStates(storage);
  final rejected = importRatchetStates(handle, entries);
  await dropRejectedRatchetStates(storage, rejected);
  return entries.length - rejected.length;
}

/// Export every conversation in [keys], skipping any veil no longer holds.
///
/// Shared by the after-every-operation flush and the shutdown save so the two
/// cannot disagree about what "the state of these conversations" means.
List<RatchetStateEntry> exportRatchetStates(
  RatchetStateHandle handle,
  Iterable<Uint8List> keys,
) {
  final out = <RatchetStateEntry>[];
  for (final key in keys) {
    final blob = handle.export(key);
    // A conversation named dirty and then forgotten between the two calls is
    // not an error: forget() is the host's own irreversible drop, and its
    // stored bytes go with it on the same pass.
    if (blob == null) continue;
    out.add(RatchetStateEntry(key, blob));
  }
  return out;
}
