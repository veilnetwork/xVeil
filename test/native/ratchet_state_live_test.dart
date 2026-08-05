import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart' show kRatchetKeyLen;
import 'package:xveil/state/ratchet_persistence.dart';

/// The ABI half of the ratchet store, which nothing else can check.
///
/// Every other test in this area runs against a faithful Dart model of veil's
/// store, and a model cannot be wrong about a `size_t` written where an
/// `intptr_t` was expected — it just reads back whatever the wrong slot held.
/// Six functions with eleven out-parameters between them is exactly the shape
/// where a typedef that does not match `veil_ffi.h` is silent, plausible, and
/// corrupts the one thing here that cannot be rebuilt.
///
/// This file used to exercise only the EMPTY store, and that is exactly why it
/// was green while nothing was being persisted at all: `take_dirty` reports a
/// COUNT OF KEYS, the host read it as a BYTE LENGTH, and with the standard
/// batch of 32 every non-empty answer is at most 32 against a 64-byte key — so
/// the split produced nothing, on a path that had already cleared the marks.
/// Zero keys and zero keys are the same answer when the store is empty. Every
/// test below therefore drives a NON-EMPTY store and asserts positively: this
/// many keys came back, this state reached the container, and the run after the
/// crash resumes at the NEXT message key rather than repeating one.
///
/// Env-gated:
///   VEIL_FFI_DYLIB = libveilclient_ffi built with `--features node-embedded`
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final skip = (dylib == null || dylib.isEmpty)
      ? 'set VEIL_FFI_DYLIB to a node-embedded libveilclient_ffi'
      : false;

  test('the ratchet door answers over the real ABI', () async {
    final lib = DynamicLibrary.open(dylib!);
    expect(
      ratchetStateAvailable(lib: lib),
      isTrue,
      reason: 'this dylib was built without the ratchet FFI',
    );

    final dir = await Directory.systemTemp.createTemp('xveil-ratchet-abi');
    final ipcSock = '${dir.path}/app.sock';
    final adminSock = '${dir.path}/admin.sock';
    final identityToml = EmbeddedNode.mineConfig(0, lib: lib);
    final config = EmbeddedNode.composeConfig(
      identityToml: identityToml,
      listenTransport: 'quic://127.0.0.1:9174',
      ipcSocket: ipcSock,
      adminSocket: adminSock,
      lib: lib,
    );
    final controller = EmbeddedNodeController(
      appSocketPath: ipcSock,
      starter: () {
        final node = EmbeddedNode.startDeferred(adminSock, lib: lib);
        node.applyConfig(config);
        return node;
      },
    );
    RatchetStateHandle? ratchet;
    try {
      await controller.start();
      expect(controller.current.phase, NodePhase.connected);

      // The connection this reaches the store through is an IPC CLIENT handle.
      // Passing the node handle from `startDeferred` — which is what the first
      // version of this code did — fails every call with "use-after-close or
      // unknown handle", and no amount of Dart-side modelling can catch that.
      final door = FfiRatchetStateHandle.connect(ipcSock, lib: lib);
      expect(door, isNotNull);
      ratchet = door!;

      // A node that has done nothing has committed nothing. If the u64 out-slot
      // were mis-typed this reads back stack garbage rather than zero.
      expect(ratchet.stateVersion(), 0);

      final dirty = ratchet.peekDirty(8);
      expect(dirty.keys, isEmpty);
      expect(dirty.remaining, 0);
      expect(ratchet.ackDirty(const [], dirty.generation), 0);
      expect(ratchet.list(), isEmpty);

      final unknown = Uint8List(kRatchetKeyLen)..fillRange(0, kRatchetKeyLen, 7);
      // VEIL_ERR_RATCHET_NO_CONVERSATION (-20) on both, decoded as "nothing
      // held" rather than thrown — the two calls the cleanup paths lean on.
      expect(ratchet.export(unknown), isNull);
      expect(ratchet.forget(unknown), isFalse);

      // "Rejects a blob it does not fully understand rather than salvaging part
      // of one." A partially-understood session is a session with the wrong
      // keys, and this is the answer the startup import treats as "drop it".
      expect(
        ratchet.import(unknown, Uint8List.fromList([1, 2, 3, 4])),
        isFalse,
      );
      expect(ratchet.list(), isEmpty);
      // Nothing above committed anything, so the counter still has not moved —
      // which is the property that lets a host tell "nothing happened" from
      // "something happened and I read it twice".
      expect(ratchet.stateVersion(), 0);

      expect(
        () => door.export(Uint8List(8)),
        throwsArgumentError,
        reason: 'a short key must never reach a 64-byte read',
      );
    } finally {
      ratchet?.close();
      await controller.stop();
      await dir.delete(recursive: true);
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

  test('a dirty list of 1, 2 and 32 comes back as KEYS, not as bytes', () async {
    final lib = DynamicLibrary.open(dylib!);
    final node = await _bootNode(lib, 9175);
    try {
      final door = node.door;

      // Thirty-two marked conversations — the batch the host actually asks for,
      // reached without a peer, a verified certificate and a DHT round.
      final keys = [for (var i = 0; i < 32; i++) _convKey(peerNode: i + 1)];
      for (final key in keys) {
        expect(
          _settledImport(() => door.import(key, _conversationBlob(sendingIndex: 1))),
          isTrue,
          reason: 'veil no longer accepts the blob this test builds — the '
              'persisted conversation format changed',
        );
      }
      expect(door.list(), hasLength(32));

      // The sweep, over the real ABI. Two things at once, and only a live node
      // can say either: that `veil_ratchet_expire` resolves and its `size_t *`
      // out-parameter is typed the way the header declares it, and that a
      // conversation this device has spoken on is never aged out. All 32 are
      // marked authenticated and stamped in 2023 — far past any time-to-live —
      // so a sweep that judged by age alone would take every one of them, and
      // both ends of all 32 conversations would be wedged for good.
      expect(
        door.expire(),
        0,
        reason: 'a proven conversation must not age out at any age',
      );
      expect(door.list(), hasLength(32));
      // `forget` is the store's own way of saying "this conversation changed":
      // it marks the key and drops the entry. The mark is what the batch loop
      // reads, and it outlives the entry, which is why the count below is 32
      // while nothing is held any more.
      for (final key in keys) {
        expect(_settled(() => door.forget(key)), isTrue);
      }
      expect(door.list(), isEmpty);

      // The whole defect in one line: with the count read as a byte length,
      // every one of these three answers is EMPTY — 1, 2 and 29 are all below
      // the 64 bytes one key takes.
      final seen = <String>[];
      final first = door.peekDirty(1);
      expect(first.keys, hasLength(1));
      expect(first.remaining, 31);
      seen.addAll(first.keys.map(_hex));

      // And reading the list is not what discharges it: the same call again
      // names the same work, because the marks stand until the bytes are down.
      final repeat = door.peekDirty(1);
      expect(repeat.keys.map(_hex), first.keys.map(_hex));
      expect(repeat.remaining, 31);
      expect(door.ackDirty(first.keys, first.generation), 1);

      final second = door.peekDirty(2);
      expect(second.keys, hasLength(2));
      expect(second.remaining, 29);
      seen.addAll(second.keys.map(_hex));
      expect(door.ackDirty(second.keys, second.generation), 2);

      final rest = door.peekDirty(32);
      expect(rest.keys, hasLength(29));
      expect(rest.remaining, 0);
      seen.addAll(rest.keys.map(_hex));
      expect(door.ackDirty(rest.keys, rest.generation), 29);

      // Every key, once, and byte-identical to what went in: a split at the
      // wrong stride would still return the right COUNT of 64-byte slices while
      // naming conversations nobody holds.
      expect(seen.toSet(), hasLength(32));
      expect(seen.toSet(), keys.map(_hex).toSet());
      for (final key in [...first.keys, ...second.keys, ...rest.keys]) {
        expect(key, hasLength(kRatchetKeyLen));
      }
      // Acknowledged means acknowledged.
      expect(door.peekDirty(32).keys, isEmpty);

      // And an acknowledgement that predates a change does not cover it. This
      // conversation moves after the read; the bytes the host is writing are
      // from before the move, so its mark has to survive them — or the state
      // that reaches the next launch is the one from before, on a chain the
      // peer has already advanced.
      final moving = _convKey(peerNode: 200);
      expect(
        _settledImport(() => door.import(moving, _conversationBlob(sendingIndex: 1))),
        isTrue,
      );
      expect(_settled(() => door.forget(moving)), isTrue);
      final inFlight = door.peekDirty(32);
      expect(inFlight.keys.map(_hex), [_hex(moving)]);
      expect(
        _settledImport(() => door.import(moving, _conversationBlob(sendingIndex: 2))),
        isTrue,
      );
      expect(_settled(() => door.forget(moving)), isTrue);
      expect(
        door.ackDirty(inFlight.keys, inFlight.generation),
        0,
        reason: 'a stale acknowledgement cleared a live mark',
      );
      expect(door.peekDirty(32).keys.map(_hex), [_hex(moving)]);
    } finally {
      await node.dispose();
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

  test(
    'after a crash the run resumes at the NEXT message key, not a repeat',
    () async {
      final lib = DynamicLibrary.open(dylib!);
      final node = await _bootNode(lib, 9176);
      final store = FakeKvLogStore();
      final storage = HiddenVolumeStorage(
        ({required Uint8List password, required bool create}) =>
            password.isEmpty ? null : store,
      );
      await storage.open(password: 'pw', createIfMissing: true);
      try {
        final door = node.door;
        final key = _convKey(peerNode: 9);
        final persistence = RatchetPersistence(native: door, storage: storage);

        // An established conversation, seven message keys of the sending chain
        // already burned, and the write for that state landed.
        expect(_settledImport(() => door.import(key, _conversationBlob(sendingIndex: 7))), isTrue);
        expect(_settled(() => door.forget(key)), isTrue);
        expect(_settledImport(() => door.import(key, _conversationBlob(sendingIndex: 7))), isTrue);
        expect(
          await persistence.flush(),
          1,
          reason: 'the flush after an operation must write exactly the one '
              'conversation that changed',
        );
        expect(
          _sendingIndexOf((await storage.loadRatchetState(key))!),
          7,
          reason: 'nothing reached the container',
        );

        // One more send. The chain advances to 8: message key 7 is spent and
        // will never be produced again by a correct run.
        expect(_settled(() => door.forget(key)), isTrue);
        expect(_settledImport(() => door.import(key, _conversationBlob(sendingIndex: 8))), isTrue);
        expect(await persistence.flush(), 1);

        // The process dies here — force-stop, OOM, OS kill. Nothing in veil
        // survives; only the container does, which is the entire point of it.
        expect(_settled(() => door.forget(key)), isTrue);
        expect(door.list(), isEmpty);
        final leftover = door.peekDirty(32);
        door.ackDirty(leftover.keys, leftover.generation);

        expect(await RatchetPersistence(native: door, storage: storage).restore(), 1);
        final resumed = _sendingIndexOf(door.export(key)!);
        expect(
          resumed,
          8,
          reason: 'the run after the crash must continue the sending chain',
        );
        expect(
          resumed,
          isNot(7),
          reason: 'resuming at 7 re-derives a message key that was already '
              'used: one ChaCha20-Poly1305 key and nonce for two plaintexts, '
              'and one Poly1305 one-time key for two tags',
        );
      } finally {
        await storage.close();
        await node.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// A node with its ratchet door open, and the one call that puts it all away.
class _LiveNode {
  _LiveNode(this.door, this._controller, this._dir);

  final RatchetStateHandle door;
  final EmbeddedNodeController _controller;
  final Directory _dir;

  Future<void> dispose() async {
    door.close();
    await _controller.stop();
    await _dir.delete(recursive: true);
  }
}

Future<_LiveNode> _bootNode(DynamicLibrary lib, int port) async {
  final dir = await Directory.systemTemp.createTemp('xveil-ratchet-abi');
  final ipcSock = '${dir.path}/app.sock';
  final adminSock = '${dir.path}/admin.sock';
  final config = EmbeddedNode.composeConfig(
    identityToml: EmbeddedNode.mineConfig(0, lib: lib),
    listenTransport: 'quic://127.0.0.1:$port',
    ipcSocket: ipcSock,
    adminSocket: adminSock,
    lib: lib,
  );
  final controller = EmbeddedNodeController(
    appSocketPath: ipcSock,
    starter: () {
      final node = EmbeddedNode.startDeferred(adminSock, lib: lib);
      node.applyConfig(config);
      return node;
    },
  );
  await controller.start();
  expect(controller.current.phase, NodePhase.connected);
  final door = FfiRatchetStateHandle.connect(ipcSock, lib: lib);
  expect(door, isNotNull);
  // Every call through this door is an IPC round trip, and a node that has just
  // reported `connected` is still bringing its rendezvous leg up. Ask it
  // something trivial until it answers three times running, so a burst of
  // set-up calls does not run into the one reply that misses its timeout.
  for (var settled = 0; settled < 3;) {
    settled = _settled(() {
      door!.stateVersion();
      return settled + 1;
    });
  }
  return _LiveNode(door!, controller, dir);
}

/// Run [op] until the node answers, for set-up work only.
///
/// A missed `node_identity` reply is a property of a node still starting up,
/// not of the thing this file checks — so the SET-UP retries and none of the
/// assertions do. Anything under test is called exactly once.
T _settled<T>(T Function() op) {
  Object? last;
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      return op();
    } catch (e) {
      last = e;
      sleep(const Duration(milliseconds: 250));
    }
  }
  throw StateError('the node never answered in 10 attempts: $last');
}

/// [_settled] for `import`, which reports "the node did not answer" and "the
/// blob was refused" as the same `false` and so has to retry on both.
bool _settledImport(bool Function() op) {
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      if (op()) return true;
    } catch (_) {
      // Same treatment: retry, and let the caller's expect name the failure.
    }
    sleep(const Duration(milliseconds: 250));
  }
  return false;
}

/// `our device (16) ‖ their node (32) ‖ their device (16)`.
Uint8List _convKey({required int peerNode}) {
  final out = Uint8List(kRatchetKeyLen);
  out.fillRange(0, 16, 3);
  out.fillRange(16, 48, peerNode);
  out.fillRange(48, 64, 1);
  return out;
}

String _hex(Uint8List k) =>
    [for (final b in k) b.toRadixString(16).padLeft(2, '0')].join();

/// Bytes past which the sending counter sits, inside a blob [_conversationBlob]
/// built: `VRC1` header, then the primitive's `VSR1` header.
const int _sendingIndexOffset =
    // VRC1 ‖ v2 ‖ peer_ik(32) ‖ authenticated ‖ last_used_at(8) ‖ no prologue
    // ‖ session length
    4 + 1 + 32 + 1 + 8 + 1 + 4 +
    // VSR1 ‖ v1 ‖ dh_sk(32) ‖ Some(32) ‖ rk(32) ‖ Some(32) ‖ Some(32)
    4 + 1 + 32 + 33 + 32 + 33 + 33;

/// A conversation veil will take back, whose sending chain stands at
/// [sendingIndex].
///
/// Both of veil's parsers for this — the `VRC1` wrapper and the primitive's
/// `VSR1` state — are pure structure: tags, lengths and option flags, with
/// nothing bound to the key material inside. That is what lets a conversation
/// be stood up here without a peer, a verified certificate and a DHT round, and
/// the `import` calls above assert veil still accepts it, so a change to either
/// format fails this file loudly instead of quietly reducing it to the empty
/// case it used to be.
Uint8List _conversationBlob({required int sendingIndex}) {
  final session = BytesBuilder()
    ..add(const [0x56, 0x53, 0x52, 0x31]) // "VSR1"
    ..addByte(1) // STATE_V1
    ..add(Uint8List(32)..fillRange(0, 32, 0x11)) // dh_sk
    ..addByte(1)
    ..add(Uint8List(32)..fillRange(0, 32, 0x22)) // dh_pk_remote
    ..add(Uint8List(32)..fillRange(0, 32, 0x33)) // rk
    ..addByte(1)
    ..add(Uint8List(32)..fillRange(0, 32, 0x44)) // cks
    ..addByte(1)
    ..add(Uint8List(32)..fillRange(0, 32, 0x55)) // ckr
    ..add(_u32(sendingIndex)) // ns — the next message key of the sending chain
    ..add(_u32(0)) // nr
    ..add(_u32(0)) // pn
    ..addByte(1) // sent_any
    ..add(_u32(0)) // no skipped message keys banked
    ..add(Uint8List(64)..fillRange(0, 64, 0x66)) // pq_seed
    ..addByte(0); // no pending ML-KEM ciphertext
  final sessionBytes = session.toBytes();

  final entry = BytesBuilder()
    ..add(const [0x56, 0x52, 0x43, 0x31]) // "VRC1"
    ..addByte(2) // CONVERSATION_BLOB_V2
    ..add(Uint8List(32)..fillRange(0, 32, 0x77)) // peer_ik
    ..addByte(1) // authenticated
    // last_used_at, big-endian seconds. v2 carries it so the store can age out
    // conversations nobody ever answered; a proven one like this is never aged
    // out at any value, which is why a fixed stamp is safe here.
    ..add(_u64(1_700_000_000))
    ..addByte(0) // no pending prologue
    ..add(_u32(sessionBytes.length))
    ..add(sessionBytes);
  return entry.toBytes();
}

int _sendingIndexOf(Uint8List blob) {
  const at = _sendingIndexOffset;
  expect(
    blob.length,
    greaterThan(at + 4),
    reason: 'not a conversation blob this test understands',
  );
  return (blob[at] << 24) | (blob[at + 1] << 16) | (blob[at + 2] << 8) |
      blob[at + 3];
}

Uint8List _u32(int v) => Uint8List.fromList([
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
]);

Uint8List _u64(int v) => Uint8List.fromList([
  (v >> 56) & 0xff,
  (v >> 48) & 0xff,
  (v >> 40) & 0xff,
  (v >> 32) & 0xff,
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
]);
