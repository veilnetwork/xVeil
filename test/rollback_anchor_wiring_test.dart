import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';

/// An anchor kept in memory, standing in for the profile preference file.
class _MemoryAnchor implements RollbackAnchorStore {
  int? seq;
  int writes = 0;

  @override
  Future<int?> read() async => seq;

  @override
  Future<void> write(int value) async {
    writes++;
    seq = value;
  }
}

void main() {
  /// The verdict has to come from the CONTAINER, not from the fake's own idea
  /// of a counter — so this walks a real store through a commit and asks.
  test(
    'an anchored space that moved forward is clean and re-anchors',
    () async {
      final store = FakeKvLogStore();
      final storage = HiddenVolumeStorage.fromStore(store);
      final anchor = _MemoryAnchor();
      // A real container has written its first superblock by the time anything
      // opens it, so its history is never empty. Commit once before anchoring
      // rather than anchoring a counter that predates the container's own
      // first record.
      store.commit([
        PutOp(Ns.settings, Uint8List.fromList([9]), Uint8List.fromList([9])),
      ]);

      // First launch: nothing anchored, so nothing to compare against.
      var check = await checkContainerAgainstAnchor(
        storage: storage,
        anchor: anchor,
        reserveAhead: 32,
      );
      expect(check.verdict, AnchorVerdict.firstRun);
      expect(anchor.seq, 1, reason: 'the first open records where it stands');

      // Some work happens.
      for (var i = 0; i < 3; i++) {
        store.commit([
          PutOp(Ns.settings, Uint8List.fromList([i]), Uint8List.fromList([i])),
        ]);
      }

      check = await checkContainerAgainstAnchor(
        storage: storage,
        anchor: anchor,
        reserveAhead: 32,
      );
      expect(check.verdict, AnchorVerdict.clean);
      expect(check.lostSendPositions, 0);
      expect(anchor.seq, 4, reason: 'a clean open moves the anchor forward');
    },
  );

  /// The case the whole thing exists for.
  test(
    'a container put back in time is caught and the anchor is kept',
    () async {
      final store = FakeKvLogStore();
      final storage = HiddenVolumeStorage.fromStore(store);
      final anchor = _MemoryAnchor();

      for (var i = 0; i < 10; i++) {
        store.commit([
          PutOp(Ns.settings, Uint8List.fromList([i]), Uint8List.fromList([i])),
        ]);
      }
      await checkContainerAgainstAnchor(
        storage: storage,
        anchor: anchor,
        reserveAhead: 32,
      );
      expect(anchor.seq, 10, reason: 'premise: this state was anchored');

      // Somebody puts an older copy of the container back.
      store.rollbackTo(4);

      final check = await checkContainerAgainstAnchor(
        storage: storage,
        anchor: anchor,
        reserveAhead: 32,
      );
      expect(check.verdict, AnchorVerdict.rolledBack);
      expect(check.mayReuseSendPositions, isTrue);
      expect(
        check.lostSendPositions,
        6 * 32,
        reason:
            'six commits went missing, and each could have renewed one '
            'conversation by a full reservation',
      );
      expect(
        anchor.seq,
        10,
        reason:
            'recording the rolled-back state would make the older copy the '
            'newest thing this device stands behind, and the evidence would be '
            'gone at the next launch',
      );
    },
  );

  /// A timeline that is not the one this device wrote.
  test('a container whose history is not ours is a fork', () async {
    final store = FakeKvLogStore();
    final storage = HiddenVolumeStorage.fromStore(store);
    final anchor = _MemoryAnchor()..seq = 4;

    // Ahead of the anchor, inside the horizon, and inside the window this
    // container reports — but the commit we anchored is not in it. That is
    // the only shape from which a fork can be told apart from a container
    // that simply retired the anchor; anything older than the window is
    // unprovable and must read as out-of-range, not as an accusation.
    store.forkHistory(const [1, 2, 3, 5, 6], seq: 6);

    final check = await checkContainerAgainstAnchor(
      storage: storage,
      anchor: anchor,
      reserveAhead: 32,
    );
    expect(check.verdict, AnchorVerdict.forked);
    expect(check.isSuspicious, isTrue);
  });

  /// THE DECOY POLICY, as code rather than as a comment.
  ///
  /// A view over the multi-space handle is how every identity beyond the
  /// first is opened, and that is where decoys live. It must not be able to
  /// answer the anchor questions at all — an anchor for a hidden space
  /// announces that the space exists, which is the one thing the container is
  /// built to deny.
  test('a multi-space view cannot be anchored', () async {
    expect(
      AsyncMultiSpaceKvLogStore,
      isNot(CommitAnchorSource),
      reason: 'a sanity check on the type identity below',
    );
    // The structural fact: neither multi-space view implements the port, so
    // `readCommitAnchor` has nothing to call and answers null.
    expect(
      MultiSpaceKvLogStore(_ThrowingBacking(), 1),
      isNot(isA<SyncCommitAnchorSource>()),
      reason: 'a decoy identity became anchorable',
    );
  });

  /// A store with no container behind it answers "cannot", and that answer is
  /// not mistaken for a commit.
  ///
  /// The worker reports -1 for a store that is not a [SyncCommitAnchorSource],
  /// because a message has to carry something. Reading that as a commit number
  /// would make every open of such a store look like a rollback from whatever
  /// was last anchored — a burn, and an alarm, over nothing.
  test('a store with no container is not read as commit minus one', () async {
    final storage = HiddenVolumeStorage.fromStore(_ContainerlessStore());
    expect(
      await storage.readCommitAnchor(),
      isNull,
      reason: 'a store that cannot answer was given a commit number anyway',
    );

    // And nothing is recorded for it.
    final anchor = _MemoryAnchor()..seq = 500;
    final check = await checkContainerAgainstAnchor(
      storage: storage,
      anchor: anchor,
      reserveAhead: 32,
    );
    expect(check.verdict, AnchorVerdict.firstRun);
    expect(check.mayReuseSendPositions, isFalse);
    expect(
      anchor.seq,
      500,
      reason:
          'the anchor was moved by a store that '
          'has no container to anchor',
    );

    // Vacuity: a store that CAN answer is read, or the assertions above would
    // hold with the whole path deleted.
    final real = HiddenVolumeStorage.fromStore(FakeKvLogStore());
    expect(await real.readCommitAnchor(), isNotNull);
  });

  /// And a storage handle that cannot answer is never anchored — no write,
  /// no verdict, nothing recorded outside its container.
  test('an unanchorable store records nothing at all', () async {
    final anchor = _MemoryAnchor();
    final check = await checkContainerAgainstAnchor(
      storage: null,
      anchor: anchor,
      reserveAhead: 32,
    );
    expect(check.verdict, AnchorVerdict.firstRun);
    expect(
      anchor.writes,
      0,
      reason:
          'something was recorded for a space that '
          'is not anchored, which is how a decoy is announced',
    );
  });

  /// Passing no anchor is the other half of the same policy.
  test('a space opened without an anchor writes nothing', () async {
    final store = FakeKvLogStore();
    final storage = HiddenVolumeStorage.fromStore(store);
    store.commit([
      PutOp(Ns.settings, Uint8List.fromList([1]), Uint8List.fromList([1])),
    ]);
    final check = await checkContainerAgainstAnchor(
      storage: storage,
      anchor: null,
      reserveAhead: 32,
    );
    expect(check.verdict, AnchorVerdict.firstRun);
  });
}

/// A backing that fails if anything actually calls it — the type test above
/// must not need a working container.
class _ThrowingBacking implements MultiSpaceBacking {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('the type test must not call the backing');
}

/// A store with no container behind it — the shape of the counting doubles in
/// other tests, and of the in-memory fake before it grew a history.
class _ContainerlessStore implements KvLogStore {
  @override
  int commit(List<KvLogOp> ops) => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
