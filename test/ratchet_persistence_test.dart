import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart' show Contact, ContactStatus, Message;
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/ratchet_persistence.dart';

/// A conversation key: `our device (16) ‖ their node (32) ‖ their device (16)`.
Uint8List _convKey({
  required int local,
  required int peerNode,
  int peerInstance = 1,
}) {
  final out = Uint8List(kRatchetKeyLen);
  out.fillRange(0, 16, local);
  out.fillRange(16, 48, peerNode);
  out.fillRange(48, 64, peerInstance);
  return out;
}

NodeId _node(int fill) => NodeId(Uint8List(32)..fillRange(0, 32, fill));

/// A one-way chain, which is the only property of a Double Ratchet these tests
/// need to be able to break.
///
/// A conversation is a send counter and a receive counter. Sealing burns the
/// next send index; opening accepts ONLY the index it is expecting and then
/// advances. Nothing here can be rebuilt: a node that lost the state cannot
/// open a frame, exactly like the real thing, and — unlike a dropped packet —
/// the sender has already moved on, so a retransmit does not help either.
class _FakeRatchetNode implements RatchetStateHandle {
  final Map<String, _FakeConversation> _held = {};

  /// Each marked conversation against the version it was marked AT — what
  /// makes an acknowledgement safe to honour or safe to ignore.
  final Map<String, int> _dirty = <String, int>{};
  int _version = 0;

  /// Acknowledgements that named a conversation which had moved on.
  int refusedStaleAcks = 0;

  /// Frames refused because the receiving state was not there.
  int refusedForMissingState = 0;

  static String _hex(Uint8List k) =>
      [for (final b in k) b.toRadixString(16).padLeft(2, '0')].join();

  /// Seal one frame to [key]. Returns the wire index it burned.
  int seal(Uint8List key) {
    final c = _held.putIfAbsent(_hex(key), () => _FakeConversation());
    final index = c.sent++;
    _version++;
    _dirty[_hex(key)] = _version;
    return index;
  }

  /// Open the frame that carries [index]. False when this node cannot.
  ///
  /// Only work that COMMITTED moves the version and marks the conversation:
  /// a frame this node cannot open changes nothing, which is the property that
  /// lets a host tell "nothing happened" from "something happened twice".
  bool open(Uint8List key, int index) {
    final c = _held[_hex(key)];
    if (c == null) {
      refusedForMissingState++;
      return false;
    }
    if (index != c.received) return false;
    c.received++;
    _version++;
    _dirty[_hex(key)] = _version;
    return true;
  }

  @override
  int stateVersion() => _version;

  @override
  ({List<Uint8List> keys, int remaining, int generation}) peekDirty(
    int maxKeys,
  ) {
    final ordered = _dirty.keys.toList()..sort();
    final named = ordered.take(maxKeys).toList();
    // CONSUMES NOTHING, and whatever did not fit is still listed — the two
    // halves of the contract the drain loop exists for. Dropping either would
    // lose the only notice those conversations get.
    return (
      keys: [for (final k in named) _unhex(k)],
      remaining: _dirty.length - named.length,
      generation: _version,
    );
  }

  @override
  int ackDirty(List<Uint8List> keys, int generation) {
    var cleared = 0;
    for (final key in keys) {
      final marked = _dirty[_hex(key)];
      if (marked == null) continue;
      if (marked > generation) {
        // Marked again after the caller read it: the bytes it just wrote are
        // from before that change, so the mark stands.
        refusedStaleAcks++;
        continue;
      }
      _dirty.remove(_hex(key));
      cleared++;
    }
    return cleared;
  }

  @override
  List<Uint8List> list() =>
      [for (final k in (_held.keys.toList()..sort())) _unhex(k)];

  @override
  Uint8List? export(Uint8List conversationKey) {
    final c = _held[_hex(conversationKey)];
    if (c == null) return null;
    return c.encode();
  }

  @override
  bool import(Uint8List conversationKey, Uint8List blob) {
    final c = _FakeConversation.decode(blob);
    if (c == null) return false;
    _held[_hex(conversationKey)] = c;
    return true;
  }

  @override
  bool forget(Uint8List conversationKey) {
    final held = _held.remove(_hex(conversationKey)) != null;
    // MARKS rather than unmarks, because that is what veil does: dropping a
    // conversation is a change like any other, and the mark is the only way
    // the host is told its stored blob has to go. Unmarking here made the
    // fake tidier and hid the one case that matters — a key named dirty that
    // veil no longer holds.
    if (held) {
      _version++;
      _dirty[_hex(conversationKey)] = _version;
    }
    return held;
  }

  /// Conversations [expire] will age out on its next call.
  ///
  /// veil decides this from its own clock and from whether this device has
  /// ever spoken on the conversation; re-deriving that here would be a second
  /// implementation of a policy veil already tests. What the host has to get
  /// right is the OBSERVABLE half — entries vanish and are marked — so that is
  /// what this models.
  final Set<String> expiring = <String>{};

  @override
  int expire() {
    var dropped = 0;
    for (final hex in expiring.toList()) {
      if (_held.remove(hex) == null) continue;
      _version++;
      _dirty[hex] = _version;
      dropped++;
    }
    expiring.clear();
    return dropped;
  }

  /// The marks currently standing, for tests that assert on them directly.
  List<Uint8List> get marked =>
      [for (final k in (_dirty.keys.toList()..sort())) _unhex(k)];

  bool closed = false;

  @override
  void close() => closed = true;

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

class _FakeConversation {
  int sent = 0;
  int received = 0;

  /// Padded to something session-shaped so the storage layer is exercised at a
  /// realistic size rather than at eight bytes.
  Uint8List encode() {
    final out = Uint8List(1400);
    out[0] = sent & 0xff;
    out[1] = (sent >> 8) & 0xff;
    out[2] = received & 0xff;
    out[3] = (received >> 8) & 0xff;
    return out;
  }

  static _FakeConversation? decode(Uint8List blob) {
    if (blob.length < 4) return null;
    return _FakeConversation()
      ..sent = blob[0] | (blob[1] << 8)
      ..received = blob[2] | (blob[3] << 8);
  }
}

/// A direct 1:1 link. [onSend] stands in for veil sealing the frame on the way
/// out; [onDeliver] for it opening the frame on the way in — both happen before
/// the app layer is told anything, which is what makes the write-before-finish
/// contract checkable here.
class _FakeTransport implements VeilTransport {
  _FakeTransport(this._me, {this.onSend});

  final NodeId _me;
  final void Function(NodeId dst)? onSend;
  void Function()? onDeliver;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _FakeTransport? peer;

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    onSend?.call(dst);
    peer?.onDeliver?.call();
    peer?._inbound.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 80));

/// Records the ORDER in which one receive's two writes land, and makes the
/// ratchet one slow enough that "eventually" and "before" cannot be confused.
///
/// A test that only checks the state is on disk after the dust settles passes
/// just as happily when the write was fired and forgotten — and a fired-and-
/// forgotten write is the whole failure: the ack goes back, the sender stops
/// retransmitting, and the key that would have opened the frame is still in a
/// pending future when the process stops.
class _OrderedStorage extends HiddenVolumeStorage {
  _OrderedStorage(super.opener, this.log, {this.ratchetDelay = Duration.zero});

  final List<String> log;
  final Duration ratchetDelay;

  @override
  Future<void> saveRatchetStates(List<RatchetStateEntry> entries) async {
    if (ratchetDelay > Duration.zero) await Future<void>.delayed(ratchetDelay);
    await super.saveRatchetStates(entries);
    log.add('ratchet');
  }

  @override
  Future<Message> appendMessage(Message message) {
    log.add('message');
    return super.appendMessage(message);
  }
}

/// Lets a test stop one ratchet transaction in the gap it actually loses races
/// in: after the export, before the commit.
class _PausableStorage extends HiddenVolumeStorage {
  _PausableStorage(super.opener);

  /// Runs once, inside the first ratchet save, between the bytes being read out
  /// of veil and the records reaching the container.
  Future<void> Function()? beforeRatchetSave;

  @override
  Future<void> saveRatchetStates(List<RatchetStateEntry> entries) async {
    final hook = beforeRatchetSave;
    if (hook != null) {
      beforeRatchetSave = null;
      await hook();
    }
    await super.saveRatchetStates(entries);
  }
}

/// A container that refuses to take ratchet state — a full disk, a closed
/// worker, an encryption error. Anything that happens between reading the marks
/// and getting the bytes down.
class _FailingStorage extends HiddenVolumeStorage {
  _FailingStorage(super.opener);

  bool failRatchetSaves = true;

  @override
  Future<void> saveRatchetStates(List<RatchetStateEntry> entries) async {
    if (failRatchetSaves) throw StateError('no space left on device');
    await super.saveRatchetStates(entries);
  }
}

/// Counts vacuum passes, which the in-memory fake has no reason to model.
class _ScrubCountingStore implements KvLogStore {
  final FakeKvLogStore inner = FakeKvLogStore();
  int scrubs = 0;

  @override
  void scrub() => scrubs++;

  @override
  int commit(List<KvLogOp> ops) => inner.commit(ops);
  @override
  Uint8List? get(int ns, Uint8List key) => inner.get(ns, key);
  @override
  Uint8List? readLog(int ns, int logId) => inner.readLog(ns, logId);
  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) => inner.iterLogRange(
    namespace: namespace,
    start: start,
    end: end,
    limit: limit,
  );
  @override
  int count(int ns) => inner.count(ns);
  @override
  List<Uint8List> kvKeys(int ns) => inner.kvKeys(ns);
  @override
  int eraseNamespace(int ns) => inner.eraseNamespace(ns);
  @override
  Uint8List exportKeys() => inner.exportKeys();
  @override
  SlotUtilization? slotUtilization() => inner.slotUtilization();
  @override
  void close() => inner.close();
}

({FakeKvLogStore store, HiddenVolumeStorage storage}) _space() {
  final store = FakeKvLogStore();
  final storage = HiddenVolumeStorage(
    ({required Uint8List password, required bool create}) =>
        password.isEmpty ? null : store,
  );
  return (store: store, storage: storage);
}

void main() {
  late FakeKvLogStore store;
  late HiddenVolumeStorage storage;

  setUp(() async {
    final space = _space();
    store = space.store;
    storage = space.storage;
    await storage.open(password: 'pw', createIfMissing: true);
  });

  group('a conversation survives a restart', () {
    test(
      'a session saved on one run opens the next frame on the next run',
      () async {
        // Audit-shaped statement of the blocker this closes. veil keeps ratchet
        // state in memory and its runtime directory is recreated every session,
        // so without a host store every launch starts a NEW conversation — and
        // the peer, who did not restart, keeps sealing to the old one.
        final peer = _node(7);
        final key = _convKey(local: 3, peerNode: 7);

        final first = _FakeRatchetNode();
        final firstRun = RatchetPersistence(native: first, storage: storage);
        // Established: three frames exchanged, each one written before the
        // operation was treated as finished.
        first.import(key, _FakeConversation().encode());
        for (var i = 0; i < 3; i++) {
          expect(first.open(key, i), isTrue);
          await firstRun.flush();
        }
        expect(first.stateVersion(), 3);

        // The process ends. Everything in [first] is gone; only the container
        // survives, which is the whole point.
        final second = _FakeRatchetNode();
        final secondRun = RatchetPersistence(native: second, storage: storage);
        expect(await secondRun.restore(), 1);

        // The peer never restarted, so its next frame is index 3 — not 0. A
        // node that had rebuilt from nothing would be expecting 0 and could
        // never catch up, because the sender will not go back.
        expect(second.open(key, 3), isTrue, reason: 'chain resumed at 3');
        expect(second.refusedForMissingState, 0);
        await secondRun.flush();

        // And the third run picks up from where the second left off.
        final third = _FakeRatchetNode();
        final thirdRun = RatchetPersistence(native: third, storage: storage);
        expect(await thirdRun.restore(), 1);
        expect(third.open(key, 4), isTrue);

        // The peer's node id is readable straight out of the key, which is what
        // makes the cleanup paths possible without a side table.
        final stored = await storage.ratchetConversationKeys();
        expect(stored, hasLength(1));
        expect(
          RatchetStateEntry(stored.single, Uint8List(1)).peerNodeId,
          peer.bytes,
        );
      },
    );

    test('a blob veil refuses is dropped rather than retried forever', () async {
      final key = _convKey(local: 3, peerNode: 8);
      await storage.saveRatchetStates([
        // Three bytes: shorter than anything the fake will decode.
        RatchetStateEntry(key, Uint8List.fromList([1, 2, 3])),
      ]);
      final node = _FakeRatchetNode();
      expect(await RatchetPersistence(native: node, storage: storage).restore(), 0);
      expect(
        await storage.ratchetConversationKeys(),
        isEmpty,
        reason: 'unusable key material is not kept',
      );
    });
    test(
      'a conversation veil aged out has its stored bytes deleted, not left to '
      'be imported back',
      () async {
        final kept = _convKey(local: 3, peerNode: 20);
        final aged = _convKey(local: 3, peerNode: 21);
        final node = _FakeRatchetNode();
        final run = RatchetPersistence(native: node, storage: storage);
        node.import(kept, _FakeConversation().encode());
        node.import(aged, _FakeConversation().encode());
        node.seal(kept);
        node.seal(aged);
        await run.flush();
        expect(await storage.ratchetConversationKeys(), hasLength(2));

        // veil sweeps: the conversation leaves the store and is MARKED, which
        // is the only notice the host gets that its blob has to go.
        node.expiring.add(_FakeRatchetNode._hex(aged));
        expect(node.expire(), 1);
        // ...and a live conversation moves in the same breath, so the flush
        // below carries BOTH in one batch. A rule that only deleted when a
        // batch produced no exports at all would look right against a batch of
        // one and be wrong here, which is the shape these misses take.
        node.seal(kept);
        await run.flush();

        final left = await storage.ratchetConversationKeys();
        expect(left, hasLength(1), reason: 'the aged-out blob was deleted');
        expect(left.single, kept);
        // The point of deleting it: a restore must not resurrect what the
        // sweep just decided to be rid of.
        final next = _FakeRatchetNode();
        expect(await RatchetPersistence(native: next, storage: storage).restore(), 1);
        expect(next.list(), hasLength(1));
      },
    );

    test('a conversation forgotten while marked leaves no blob behind', () async {
      // Same shape by a different route: forget() drops the entry and marks it
      // too, so the flush that discharges the mark is what must delete the
      // bytes. This used to be skipped silently.
      final key = _convKey(local: 3, peerNode: 22);
      final node = _FakeRatchetNode();
      final run = RatchetPersistence(native: node, storage: storage);
      node.import(key, _FakeConversation().encode());
      node.seal(key);
      await run.flush();
      expect(await storage.ratchetConversationKeys(), hasLength(1));

      expect(node.forget(key), isTrue);
      await run.flush();
      expect(await storage.ratchetConversationKeys(), isEmpty);
    });
  });

  group('a skipped write is caught', () {
    test(
      'not saving after a receive costs the next message, so the write is '
      'not optional',
      () async {
        // Requirement 2 of the host contract, stated as a failure rather than
        // as a wish: if the flush after a receive is skipped, the state that
        // reaches the next run is the one from BEFORE that receive, and the
        // sender — who advanced — is now ahead of it. Nothing re-sends the gap
        // in a form this node can read.
        final key = _convKey(local: 3, peerNode: 9);

        final first = _FakeRatchetNode();
        final run = RatchetPersistence(native: first, storage: storage);
        first.import(key, _FakeConversation().encode());
        expect(first.open(key, 0), isTrue);
        await run.flush();
        // ...and here the second receive is NOT written.
        expect(first.open(key, 1), isTrue);

        final second = _FakeRatchetNode();
        expect(
          await RatchetPersistence(native: second, storage: storage).restore(),
          1,
        );
        // The peer's next frame is index 2. The restored state is expecting 1.
        expect(
          second.open(key, 2),
          isFalse,
          reason: 'the skipped write cost exactly one message key',
        );
        // And the frame it IS expecting will never arrive again.
        expect(second.stateVersion(), 0, reason: 'nothing committed');
      },
    );

    test('the flush is awaited before a send is reported finished', () async {
      // The window this closes is small and fatal: a send that returned before
      // its key was on disk is a key that exists nowhere if the process stops
      // between the two.
      final key = _convKey(local: 3, peerNode: 10);
      final node = _FakeRatchetNode();
      final run = RatchetPersistence(native: node, storage: storage);
      node.seal(key);
      final pending = run.flush();
      // Nothing is stored until the returned future completes.
      expect(await storage.ratchetConversationKeys(), isEmpty);
      await pending;
      expect(await storage.ratchetConversationKeys(), hasLength(1));
    });
  });

  group('the dirty loop finishes the remainder', () {
    test(
      'a buffer smaller than the dirty list loses nothing',
      () async {
        // veil bounds `take_dirty` by the caller's buffer and leaves the rest
        // MARKED. A host that read one batch and stopped would silently strand
        // every conversation past it until the next time it changed — by which
        // point the keys it was holding are gone.
        final keys = [
          for (var i = 0; i < 11; i++) _convKey(local: 3, peerNode: 20 + i),
        ];
        final node = _FakeRatchetNode();
        for (final k in keys) {
          node.seal(k);
        }
        // Three at a time against eleven dirty: four passes, and the last one
        // is the one that reports zero remaining.
        final run = RatchetPersistence(
          native: node,
          storage: storage,
          dirtyBatch: 3,
        );
        expect(await run.flush(), keys.length);
        expect(node.marked, isEmpty, reason: 'nothing left marked');

        final stored = await storage.ratchetConversationKeys();
        expect(stored, hasLength(keys.length));
        for (final k in keys) {
          expect(
            await storage.loadRatchetState(k),
            isNotNull,
            reason: 'peer ${k[16]} was in the remainder, not the first batch',
          );
        }

        // Every one of them restores, which is the point of not losing them.
        final restarted = _FakeRatchetNode();
        expect(
          await RatchetPersistence(
            native: restarted,
            storage: storage,
          ).restore(),
          keys.length,
        );
      },
    );

    test('a state larger than one KV value round-trips whole', () async {
      // A hidden-volume KV value stops at 2 KiB; an exported session does not.
      // The skipped-message-key cache rides along at 68 bytes per banked key,
      // and veil caps the whole thing at 256 KiB — so the conversations that
      // would fail a single-value scheme are exactly the ones under load, with
      // the most keys to lose.
      final key = _convKey(local: 3, peerNode: 40);
      final big = Uint8List(60 * 1024);
      for (var i = 0; i < big.length; i++) {
        big[i] = (i * 31 + 7) & 0xff;
      }
      await storage.saveRatchetStates([RatchetStateEntry(key, big)]);
      expect(await storage.loadRatchetState(key), big);

      // Shrinking must not leave the old tail behind for a later, longer save
      // to splice back in.
      final small = Uint8List.fromList([9, 9, 9, 9]);
      await storage.saveRatchetStates([RatchetStateEntry(key, small)]);
      expect(await storage.loadRatchetState(key), small);
      expect(
        store.count(Ns.ratchet),
        1,
        reason: 'the records past the new tail are gone, not orphaned',
      );
    });

    test('a run missing a record reads as absent, never as truncated', () async {
      final key = _convKey(local: 3, peerNode: 41);
      final blob = Uint8List(3000)..fillRange(0, 3000, 0xab);
      await storage.saveRatchetStates([RatchetStateEntry(key, blob)]);
      expect(await storage.loadRatchetState(key), hasLength(3000));
      // Lose the tail record the way a damaged container would.
      final tail = Uint8List(kRatchetKeyLen + 2)
        ..setRange(0, kRatchetKeyLen, key)
        ..[kRatchetKeyLen + 1] = 2;
      store.commit([DeleteOp(Ns.ratchet, tail)]);
      expect(
        await storage.loadRatchetState(key),
        isNull,
        reason: 'half a session is a session with the WRONG keys',
      );
    });
  });

  group('identities do not leak', () {
    test(
      'one identity\'s sessions are invisible and unusable from another',
      () async {
        // Every identity has its own container, and the ratchet state is the
        // one thing that would tie two of them to the same conversation on the
        // wire if it crossed.
        final other = _space();
        await other.storage.open(password: 'pw2', createIfMissing: true);

        final key = _convKey(local: 3, peerNode: 55);
        final mine = _FakeRatchetNode();
        final mineRun = RatchetPersistence(native: mine, storage: storage);
        mine.import(key, _FakeConversation().encode());
        expect(mine.open(key, 0), isTrue);
        await mineRun.flush();
        expect(await storage.ratchetConversationKeys(), hasLength(1));

        // The other identity's container holds nothing, and its node restores
        // nothing — so a frame for that conversation cannot be opened there.
        expect(await other.storage.ratchetConversationKeys(), isEmpty);
        final theirs = _FakeRatchetNode();
        expect(
          await RatchetPersistence(
            native: theirs,
            storage: other.storage,
          ).restore(),
          0,
        );
        expect(theirs.open(key, 1), isFalse);
        expect(theirs.refusedForMissingState, 1);

        // ...and the reverse: what the other identity writes stays in its own
        // space rather than appearing in ours.
        final theirKey = _convKey(local: 4, peerNode: 66);
        theirs.seal(theirKey);
        await RatchetPersistence(
          native: theirs,
          storage: other.storage,
        ).flush();
        expect(await other.storage.ratchetConversationKeys(), hasLength(1));
        expect(await storage.ratchetConversationKeys(), hasLength(1));
        expect(await storage.loadRatchetState(theirKey), isNull);
      },
    );

    test('superseded sessions are reclaimed, not left readable', () async {
      // Replacing a KV value ORPHANS the chunk that held the old one; the
      // bytes stay in the container, readable to anyone with the password,
      // until a vacuum reclaims them. For an ordinary setting that is untidy.
      // Here every superseded blob is a chain key the ratchet has turned past,
      // and forward secrecy a password recovers is not forward secrecy.
      final counting = _ScrubCountingStore();
      final vol = HiddenVolumeStorage(
        ({required Uint8List password, required bool create}) => counting,
      );
      await vol.open(password: 'pw', createIfMissing: true);
      final key = _convKey(local: 3, peerNode: 120);
      Uint8List blob(int n) => Uint8List(1400)..[0] = n & 0xff;

      for (var i = 0; i < 127; i++) {
        await vol.saveRatchetStates([RatchetStateEntry(key, blob(i))]);
      }
      expect(counting.scrubs, 0, reason: 'amortized, not once per message');
      await vol.saveRatchetStates([RatchetStateEntry(key, blob(127))]);
      expect(
        counting.scrubs,
        1,
        reason: 'the window is bounded by a count of writes, not by time',
      );
      expect(await vol.loadRatchetState(key), blob(127));
    });

    test('erasing an identity takes its ratchet state with it', () async {
      final key = _convKey(local: 3, peerNode: 77);
      await storage.saveRatchetStates([
        RatchetStateEntry(key, Uint8List(1400)),
      ]);
      expect(store.count(Ns.ratchet), greaterThan(0));
      await storage.eraseSpace();
      expect(
        store.count(Ns.ratchet),
        0,
        reason: 'the one namespace that is pure key material is not exempt',
      );
    });
  });

  group('cleanup reads the key', () {
    test('forgetting a contact drops both of their devices', () async {
      // The key is flat and reversible on purpose: everything belonging to a
      // contact is everything with that node id in its middle 32 bytes, and
      // two devices of one contact are two independent ratchets.
      final gone = _node(90);
      final phone = _convKey(local: 3, peerNode: 90, peerInstance: 1);
      final laptop = _convKey(local: 3, peerNode: 90, peerInstance: 2);
      final other = _convKey(local: 3, peerNode: 91);

      final node = _FakeRatchetNode();
      final run = RatchetPersistence(native: node, storage: storage);
      for (final k in [phone, laptop, other]) {
        node.seal(k);
      }
      await run.flush();
      expect(await storage.ratchetConversationKeys(), hasLength(3));

      expect(await run.forgetPeer(gone), 2);
      expect(await storage.ratchetConversationKeys(), hasLength(1));
      expect(await storage.loadRatchetState(other), isNotNull);
      // Live state goes too, or the session survives the deletion in memory
      // and re-persists itself on the next flush.
      expect(node.list(), hasLength(1));
      await run.flush();
      expect(await storage.ratchetConversationKeys(), hasLength(1));
    });

    test(
      'a contact whose sessions are only on disk still loses all of them',
      () async {
        // The mirror of the test above, and the one that actually pins the
        // storage-side scan: here the node holds NOTHING — the app was
        // restarted and the chat deleted before anything re-opened — so the
        // only thing that can find these two conversations is reading the
        // stored keys. With the live list carrying the case, a forget that
        // stopped at the first stored match looked correct.
        final gone = _node(93);
        final phone = _convKey(local: 3, peerNode: 93, peerInstance: 1);
        final laptop = _convKey(local: 3, peerNode: 93, peerInstance: 2);
        final other = _convKey(local: 3, peerNode: 94);
        for (final k in [phone, laptop, other]) {
          await storage.saveRatchetStates([
            RatchetStateEntry(k, _FakeConversation().encode()),
          ]);
        }

        final cold = _FakeRatchetNode();
        final run = RatchetPersistence(native: cold, storage: storage);
        expect(cold.list(), isEmpty);
        expect(await run.forgetPeer(gone), 2);

        final left = await storage.ratchetConversationKeys();
        expect(left, hasLength(1));
        expect(await storage.loadRatchetState(other), isNotNull);
        expect(await storage.loadRatchetState(phone), isNull);
        expect(await storage.loadRatchetState(laptop), isNull);
      },
    );

    test(
      'a session veil holds but the container has not seen yet is still '
      'forgotten',
      () async {
        final gone = _node(92);
        final key = _convKey(local: 3, peerNode: 92);
        final node = _FakeRatchetNode();
        final run = RatchetPersistence(native: node, storage: storage);
        // Opened this session and never flushed — deleting the chat must not
        // leave it live in the node to be written back a moment later.
        node.seal(key);
        expect(await storage.ratchetConversationKeys(), isEmpty);

        await run.forgetPeer(gone);
        expect(node.list(), isEmpty);
        await run.flush();
        expect(await storage.ratchetConversationKeys(), isEmpty);
      },
    );

    test(
      'state keyed to a device we are no longer is dropped once veil says so',
      () async {
        // The first 16 bytes are OUR device, and they change when this
        // identity's active subkey is re-issued. Nothing on this side knows
        // that value, so it is learned from a key veil itself produced —
        // never guessed.
        final oldDevice = _convKey(local: 1, peerNode: 30);
        final node = _FakeRatchetNode();
        final run = RatchetPersistence(native: node, storage: storage);
        node.seal(oldDevice);
        await run.flush();
        expect(
          await storage.getSetting(kRatchetLocalInstanceSetting),
          isNotNull,
        );

        // A later run, after the device was re-issued: veil now keys
        // conversations under a different local instance.
        final reissued = _FakeRatchetNode();
        final reissuedRun = RatchetPersistence(
          native: reissued,
          storage: storage,
        );
        await reissuedRun.restore();
        reissued.seal(_convKey(local: 2, peerNode: 31));
        await reissuedRun.flush();

        final left = await storage.ratchetConversationKeys();
        expect(left, hasLength(1));
        expect(left.single[0], 2, reason: 'only the current device remains');
      },
    );

    test('a first run records the device without dropping anything', () async {
      // Nothing stored, nothing to prune — and the marker still gets written,
      // or the NEXT run would think the device had just changed.
      final key = _convKey(local: 5, peerNode: 32);
      final node = _FakeRatchetNode();
      final run = RatchetPersistence(native: node, storage: storage);
      node.seal(key);
      await run.flush();
      expect(await storage.ratchetConversationKeys(), hasLength(1));

      final next = _FakeRatchetNode();
      final nextRun = RatchetPersistence(native: next, storage: storage);
      expect(await nextRun.restore(), 1);
      next.seal(key);
      await nextRun.flush();
      expect(
        await storage.ratchetConversationKeys(),
        hasLength(1),
        reason: 'the same device must not prune its own state',
      );
    });
  });

  group('the messaging paths write before they finish', () {
    // The contract is not "persist somewhere"; it is "persist BEFORE the send
    // or the receive is treated as complete". These drive the real service so
    // the two chokepoints — the single egress point and the inbound handler —
    // are what is being checked, not a helper beside them.
    late _FakeTransport tA, tB;
    late HiddenVolumeStorage sA, sB;
    late MessagingService mA, mB;
    late _FakeRatchetNode nA, nB;
    late NodeId a, b;
    late List<String> orderB;

    setUp(() async {
      a = _node(1);
      b = _node(2);
      nA = _FakeRatchetNode();
      nB = _FakeRatchetNode();
      orderB = <String>[];
      final spaceA = _space();
      final storeB = FakeKvLogStore();
      sA = spaceA.storage;
      sB = _OrderedStorage(
        ({required Uint8List password, required bool create}) => storeB,
        orderB,
        // Long enough that a write which was merely STARTED before the frame
        // was acted on cannot finish first by accident.
        ratchetDelay: const Duration(milliseconds: 40),
      );
      await sA.open(password: 'a', createIfMissing: true);
      await sB.open(password: 'b', createIfMissing: true);
      // Sealing on the way out and opening on the way in, the way veil does it
      // around the frame this transport carries.
      tA = _FakeTransport(a, onSend: (dst) => nA.seal(_convKey(local: 1, peerNode: 2)));
      tB = _FakeTransport(b, onSend: (dst) => nB.seal(_convKey(local: 2, peerNode: 1)));
      tA.peer = tB;
      tB.peer = tA;
      tA.onDeliver = () =>
          nA.open(_convKey(local: 1, peerNode: 2), nA._held.isEmpty ? -1 : 0);
      tB.onDeliver = () {
        nB.import(_convKey(local: 2, peerNode: 1), _FakeConversation().encode());
        nB.seal(_convKey(local: 2, peerNode: 1));
      };
      mA = MessagingService(tA, sA)
        ..ratchet = RatchetPersistence(native: nA, storage: sA)
        ..start();
      mB = MessagingService(tB, sB)
        ..ratchet = RatchetPersistence(native: nB, storage: sB)
        ..start();
    });

    tearDown(() async {
      await mA.dispose();
      await mB.dispose();
    });

    test('a send does not finish until its key is on disk', () async {
      expect(await sA.ratchetConversationKeys(), isEmpty);
      await mA.sendRequest(b, 'hello');
      // No pump. The send already returned, so by the contract the key it
      // burned is already in the container.
      expect(
        await sA.ratchetConversationKeys(),
        hasLength(1),
        reason: 'the flush is inside the single egress point',
      );
    });

    test('a receive does not finish until its key is on disk', () async {
      await mA.sendRequest(b, 'hello');
      await _pump();
      expect(await sB.ratchetConversationKeys(), hasLength(1));
      // ORDER, not eventuality. veil advanced the receiving chain on the way
      // up; from the moment this frame is acted on the sender is told to stop
      // retransmitting, so the write has to be finished first — not merely
      // started.
      expect(
        orderB.first,
        'ratchet',
        reason: 'the key was kept before anything was done with the frame',
      );
      expect(orderB, contains('message'));
    });

    test('deleting the chat takes the stored session with it', () async {
      await mA.sendRequest(b, 'hello');
      await _pump();
      expect(await sA.ratchetConversationKeys(), hasLength(1));
      await mA.deleteConversation(b);
      expect(
        await sA.ratchetConversationKeys(),
        isEmpty,
        reason: 'a deleted chat leaves no chain behind',
      );
    });
  });

  group('the shutdown save consumes no marks', () {
    test('saveAll writes everything held and leaves the dirty list', () async {
      final a = _convKey(local: 3, peerNode: 100);
      final b = _convKey(local: 3, peerNode: 101);
      final node = _FakeRatchetNode();
      final run = RatchetPersistence(native: node, storage: storage);
      node.seal(a);
      node.seal(b);

      expect(await run.saveAll(), 2);
      expect(await storage.ratchetConversationKeys(), hasLength(2));
      // The marks are the record of what still needs writing; a shutdown save
      // that consumed them would leave a crash after this point with nothing
      // to notice.
      expect(node.marked, hasLength(2));
    });
  });

  group('the mark is cleared by the write, not by the read', () {
    test('a write that fails leaves the work marked for the next flush',
        () async {
      // The notice a conversation gets is ONE mark. Under a destructive read it
      // was spent on the attempt rather than on the result, so a disk that said
      // no took the notice with it — and not only for this conversation: for
      // every other key in the same batch, which had done nothing wrong at all.
      final failing = _FailingStorage(
        ({required Uint8List password, required bool create}) =>
            password.isEmpty ? null : FakeKvLogStore(),
      );
      await failing.open(password: 'pw', createIfMissing: true);
      final a = _convKey(local: 3, peerNode: 60);
      final b = _convKey(local: 3, peerNode: 61);
      final node = _FakeRatchetNode();
      final run = RatchetPersistence(native: node, storage: failing);
      node.seal(a);
      node.seal(b);

      await expectLater(run.flush(), throwsStateError);
      expect(
        run.degraded,
        isTrue,
        reason: 'a failed write must not leave the object claiming the state '
            'is safe',
      );
      expect(
        node.marked,
        hasLength(2),
        reason: 'the marks went down with the write that failed',
      );

      // The disk comes back. Nothing had to change for this to be picked up:
      // the work was never forgotten.
      failing.failRatchetSaves = false;
      expect(await run.flush(), 2);
      expect(run.degraded, isFalse);
      expect(node.marked, isEmpty);
      expect(await failing.loadRatchetState(a), isNotNull);
      expect(await failing.loadRatchetState(b), isNotNull);
      await failing.close();
    });

    test('a conversation that moved mid-write keeps its mark', () async {
      // The acknowledgement carries the generation the read reported. This
      // conversation changed after that read, so the bytes on their way down do
      // not contain the change — and clearing the mark would leave the state
      // for the newer send in no queue at all.
      final paused = _PausableStorage(
        ({required Uint8List password, required bool create}) =>
            password.isEmpty ? null : FakeKvLogStore(),
      );
      await paused.open(password: 'pw', createIfMissing: true);
      final key = _convKey(local: 3, peerNode: 62);
      final node = _FakeRatchetNode();
      final run = RatchetPersistence(native: node, storage: paused);

      node.seal(key);
      paused.beforeRatchetSave = () async {
        // The send that lands while the previous one's write is in flight.
        node.seal(key);
      };
      expect(await run.flush(), 1);
      expect(node.refusedStaleAcks, 1);
      expect(
        node.marked,
        hasLength(1),
        reason: 'the second send was acknowledged by a write that predates it',
      );

      // And the flush that follows it writes the state that includes both.
      expect(await run.flush(), 1);
      expect(node.marked, isEmpty);
      final stored = _FakeConversation.decode(
        (await paused.loadRatchetState(key))!,
      )!;
      expect(stored.sent, 2);
      await paused.close();
    });
  });

  group('one ratchet transaction at a time', () {
    late _PausableStorage paused;
    late FakeKvLogStore pausedStore;

    setUp(() async {
      pausedStore = FakeKvLogStore();
      paused = _PausableStorage(
        ({required Uint8List password, required bool create}) =>
            password.isEmpty ? null : pausedStore,
      );
      await paused.open(password: 'pw', createIfMissing: true);
    });

    test('a flush that overtakes another cannot leave the older state', () async {
      final key = _convKey(local: 3, peerNode: 40);
      final node = _FakeRatchetNode();
      final run = RatchetPersistence(native: node, storage: paused);

      // One send. The first flush reads these bytes out and stops on the far
      // side of the export, holding a commit it has not made.
      node.seal(key);
      Future<int>? overtaker;
      paused.beforeRatchetSave = () async {
        // Another send lands while that commit is in the air, and the flush it
        // triggers exports the NEWER bytes.
        node.seal(key);
        overtaker = run.flush();
        // Long enough for the second transaction to run to completion if
        // nothing is stopping it — which is the failure: its newer record is
        // then overwritten by the older one still on its way down.
        await Future<void>.delayed(const Duration(milliseconds: 60));
      };
      await run.flush();
      await overtaker;

      final stored = _FakeConversation.decode(
        (await paused.loadRatchetState(key))!,
      )!;
      expect(
        stored.sent,
        2,
        reason: 'the container holds the state from before the second send: '
            'the older transaction committed last',
      );
    });

    test('two persistences over one container are still one writer', () async {
      // The gate is on the CONTAINER, not on the object. An identity switch
      // that has not finished tearing the old [RatchetPersistence] down is two
      // of them over one set of records, and a lock each is no lock at all —
      // the older transaction still lands last and still wins.
      final key = _convKey(local: 3, peerNode: 42);
      final node = _FakeRatchetNode();
      final leaving = RatchetPersistence(native: node, storage: paused);
      final arriving = RatchetPersistence(native: node, storage: paused);

      node.seal(key);
      Future<int>? other;
      paused.beforeRatchetSave = () async {
        node.seal(key);
        other = arriving.flush();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      };
      await leaving.flush();
      await other;

      final stored = _FakeConversation.decode(
        (await paused.loadRatchetState(key))!,
      )!;
      expect(
        stored.sent,
        2,
        reason: 'the second persistence wrote through the first one\'s '
            'transaction',
      );
    });

    test('a flush in flight cannot resurrect a conversation just forgotten',
        () async {
      final peer = _node(41);
      final key = _convKey(local: 3, peerNode: 41);
      final node = _FakeRatchetNode();
      final run = RatchetPersistence(native: node, storage: paused);

      node.seal(key);
      Future<int>? forgetting;
      paused.beforeRatchetSave = () async {
        // The chat is deleted while the write for it is in the air. Deleting a
        // chat is irreversible on purpose, and a write that lands afterwards
        // puts the key material of a conversation the user removed back into
        // the container — where the next launch restores it.
        forgetting = run.forgetPeer(peer);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      };
      await run.flush();
      await forgetting;

      expect(
        await paused.ratchetConversationKeys(),
        isEmpty,
        reason: 'a forgotten conversation came back after the deletion',
      );
      expect(node.list(), isEmpty);
    });
  });

  group("take_dirty's answer is a count of keys", () {
    // The unit the C ABI speaks in, pulled out of the `Pointer` plumbing so it
    // can be checked without a native node. A `size_t` read as a byte length
    // instead of a key count is the whole of audit C-01: the marks are cleared
    // by the same call, so every key it fails to yield is a conversation whose
    // state is never written and whose next launch resumes on a message key it
    // already spent.
    Uint8List buffer(int keys) => Uint8List(keys * kRatchetKeyLen)
      ..setAll(0, [
        for (var i = 0; i < keys * kRatchetKeyLen; i++) (i * 7 + 1) & 0xff,
      ]);

    test('one written key is one 64-byte key, not one byte', () {
      final buf = buffer(32);
      final keys = dirtyKeysFrom(buf, 1, 32);
      expect(keys, hasLength(1));
      expect(keys.single, Uint8List.sublistView(buf, 0, kRatchetKeyLen));
    });

    test('two written keys are two keys, at the right stride', () {
      final buf = buffer(32);
      final keys = dirtyKeysFrom(buf, 2, 32);
      expect(keys, hasLength(2));
      expect(keys[0], Uint8List.sublistView(buf, 0, kRatchetKeyLen));
      expect(
        keys[1],
        Uint8List.sublistView(buf, kRatchetKeyLen, 2 * kRatchetKeyLen),
      );
    });

    test('a full batch of 32 is 32 keys', () {
      final buf = buffer(32);
      final keys = dirtyKeysFrom(buf, 32, 32);
      expect(keys, hasLength(32));
      for (var i = 0; i < 32; i++) {
        expect(
          keys[i],
          Uint8List.sublistView(buf, i * kRatchetKeyLen, (i + 1) * kRatchetKeyLen),
        );
      }
    });

    test('nothing written is no keys', () {
      expect(dirtyKeysFrom(buffer(32), 0, 32), isEmpty);
    });

    test('a count above the batch asked for is refused', () {
      // The buffer here is twice the size the batch needs, so the length check
      // below is no help: what refuses this is the count being more than veil
      // was ever given room to write.
      expect(() => dirtyKeysFrom(buffer(64), 33, 32), throwsStateError);
    });

    test('a count the buffer cannot hold is refused, not read past', () {
      // And here the count is within the batch, so only the buffer's own
      // length stands between a wrong `size_t` and a read past the end of it.
      // The marks are already gone either way; not reading past is what is
      // left to get right.
      expect(() => dirtyKeysFrom(buffer(4), 8, 32), throwsStateError);
    });

    test('a negative count is refused', () {
      // `size_t` is unsigned; a negative here means the out-slot was read as a
      // signed type of the wrong width, which is the same class of mistake.
      expect(() => dirtyKeysFrom(buffer(32), -1, 32), throwsStateError);
    });
  });

  group('serving a file does not pay a container write per chunk', () {
    // The ratchet write goes to the same container worker the serve reads its
    // chunks through. Measured on a phone: the write is 8 ms, but queued behind
    // the serve's own I/O it stalled for SECONDS — fifty times over, which is
    // the whole of a 200 KB file taking a minute. A chunk is a fire-and-forget
    // datagram and reports success to nobody, so the promise the write keeps is
    // owed once, at the end of the serve — not once per chunk.
    late _FakeRatchetNode nA, nB;
    late _FakeTransport tA, tB;
    late HiddenVolumeStorage sA, sB;
    late MessagingService mA, mB;
    final writesA = <String>[];

    setUp(() async {
      writesA.clear();
      nA = _FakeRatchetNode();
      nB = _FakeRatchetNode();
      final storeA = FakeKvLogStore();
      final storeB = FakeKvLogStore();
      sA = _OrderedStorage(
        ({required Uint8List password, required bool create}) => storeA,
        writesA,
      );
      sB = HiddenVolumeStorage(
        ({required Uint8List password, required bool create}) => storeB,
      );
      await sA.open(password: 'a', createIfMissing: true);
      await sB.open(password: 'b', createIfMissing: true);
      tA = _FakeTransport(
        _node(1),
        onSend: (dst) => nA.seal(_convKey(local: 1, peerNode: 2)),
      );
      tB = _FakeTransport(_node(2));
      tA.peer = tB;
      tB.peer = tA;
      mA = MessagingService(tA, sA, contentPacing: Duration.zero)
        ..ratchet = RatchetPersistence(native: nA, storage: sA)
        ..start();
      mB = MessagingService(tB, sB, contentPacing: Duration.zero)
        ..ratchet = RatchetPersistence(native: nB, storage: sB)
        ..start();
      await sA.upsertContact(
        Contact(nodeId: _node(2), status: ContactStatus.accepted),
      );
      await sB.upsertContact(
        Contact(nodeId: _node(1), status: ContactStatus.accepted),
      );
    });

    tearDown(() async {
      await mA.dispose();
      await mB.dispose();
    });

    test('the chunks of one serve share a single write, and it lands before '
        'the serve is finished', () async {
      final data = Uint8List.fromList(
        List.generate(64 * 1024, (i) => (i * 31 + 7) & 0xff),
      );
      await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );
      final cid = ContentManifest.fromBytes('serve.bin', data).contentId;
      await mA.sendFileStreaming(
        _node(2),
        'serve.bin',
        data.length,
        (o, l) async => Uint8List.sublistView(data, o, o + l),
        close: () async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final sendWrites = writesA.where((e) => e == 'ratchet').length;
      await mB.downloadContent(_node(1), cid);

      // Wait for B to hold it — the serve is over by then.
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        if (await sB.hasFile(cid)) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await sB.hasFile(cid), isTrue, reason: 'sanity: the file arrived');

      final serveWrites =
          writesA.where((e) => e == 'ratchet').length - sendWrites;
      // 64 KiB is many chunks; one write for the lot is the point.
      expect(
        serveWrites,
        lessThanOrEqualTo(4),
        reason:
            'the serve made \$serveWrites container writes — one per chunk '
            'is what queued behind its own reads and cost seconds each',
      );
      // The count alone cannot say the serve's OWN keys landed — acks and
      // receives write too, so a serve that never flushed would still see
      // writes go by. Compare the stored chain against the live one instead:
      // if the final write was skipped, the container is behind by every chunk
      // this serve sent.
      final key = _convKey(local: 1, peerNode: 2);
      final live = _FakeConversation.decode(nA.export(key)!)!.sent;
      final storedBlob = await sA.loadRatchetState(key);
      expect(storedBlob, isNotNull, reason: 'nothing was stored for the peer');
      final stored = _FakeConversation.decode(storedBlob!)!.sent;
      expect(
        stored,
        live,
        reason:
            'the serve finished with the container $live vs $stored behind '
            '— the keys those chunks burned exist only in RAM',
      );
    });
  });
}
