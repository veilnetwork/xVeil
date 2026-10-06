import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/state/ratchet_persistence.dart';

/// The state behind a published ciphertext is written AFTER the frame goes out,
/// and that write can fail. A restart then brings back the state from before
/// the send, and the next message re-derives the key and nonce that frame
/// already used — for different plaintext. Two ciphertexts under one nonce hand
/// anyone who sees both the XOR of their plaintexts (report12 X-H5).
///
/// The state runs to kilobytes and is far too big to write before publishing.
/// The POSITION is 36 bytes, so the send path reserves a run of indices durably
/// and the startup recovery steps over every one that might have been spent.

/// A node just rich enough for this file. Deliberately not shared with
/// `ratchet_persistence_test.dart`: extracting that file's larger double drags
/// its private helpers along, and the risk of disturbing a suite that size is
/// worse than a small second double kept honest here.
///
/// Honest means: no more permissive than the real one. A position from another
/// chain, or one already passed, burns nothing.
class _Node implements RatchetStateHandle {
  final Map<String, ({int sent, Uint8List blob})> _held = {};
  final Map<String, Uint8List> _chains = {};
  final Map<String, int> _dirty = {};
  int _version = 0;

  static String _hex(Uint8List k) =>
      [for (final b in k) b.toRadixString(16).padLeft(2, '0')].join();
  static Uint8List _chainOf(String hex) => Uint8List.fromList(
    List<int>.generate(32, (i) => hex.codeUnitAt(i % hex.length) & 0xff),
  );

  /// Seal one frame and return the index it burned.
  int seal(Uint8List key) {
    final hex = _hex(key);
    final held = _held[hex] ?? (sent: 0, blob: Uint8List(0));
    final index = held.sent;
    _held[hex] = (sent: index + 1, blob: held.blob);
    _version++;
    _dirty[hex] = _version;
    return index;
  }

  void rotate(Uint8List key, int tag) {
    final hex = _hex(key);
    _chains[hex] = Uint8List(32)..fillRange(0, 32, tag);
    _held[hex] = (sent: 0, blob: Uint8List(0));
    _dirty[hex] = ++_version;
  }

  @override
  RatchetSendPosition? sendPosition(Uint8List key) {
    final held = _held[_hex(key)];
    if (held == null) return null;
    return RatchetSendPosition(
      _chains[_hex(key)] ?? _chainOf(_hex(key)),
      held.sent,
    );
  }

  @override
  List<RatchetSendPosition> sendPositions(Uint8List key) => [
    ?sendPosition(key),
  ];

  @override
  List<RatchetSendPosition> storedSendPositions(Uint8List key, Uint8List blob) {
    if (blob.length != 34) throw StateError('invalid fake state');
    return [
      RatchetSendPosition(
        Uint8List.fromList(blob.sublist(2)),
        blob[0] | (blob[1] << 8),
      ),
    ];
  }

  @override
  int skipSendTo(Uint8List key, RatchetSendPosition to) {
    final hex = _hex(key);
    final held = _held[hex];
    if (held == null) return 0;
    if (!_same(to.chain, _chains[hex] ?? _chainOf(hex)) ||
        to.next <= held.sent) {
      return 0;
    }
    final burned = to.next - held.sent;
    _held[hex] = (sent: to.next, blob: held.blob);
    _version++;
    _dirty[hex] = _version;
    return burned;
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int stateVersion() => _version;

  @override
  ({List<Uint8List> keys, int remaining, int generation}) peekDirty(int max) {
    final named = (_dirty.keys.toList()..sort()).take(max).toList();
    return (
      keys: [for (final k in named) _unhex(k)],
      remaining: _dirty.length - named.length,
      generation: _version,
    );
  }

  @override
  int ackDirty(List<Uint8List> keys, int generation) {
    var cleared = 0;
    for (final k in keys) {
      final marked = _dirty[_hex(k)];
      if (marked == null || marked > generation) continue;
      _dirty.remove(_hex(k));
      cleared++;
    }
    return cleared;
  }

  /// How many times the whole conversation set has been copied out. The
  /// reservation runs on EVERY send, and this is an FFI call in production.
  int listCalls = 0;

  @override
  List<Uint8List> list() {
    listCalls++;
    return [for (final k in _held.keys) _unhex(k)];
  }

  @override
  Uint8List? export(Uint8List key) {
    final held = _held[_hex(key)];
    if (held == null) return null;
    // The sent counter IS the state, for this double's purposes.
    return Uint8List.fromList([
      held.sent & 0xff,
      (held.sent >> 8) & 0xff,
      ...(_chains[_hex(key)] ?? _chainOf(_hex(key))),
    ]);
  }

  @override
  bool import(Uint8List key, Uint8List blob) {
    if (blob.length != 34) return false;
    _held[_hex(key)] = (sent: blob[0] | (blob[1] << 8), blob: blob);
    _chains[_hex(key)] = Uint8List.fromList(blob.sublist(2));
    return true;
  }

  @override
  bool forget(Uint8List key) => _held.remove(_hex(key)) != null;

  @override
  int expire() => 0;

  @override
  void close() {}

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List _convKey({
  required int local,
  required int peerNode,
  int peerInstance = 0,
}) {
  // The peer's node id sits at [kRatchetKeyPeerNodeOffset] and OVERLAPS the
  // local part, so it is written second and wholly. Filling both in one loop
  // let the local bytes land back on top of the first half of the peer id,
  // and `_peerNodeMatches` then found nothing.
  final out = Uint8List(kRatchetKeyLen)..fillRange(0, kRatchetKeyLen, local);
  for (var i = 0; i < 32; i++) {
    out[kRatchetKeyPeerNodeOffset + i] = peerNode;
  }
  // The peer's DEVICE instance is the tail, past the node id — what makes two
  // conversations with one correspondent distinct.
  for (var i = kRatchetKeyPeerNodeOffset + 32; i < kRatchetKeyLen; i++) {
    out[i] = peerInstance;
  }
  return out;
}

void main() {
  late HiddenVolumeStorage storage;
  final peer = NodeId(Uint8List.fromList(List.filled(32, 2)));
  final key = _convKey(local: 1, peerNode: 2);

  setUp(() async {
    storage = HiddenVolumeStorage(
      ({required password, required bool create}) => FakeKvLogStore(),
    );
    await storage.open(password: 'pw', createIfMissing: true);
  });

  test(
    'a send whose state never reached disk cannot reuse its index',
    () async {
      final node = _Node();
      final ratchet = RatchetPersistence(native: node, storage: storage);

      // A conversation exists and its state IS on disk.
      node.seal(key);
      await ratchet.flush(why: 'setup');

      // The send path takes a reservation, and four frames go out under it.
      await ratchet.reserveBeforePublish(peer);
      final published = [for (var i = 0; i < 4; i++) node.seal(key)];
      expect(published, [1, 2, 3, 4]);

      // Their state write never lands and the process dies. A fresh node comes
      // up and is handed what the container actually holds.
      final restarted = _Node();
      await RatchetPersistence(native: restarted, storage: storage).restore();
      expect(
        restarted.sendPosition(key)!.next,
        1,
        reason: 'the restored state is the one from BEFORE the four sends',
      );

      final burned = await recoverReservedSendPositions(restarted, storage);
      expect(
        burned,
        greaterThan(0),
        reason: 'the reservation must be honoured',
      );

      final afterRestart = restarted.seal(key);
      for (final index in published) {
        expect(
          afterRestart,
          isNot(index),
          reason:
              'index $index was already published; sealing at it again is two '
              'ciphertexts under one nonce',
        );
      }
    },
  );

  test(
    'a chain change cannot erase the reservation for the disk state',
    () async {
      final node = _Node();
      final ratchet = RatchetPersistence(native: node, storage: storage);
      node.seal(key);
      await ratchet.flush(why: 'setup');
      final old = node.sendPosition(key)!;
      await ratchet.reserveBeforePublish(peer);
      final published = [for (var i = 0; i < 4; i++) node.seal(key)];
      node.rotate(key, 91);
      await ratchet.reserveBeforePublish(peer);
      node.seal(key);
      // Both post-send state writes are lost, including the chain change.
      final restarted = _Node();
      await RatchetPersistence(native: restarted, storage: storage).restore();
      expect(restarted.sendPosition(key)!.chain, old.chain);
      await recoverReservedSendPositions(restarted, storage);
      expect(restarted.seal(key), greaterThan(published.last));
    },
  );

  test(
    'many volatile epochs retain the disk mark within the ledger bound',
    () async {
      final node = _Node();
      final ratchet = RatchetPersistence(native: node, storage: storage);
      node.seal(key);
      await ratchet.flush(why: 'setup');
      final diskChain = node.sendPosition(key)!.chain;
      await ratchet.reserveBeforePublish(peer);
      node.seal(key);
      for (var tag = 1; tag <= 200; tag++) {
        node.rotate(key, tag);
        await ratchet.reserveBeforePublish(peer);
        final marks = decodeRatchetReservations(
          await storage.getSetting(ratchetReservationKey(key)),
        );
        expect(marks.length, 2);
        expect(marks.first.chain, diskChain);
        node.seal(key);
      }
      final restarted = _Node();
      await RatchetPersistence(native: restarted, storage: storage).restore();
      await recoverReservedSendPositions(restarted, storage);
      expect(restarted.seal(key), greaterThan(1));
    },
  );

  test('retire an old mark only after the new snapshot is durable', () async {
    final node = _Node();
    final ratchet = RatchetPersistence(native: node, storage: storage);
    node.seal(key);
    await ratchet.flush(why: 'setup');
    await ratchet.reserveBeforePublish(peer);
    node.rotate(key, 91);
    await ratchet.reserveBeforePublish(peer);
    node.seal(key);
    await ratchet.flush(why: 'new chain saved');
    node.rotate(key, 92);
    await ratchet.reserveBeforePublish(peer);
    final marks = decodeRatchetReservations(
      await storage.getSetting(ratchetReservationKey(key)),
    );
    expect(marks.map((m) => m.chain.first), [91, 92]);
    final restarted = _Node();
    await RatchetPersistence(native: restarted, storage: storage).restore();
    expect(restarted.sendPosition(key)!.chain.first, 91);
    await recoverReservedSendPositions(restarted, storage);
    expect(restarted.seal(key), greaterThan(0));
  });

  test('legacy marks migrate; malformed marks prevent publication', () async {
    final node = _Node();
    final ratchet = RatchetPersistence(native: node, storage: storage);
    node.seal(key);
    await ratchet.flush(why: 'setup');
    final old = node.sendPosition(key)!;
    final legacy = encodeRatchetReservations([
      RatchetSendPosition(old.chain, 33),
    ]);
    expect(legacy, isNot(startsWith('v2|')));
    await storage.putSetting(ratchetReservationKey(key), legacy);
    node.rotate(key, 91);
    await ratchet.reserveBeforePublish(peer);
    expect(
      decodeRatchetReservations(
        await storage.getSetting(ratchetReservationKey(key)),
      ).length,
      2,
    );
    await storage.putSetting(ratchetReservationKey(key), 'v2|corrupt');
    node.rotate(key, 92);
    await expectLater(ratchet.reserveBeforePublish(peer), throwsStateError);
    await expectLater(
      recoverReservedSendPositions(node, storage),
      throwsStateError,
    );
  });

  test('writers over one container share reservation retirement', () async {
    final oldNode = _Node();
    final oldWriter = RatchetPersistence(native: oldNode, storage: storage);
    oldNode.seal(key);
    await oldWriter.flush(why: 'setup');
    await oldWriter.reserveBeforePublish(peer);
    final oldChain = oldNode.sendPosition(key)!.chain;
    oldNode.seal(key);
    final replacement = _Node();
    replacement.rotate(key, 91);
    final newWriter = RatchetPersistence(native: replacement, storage: storage);
    await newWriter.reserveBeforePublish(peer);
    replacement.seal(key);
    await newWriter.flush(why: 'replacement saved');
    replacement.rotate(key, 92);
    await newWriter.reserveBeforePublish(peer);
    var marks = decodeRatchetReservations(
      await storage.getSetting(ratchetReservationKey(key)),
    );
    expect(marks.map((m) => m.chain.first), [91, 92]);
    // The retiring writer still has work. Its own earlier cache must not
    // claim a mark that the replacement has since safely retired.
    await oldWriter.reserveBeforePublish(peer);
    marks = decodeRatchetReservations(
      await storage.getSetting(ratchetReservationKey(key)),
    );
    expect(marks.any((m) => _Node._same(m.chain, oldChain)), isTrue);
    expect(marks.any((m) => m.chain.first == 91), isTrue);
  });

  test(
    'invalid durable metadata does not erase earlier reservations',
    () async {
      final node = _Node();
      final ratchet = RatchetPersistence(native: node, storage: storage);
      node.seal(key);
      await ratchet.flush(why: 'setup');
      await ratchet.reserveBeforePublish(peer);
      final before = await storage.getSetting(ratchetReservationKey(key));
      await storage.saveRatchetStates([RatchetStateEntry(key, Uint8List(3))]);
      node.rotate(key, 91);
      await expectLater(ratchet.reserveBeforePublish(peer), throwsStateError);
      expect(await storage.getSetting(ratchetReservationKey(key)), before);
    },
  );

  test('the reservation writes once per run, not once per send', () async {
    // What the reservation amortises is the durable WRITE. It used to also
    // cache the conversation list, and that cache was the X14-H3 hole: keyed
    // by the peer, it covered the first device forever. Listing is cheap —
    // 64 bytes per conversation held — and is now done every time; this pins
    // the part that is actually expensive.
    final node = _Node();
    final ratchet = RatchetPersistence(native: node, storage: storage);
    node.seal(key);
    await ratchet.flush(why: 'setup');

    await ratchet.reserveBeforePublish(peer);
    final first = await storage.getSetting(ratchetReservationKey(key));
    expect(first, isNotNull);

    for (var i = 0; i < RatchetPersistence.reserveAhead ~/ 2; i++) {
      node.seal(key);
      await ratchet.reserveBeforePublish(peer);
    }
    expect(
      await storage.getSetting(ratchetReservationKey(key)),
      first,
      reason: 'these sends are inside the run already on disk',
    );
  });

  test('a second device of the same peer is reserved too', () async {
    // A conversation key is `local instance || peer node || peer instance`, so
    // one peer has one per device. A cache keyed only by the PEER answered for
    // device A forever, and the conversation with device B — a second phone, a
    // reinstall — was never reserved (report14 X14-H3).
    final node = _Node();
    final ratchet = RatchetPersistence(native: node, storage: storage);
    final deviceA = key;
    node.seal(deviceA);
    await ratchet.flush(why: 'setup');
    await ratchet.reserveBeforePublish(peer);
    expect(await storage.getSetting(ratchetReservationKey(deviceA)), isNotNull);

    // The same peer reaches us from another device. Nothing about A changed.
    final deviceB = _convKey(local: 1, peerNode: 2, peerInstance: 7);
    node.seal(deviceB);
    await ratchet.reserveBeforePublish(peer);

    expect(
      await storage.getSetting(ratchetReservationKey(deviceB)),
      isNotNull,
      reason:
          'the send native picks is per DEVICE, so a reservation that only '
          'ever covers the first one leaves the rest publishing unguarded',
    );
  });

  test('a reservation costs one write per run, not one per send', () async {
    final node = _Node();
    final ratchet = RatchetPersistence(native: node, storage: storage);
    node.seal(key);
    await ratchet.flush(why: 'setup');

    await ratchet.reserveBeforePublish(peer);
    final first = await storage.getSetting(ratchetReservationKey(key));
    expect(first, isNotNull);

    // Well inside the run: nothing further is owed to the container.
    for (var i = 0; i < RatchetPersistence.reserveAhead ~/ 2; i++) {
      node.seal(key);
      await ratchet.reserveBeforePublish(peer);
    }
    expect(
      await storage.getSetting(ratchetReservationKey(key)),
      first,
      reason: 'these sends are covered already, so nothing was written',
    );

    // Past the end of it: a further run has to be taken.
    for (var i = 0; i < RatchetPersistence.reserveAhead; i++) {
      node.seal(key);
    }
    await ratchet.reserveBeforePublish(peer);
    expect(
      await storage.getSetting(ratchetReservationKey(key)),
      isNot(first),
      reason: 'the run ran out, so a further one must reach disk',
    );
  });
}
