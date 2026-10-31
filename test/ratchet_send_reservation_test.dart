import 'dart:async';
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

class _GuardNode extends _Node implements RatchetPublicationGuard {
  int epoch = 0;
  bool active = false;
  final Map<String, RatchetSendPosition> permits = {};
  final Set<String> needs = {};
  int allowed = 0;

  @override
  int beginHostPublication() {
    active = true;
    permits.clear();
    needs.clear();
    return ++epoch;
  }

  @override
  RatchetPublicationState hostPublicationState(int owner) {
    if (owner != epoch) return RatchetPublicationState.superseded;
    if (!active) return RatchetPublicationState.retired;
    return needs.isEmpty
        ? RatchetPublicationState.idle
        : RatchetPublicationState.needsReservation;
  }

  @override
  void endHostPublication(int owner) {
    if (owner == epoch) active = false;
  }

  @override
  void allowHostPublication(
    int owner,
    Uint8List key,
    List<RatchetSendPosition> positions,
  ) {
    if (owner != epoch || !active) throw StateError('retired owner');
    final at = sendPosition(key)!;
    for (final p in positions) {
      if (_Node._same(p.chain, at.chain) && p.next > at.next) {
        permits[_Node._hex(key)] = p;
        needs.remove(_Node._hex(key));
        allowed++;
      }
    }
  }

  @override
  int seal(Uint8List key) {
    if (epoch == 0) return super.seal(key);
    if (!active) throw StateError('closed');
    final at = sendPosition(key)!;
    final permit = permits[_Node._hex(key)];
    if (permit == null ||
        !_Node._same(permit.chain, at.chain) ||
        at.next >= permit.next) {
      needs.add(_Node._hex(key));
      throw StateError('reservation required');
    }
    return super.seal(key);
  }
}

class _ReservationStorage extends HiddenVolumeStorage {
  _ReservationStorage()
    : super(({required password, required bool create}) => FakeKvLogStore());
  Completer<void>? hold;
  Completer<void>? entered;
  Completer<void>? anchorHold;
  Completer<void>? anchorEntered;
  bool fail = false;
  bool failAfterCommit = false;
  int writes = 0;
  int anchors = 0;
  int pairedSaves = 0;
  Future<void> Function()? beforePairedSave;
  Future<void> Function()? afterPairedSave;
  bool declinePaired = false;
  @override
  Future<void> saveRatchetStates(List<RatchetStateEntry> entries) async {
    if (entries.any((entry) => entry.sendReservation != null)) {
      pairedSaves++;
      if (declinePaired) throw const RatchetSnapshotReservationTooLarge();
      await beforePairedSave?.call();
      await super.saveRatchetStates(entries);
      await afterPairedSave?.call();
    } else {
      await super.saveRatchetStates(entries);
    }
  }

  @override
  Future<void> putSetting(String key, String value) async {
    if (key.startsWith('ratchet_reserve:')) {
      writes++;
      entered?.complete();
      entered = null;
      await hold?.future;
      if (fail) throw StateError('injected commit failure');
      await super.putSetting(key, value);
      if (failAfterCommit) throw StateError('injected uncertain commit');
      return;
    }
    await super.putSetting(key, value);
  }

  @override
  Future<bool> advanceRollbackAnchor() async {
    anchors++;
    anchorEntered?.complete();
    anchorEntered = null;
    await anchorHold?.future;
    return true;
  }
}

void main() {
  _hostPublicationTests();
  late HiddenVolumeStorage storage;
  final peer = NodeId(Uint8List.fromList(List.filled(32, 2)));
  final key = _convKey(local: 1, peerNode: 2);

  setUp(() async {
    storage = HiddenVolumeStorage(
      ({required password, required bool create}) => FakeKvLogStore(),
    );
    await storage.open(password: 'pw', createIfMissing: true);
  });

  test('unguarded stores keep the serialized reservation contract', () async {
    final backing = _ReservationStorage();
    await backing.open(password: 'pw', createIfMissing: true);
    addTearDown(backing.close);
    final node = _Node()..rotate(key, 78);
    final binder = RatchetPersistence(native: node, storage: backing);
    addTearDown(binder.close);
    await binder.reserveBeforePublish(peer);
    node.rotate(_convKey(local: 1, peerNode: 3), 79);
    final entered = Completer<void>();
    backing.entered = entered;
    backing.hold = Completer<void>();
    final blocked = binder.reserveBeforePublish(
      NodeId(Uint8List.fromList(List.filled(32, 3))),
    );
    await entered.future;
    var finished = false;
    final covered = binder.reserveBeforePublish(peer).then((_) {
      finished = true;
    });
    try {
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
    } finally {
      backing.hold!.complete();
      backing.hold = null;
      await Future.wait([blocked, covered]);
    }
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

void _hostPublicationTests() {
  group('native host publication attachment', () {
    late _ReservationStorage storage;
    late _GuardNode node;
    late RatchetPersistence owner;
    final key = _convKey(local: 1, peerNode: 2);
    final peer = NodeId(Uint8List.fromList(List.filled(32, 2)));
    setUp(() async {
      storage = _ReservationStorage();
      await storage.open(password: 'pw', createIfMissing: true);
      node = _GuardNode();
      for (var i = 0; i < 31; i++) {
        node.seal(key);
      }
      // These cases start with an existing durable session and test the
      // standalone reservation path. Persist it before attaching the owner;
      // a guarded flush now proactively reserves new snapshot chains.
      await storage.saveRatchetStates([
        RatchetStateEntry(key, node.export(key)!),
      ]);
      node.ackDirty([key], node.stateVersion());
      owner = RatchetPersistence(native: node, storage: storage);
      await owner.flush(now: true);
    });
    tearDown(() async {
      storage.hold?.complete();
      storage.hold = null;
      await owner.close();
      await storage.close();
    });

    test('idle polling does not write a reservation', () async {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(storage.writes, 0);
      expect(node.allowed, 0);
    });

    test(
      'a guarded snapshot prepares its reservation without a separate precheck',
      () async {
        node.rotate(key, 81);
        await owner.flush(now: true);
        expect(storage.pairedSaves, 1);
        expect(storage.writes, 0);
        expect(node.seal(key), 0);
      },
    );

    test(
      'snapshot reservation waits for commit and anchor before permit',
      () async {
        node.rotate(key, 81);
        final committed = Completer<void>();
        final allowCommitReply = Completer<void>();
        storage.afterPairedSave = () async {
          committed.complete();
          await allowCommitReply.future;
        };
        final anchorEntered = Completer<void>();
        storage.anchorEntered = anchorEntered;
        storage.anchorHold = Completer<void>();
        final work = owner.flush(now: true);
        try {
          await committed.future;
          expect(storage.pairedSaves, 1);
          expect(node.allowed, 0);
          expect(node.peekDirty(32).keys, isNotEmpty);
          expect(() => node.seal(key), throwsStateError);
          expect(
            await storage.getSetting(ratchetReservationKey(key)),
            isNotNull,
          );
          allowCommitReply.complete();
          await anchorEntered.future;
          expect(node.allowed, 0);
          expect(node.peekDirty(32).keys, isNotEmpty);
          expect(() => node.seal(key), throwsStateError);
        } finally {
          if (!allowCommitReply.isCompleted) allowCommitReply.complete();
          storage.anchorHold!.complete();
          storage.anchorHold = null;
          await work;
        }
        expect(node.peekDirty(32).keys, isEmpty);
        expect(node.seal(key), 0);
        expect(storage.writes, 0, reason: 'no separate setting write');
      },
    );

    test(
      'snapshot preparation preserves a higher durable reservation',
      () async {
        node.rotate(key, 81);
        await storage.putSetting(
          ratchetReservationKey(key),
          encodeRatchetReservations([
            RatchetSendPosition(node.sendPosition(key)!.chain, 100),
          ]),
        );
        await owner.flush(now: true);
        expect(
          decodeRatchetReservations(
            (await storage.getSetting(ratchetReservationKey(key)))!,
          ).single.next,
          100,
        );
        expect(node.seal(key), 0);
      },
    );

    test('paired budget refusal uses the separate reservation path', () async {
      node.rotate(key, 81);
      storage.declinePaired = true;
      await owner.flush(now: true);
      expect(storage.pairedSaves, 1);
      expect(storage.writes, 1);
      expect(storage.anchors, 1);
      expect(node.peekDirty(32).keys, isEmpty);
      expect(node.seal(key), 0);
    });

    test(
      'failed paired save holds the native floor and dirty acknowledgement',
      () async {
        node.rotate(key, 81);
        storage.beforePairedSave = () async {
          throw StateError('paired write failed');
        };
        await expectLater(owner.flush(now: true), throwsStateError);
        expect(
          storage.writes,
          0,
          reason: 'I/O failure must not use the budget fallback',
        );
        expect(node.allowed, 0);
        expect(node.peekDirty(32).keys, isNotEmpty);
        expect(() => node.seal(key), throwsStateError);
        storage.beforePairedSave = null;
        await owner.flush(now: true);
        expect(node.seal(key), 0);
      },
    );

    test(
      'a rotation during paired IO cannot reuse the exported chain permit',
      () async {
        node.rotate(key, 81);
        storage.beforePairedSave = () async {
          node.rotate(key, 82);
        };
        await owner.flush(now: true);
        expect(node.allowed, 0);
        expect(() => node.seal(key), throwsStateError);
        expect(node.peekDirty(32).keys, isNotEmpty);
        final saved = await storage.loadRatchetState(key);
        expect(node.storedSendPositions(key, saved!).single.chain.first, 81);
        storage.beforePairedSave = null;
        await owner.flush(now: true);
        expect(
          node
              .storedSendPositions(key, (await storage.loadRatchetState(key))!)
              .single
              .chain
              .first,
          82,
        );
        expect(node.seal(key), 0);
      },
    );

    test('a replaced owner grants no permit after paired IO', () async {
      node.rotate(key, 81);
      final previous = owner;
      storage.afterPairedSave = () async {
        owner = RatchetPersistence(native: node, storage: storage);
      };
      await previous.flush(now: true);
      expect(node.allowed, 0);
      expect(storage.anchors, 0);
      expect(() => node.seal(key), throwsStateError);
      storage.afterPairedSave = null;
      await previous.close();
      expect(node.active, isTrue);
      await owner.reserveBeforePublish(peer);
      expect(
        storage.anchors,
        1,
        reason: 'successor must witness the durable readback',
      );
      expect(node.seal(key), 0);
    });

    test('closing during paired IO never reopens publication', () async {
      node.rotate(key, 81);
      Future<int>? closing;
      storage.afterPairedSave = () async {
        closing = owner.close();
      };
      await owner.flush(now: true);
      await closing;
      expect(node.active, isFalse);
      expect(node.allowed, 0);
      expect(storage.anchors, 0);
      expect(() => node.seal(key), throwsStateError);
      expect(await storage.loadRatchetState(key), isNotNull);
    });

    test(
      'a lost paired reply leaves permits held until an anchored retry',
      () async {
        node.rotate(key, 81);
        storage.afterPairedSave = () async {
          throw StateError('lost paired reply');
        };
        await expectLater(owner.flush(now: true), throwsStateError);
        expect(await storage.getSetting(ratchetReservationKey(key)), isNotNull);
        expect(node.allowed, 0);
        expect(storage.anchors, 0);
        expect(node.peekDirty(32).keys, isNotEmpty);
        expect(() => node.seal(key), throwsStateError);
        storage.afterPairedSave = null;
        await owner.flush(now: true);
        expect(storage.anchors, 1);
        expect(storage.writes, 0);
        expect(node.seal(key), 0);
      },
    );

    test(
      'retry after a lost reservation reply attempts the rollback anchor',
      () async {
        storage.failAfterCommit = true;
        await expectLater(owner.reserveBeforePublish(peer), throwsStateError);
        expect(await storage.getSetting(ratchetReservationKey(key)), isNotNull);
        expect(node.allowed, 0);
        expect(storage.anchors, 0);
        storage.failAfterCommit = false;
        final entered = Completer<void>();
        storage.anchorEntered = entered;
        storage.anchorHold = Completer<void>();
        final retry = owner.reserveBeforePublish(peer);
        try {
          await entered.future;
          expect(
            storage.anchors,
            1,
            reason:
                'marks read back after an uncertain commit have no witness '
                'that the rollback anchor was attempted',
          );
          expect(node.allowed, 0);
          expect(() => node.seal(key), throwsStateError);
        } finally {
          storage.anchorHold!.complete();
          storage.anchorHold = null;
          await retry;
        }
        expect(node.seal(key), 31);
        await owner.reserveBeforePublish(peer);
        expect(
          storage.anchors,
          1,
          reason: 'a warm cache hit needs no new attempt',
        );
      },
    );

    test(
      'a covered guarded send does not wait for another reservation',
      () async {
        await owner.reserveBeforePublish(peer);
        final allowed = node.allowed;
        final foreign = _convKey(local: 1, peerNode: 3);
        node.rotate(foreign, 77);
        expect(() => node.seal(foreign), throwsStateError);
        final entered = Completer<void>();
        storage.entered = entered;
        storage.hold = Completer<void>();
        final blocked = owner.reserveBeforePublish(
          NodeId(Uint8List.fromList(List.filled(32, 3))),
        );
        await entered.future;
        var finished = false;
        final covered = owner.reserveBeforePublish(peer).then((_) {
          finished = true;
        });
        try {
          // Event-loop barrier, not a timing bound. The foreign commit remains
          // gated throughout; a cached durable reservation needs no storage I/O.
          await Future<void>.delayed(Duration.zero);
          expect(finished, isTrue);
          expect(
            node.allowed,
            allowed,
            reason: 'no new permission is installed',
          );
          expect(node.seal(key), 31);
          expect(() => node.seal(foreign), throwsStateError);
        } finally {
          storage.hold!.complete();
          storage.hold = null;
          await Future.wait([blocked, covered]);
        }
        expect(node.seal(foreign), 0);
      },
    );

    test(
      'cached marks do not grant a native floor before the anchor attempt',
      () async {
        expect(() => node.seal(key), throwsStateError);
        final entered = Completer<void>();
        storage.anchorEntered = entered;
        storage.anchorHold = Completer<void>();
        final reserving = owner.reserveBeforePublish(peer);
        await entered.future;
        var finished = false;
        final covered = owner.reserveBeforePublish(peer).then((_) {
          finished = true;
        });
        try {
          await Future<void>.delayed(Duration.zero);
          expect(finished, isTrue);
          expect(
            await storage.getSetting(ratchetReservationKey(key)),
            isNotNull,
          );
          expect(node.allowed, 0);
          expect(() => node.seal(key), throwsStateError);
        } finally {
          storage.anchorHold!.complete();
          storage.anchorHold = null;
          await Future.wait([reserving, covered]);
        }
        expect(node.seal(key), 31);
      },
    );

    for (final change in ['rotation', 'exhaustion', 'sibling']) {
      test('a $change cannot reuse a covered reservation fast path', () async {
        await owner.reserveBeforePublish(peer);
        final foreign = _convKey(local: 1, peerNode: 3);
        node.rotate(foreign, 77);
        final entered = Completer<void>();
        storage.entered = entered;
        storage.hold = Completer<void>();
        final blocked = owner.reserveBeforePublish(
          NodeId(Uint8List.fromList(List.filled(32, 3))),
        );
        await entered.future;
        var changedKey = key;
        if (change == 'rotation') {
          node.rotate(key, 78);
        } else if (change == 'sibling') {
          changedKey = _convKey(local: 1, peerNode: 2, peerInstance: 7);
          node.rotate(changedKey, 79);
        } else {
          for (var n = 0; n < RatchetPersistence.reserveAhead; n++) {
            node.seal(key);
          }
        }
        expect(() => node.seal(changedKey), throwsStateError);
        var finished = false;
        final demand = owner.reserveBeforePublish(peer).then((_) {
          finished = true;
        });
        try {
          await Future<void>.delayed(Duration.zero);
          expect(finished, isFalse);
          expect(() => node.seal(changedKey), throwsStateError);
        } finally {
          storage.hold!.complete();
          storage.hold = null;
          await Future.wait([blocked, demand]);
        }
        expect(node.seal(changedKey), change == 'exhaustion' ? 63 : 0);
      });
    }

    test('cached marks do not outlive a retired native owner', () async {
      await owner.reserveBeforePublish(peer);
      node.endHostPublication(node.epoch);
      await expectLater(owner.reserveBeforePublish(peer), throwsStateError);
      expect(() => node.seal(key), throwsStateError);
    });

    test(
      'parallel prechecks cannot publish beyond the committed floor',
      () async {
        await storage.putSetting(
          ratchetReservationKey(key),
          encodeRatchetReservations([
            RatchetSendPosition(node.sendPosition(key)!.chain, 32),
          ]),
        );
        await Future.wait([
          owner.reserveBeforePublish(peer),
          owner.reserveBeforePublish(peer),
        ]);
        expect(node.seal(key), 31);
        expect(() => node.seal(key), throwsStateError);
        final entered = Completer<void>();
        storage.entered = entered;
        storage.hold = Completer<void>();
        final permitsBefore = node.allowed;
        await entered.future.timeout(const Duration(seconds: 3));
        expect(node.sendPosition(key)!.next, 32);
        expect(node.allowed, permitsBefore);
        expect(() => node.seal(key), throwsStateError);
        storage.hold!.complete();
        storage.hold = null;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(node.seal(key), 32);
        expect(storage.anchors, greaterThan(0));
        final oldSnapshot = (await storage.loadRatchetState(key))!;
        final restored = _Node();
        restored.import(key, oldSnapshot);
        await recoverReservedSendPositions(restored, storage);
        expect(restored.seal(key), 64);
      },
    );

    for (final uncertain in [false, true]) {
      test(
        'failed commit ($uncertain uncertain) cannot authorize ciphertext',
        () async {
          storage.fail = !uncertain;
          storage.failAfterCommit = uncertain;
          await expectLater(owner.reserveBeforePublish(peer), throwsStateError);
          expect(node.allowed, 0);
          expect(() => node.seal(key), throwsStateError);
          expect(node.sendPosition(key)!.next, 31);
          storage.fail = false;
          storage.failAfterCommit = false;
          await owner.reserveBeforePublish(peer);
          expect(node.seal(key), 31);
        },
      );
    }

    test(
      'demand pump reserves the native identity despite a physical alias',
      () async {
        final alias = NodeId(Uint8List.fromList(List.filled(32, 99)));
        await owner.reserveBeforePublish(alias);
        expect(storage.writes, 0);
        expect(() => node.seal(key), throwsStateError);
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(node.seal(key), 31);
        expect(storage.writes, 1);
      },
    );

    test('rotated chain cannot borrow the old chain floor', () async {
      await owner.reserveBeforePublish(peer);
      final old = node.sendPosition(key)!;
      node.rotate(key, 73);
      expect(() => node.seal(key), throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(node.seal(key), 0);
      final marks = decodeRatchetReservations(
        await storage.getSetting(ratchetReservationKey(key)),
      );
      expect(marks.any((m) => _Node._same(m.chain, old.chain)), isTrue);
      expect(marks.length, 2);
    });

    test(
      'shutdown joins an in-flight commit and never permits a closed owner',
      () async {
        final entered = Completer<void>();
        storage.entered = entered;
        storage.hold = Completer<void>();
        expect(() => node.seal(key), throwsStateError);
        await entered.future.timeout(const Duration(seconds: 3));
        var done = false;
        final closing = owner.close().then((_) {
          done = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(done, isFalse);
        expect(node.active, isFalse);
        expect(node.allowed, 0);
        storage.hold!.complete();
        storage.hold = null;
        await closing;
        expect(node.allowed, 0);
        expect(() => node.seal(key), throwsStateError);
      },
    );

    test('superseded binder cannot close or snapshot a successor', () async {
      final previous = owner;
      owner = RatchetPersistence(native: node, storage: storage);
      node.rotate(key, 92);
      final saved = await storage.loadRatchetState(key);
      expect(await previous.flush(now: true), 0);
      await expectLater(previous.reserveBeforePublish(peer), throwsStateError);
      expect(await previous.close(), 0);
      expect(node.active, isTrue);
      expect(await storage.loadRatchetState(key), saved);
      await owner.reserveBeforePublish(peer);
      expect(node.seal(key), 0);
    });
  });
}
