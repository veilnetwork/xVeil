import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';

/// An anchor kept in memory, standing in for the profile preference file.
class _MemoryAnchor implements RollbackAnchorStore {
  AnchorRecord? record;
  int writes = 0;

  /// Make the store refuse, the way a full disk does.
  bool refuse = false;

  int? get seq => record?.seq;

  @override
  Future<AnchorRecord?> read() async => record;

  @override
  Future<bool> write(AnchorRecord value) async {
    writes++;
    if (refuse) return false;
    record = value;
    return true;
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
      // Two, not one: the container's generation is minted on first use and
      // that mint is itself a commit.
      expect(anchor.seq, 2, reason: 'the first open records where it stands');

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
      expect(anchor.seq, 5, reason: 'a clean open moves the anchor forward');
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
      expect(anchor.seq, 11, reason: 'premise: this state was anchored');

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
        7 * 32,
        reason:
            'the missing commits could each have renewed one '
            'conversation by a full reservation',
      );
      expect(
        anchor.seq,
        11,
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
    final anchor = _MemoryAnchor();

    // Ahead of the anchor, inside the horizon, and inside the window this
    // container reports — but the commit we anchored is not in it. That is
    // the only shape from which a fork can be told apart from a container
    // that simply retired the anchor; anything older than the window is
    // unprovable and must read as out-of-range, not as an accusation.
    // Establish an anchor ABOUT THIS CONTAINER first: a record naming a
    // different container is not evidence of anything, so a fork can only be
    // told from the generation it shares with us.
    store.commit([
      PutOp(Ns.settings, Uint8List.fromList([1]), Uint8List.fromList([1])),
    ]);
    await checkContainerAgainstAnchor(
      storage: storage,
      anchor: anchor,
      reserveAhead: 32,
    );
    final anchored = anchor.seq!;
    store.forkHistory([
      for (var i = 1; i <= anchored + 3; i++)
        if (i != anchored) i,
    ], seq: anchored + 3);

    final check = await checkContainerAgainstAnchor(
      storage: storage,
      anchor: anchor,
      reserveAhead: 32,
    );
    expect(check.verdict, AnchorVerdict.forked);
    expect(check.isSuspicious, isTrue);
  });

  /// The anchor keeps moving after boot, or it protects only the boot.
  ///
  /// It used to be written once, at the open, and never again. The device
  /// then ran past that commit: every later reservation was durable and every
  /// message published under it was on the wire, while the anchor still named
  /// the boot. Restoring ANY snapshot from in between compared equal-or-ahead
  /// against it, read as a clean continuation, burned nothing — and the
  /// positions that snapshot did not carry were derived a second time
  /// (report22 XV-RA1).
  test('a snapshot from after the boot is still caught', () async {
    final store = FakeKvLogStore();
    final storage = HiddenVolumeStorage.fromStore(store);
    final anchor = _MemoryAnchor();
    storage.attachRollbackAnchor(anchor);

    // Boot.
    await checkContainerAgainstAnchor(
      storage: storage,
      anchor: anchor,
      reserveAhead: 32,
    );
    final atBoot = anchor.seq!;

    // The device runs on. This stands for the reservations that make new
    // ciphertext publishable: each is a durable commit, and each advances the
    // anchor through the storage handle.
    for (var i = 0; i < 6; i++) {
      store.commit([
        PutOp(Ns.settings, Uint8List.fromList([i]), Uint8List.fromList([i])),
      ]);
      expect(
        await storage.advanceRollbackAnchor(),
        isTrue,
        reason: 'the anchor refused to move with a durable write',
      );
    }
    final head = store.commitSeq();
    expect(
      anchor.seq,
      head,
      reason: 'the anchor did not follow the container past the boot',
    );

    // Somebody restores a snapshot from BETWEEN the boot and now — valid,
    // newer than the boot, and still missing what came after it.
    final between = atBoot + 2;
    expect(between, lessThan(head), reason: 'premise: strictly in between');
    store.rollbackTo(between);

    final check = await checkContainerAgainstAnchor(
      storage: storage,
      anchor: anchor,
      reserveAhead: 32,
    );
    expect(
      check.verdict,
      AnchorVerdict.rolledBack,
      reason:
          'a snapshot taken after the boot passed as a clean '
          'continuation, so the positions it does not carry are derived '
          'again',
    );
    expect(check.lostSendPositions, greaterThan(0));
  });

  /// A DIFFERENT container is not a container that went backwards.
  ///
  /// The anchor used to hold a bare commit number, so a fresh container after
  /// a wipe — whose counter starts again — read as a rollback at every launch,
  /// burning keys and raising an alarm over nothing (report22 XV-RA2). The
  /// generation is what makes the record a statement about one container.
  test('a fresh container after a wipe is not read as a rollback', () async {
    final first = FakeKvLogStore();
    final firstStorage = HiddenVolumeStorage.fromStore(first);
    final anchor = _MemoryAnchor();
    for (var i = 0; i < 20; i++) {
      first.commit([
        PutOp(Ns.settings, Uint8List.fromList([i]), Uint8List.fromList([i])),
      ]);
    }
    await checkContainerAgainstAnchor(
      storage: firstStorage,
      anchor: anchor,
      reserveAhead: 32,
    );
    expect(anchor.seq, greaterThan(10), reason: 'premise: it ran a while');
    final firstGeneration = anchor.record!.generation;

    // Wiped. The replacement is a different container that happens to start
    // its counter from the beginning again — and nothing cleared the record.
    final second = FakeKvLogStore();
    final check = await checkContainerAgainstAnchor(
      storage: HiddenVolumeStorage.fromStore(second),
      anchor: anchor,
      reserveAhead: 32,
    );
    expect(
      check.verdict,
      AnchorVerdict.firstRun,
      reason:
          'a brand-new container was called a rollback because the old '
          'record outlived the container it was about',
    );
    expect(check.lostSendPositions, 0, reason: 'and nothing was burned');
    expect(
      anchor.record!.generation,
      isNot(firstGeneration),
      reason: 'the record must now be about the container in front of us',
    );
  });

  /// A fork keeps its evidence.
  ///
  /// Only a rollback used to be spared the re-anchor, so a forked timeline was
  /// recorded as the newest thing this device stood behind and the NEXT launch
  /// called it clean. The one record that it was ever a different branch was
  /// destroyed by noticing it (report22 XV-RA3).
  test('a fork is not quietly adopted at the next launch', () async {
    final store = FakeKvLogStore();
    final storage = HiddenVolumeStorage.fromStore(store);
    final anchor = _MemoryAnchor();
    store.commit([
      PutOp(Ns.settings, Uint8List.fromList([1]), Uint8List.fromList([1])),
    ]);
    await checkContainerAgainstAnchor(
      storage: storage,
      anchor: anchor,
      reserveAhead: 32,
    );
    final anchored = anchor.seq!;

    store.forkHistory([
      for (var i = 1; i <= anchored + 3; i++)
        if (i != anchored) i,
    ], seq: anchored + 3);
    final first = await checkContainerAgainstAnchor(
      storage: storage,
      anchor: anchor,
      reserveAhead: 32,
    );
    expect(first.verdict, AnchorVerdict.forked, reason: 'premise');
    expect(
      anchor.seq,
      anchored,
      reason: 'the fork was recorded as ours, so the evidence is gone',
    );

    // The same container, opened again. It must STILL be a fork.
    final second = await checkContainerAgainstAnchor(
      storage: storage,
      anchor: anchor,
      reserveAhead: 32,
    );
    expect(
      second.verdict,
      AnchorVerdict.forked,
      reason: 'the second launch adopted a timeline it had already refused',
    );
  });

  /// An anchor that did not reach the disk says so.
  ///
  /// The interface returned `void`, so a full disk left a stale record while
  /// everything reported success — and the next launch measured against a
  /// commit this device had already moved past (report22 XV-RA4).
  test('an anchor write that fails is reported, not swallowed', () async {
    final store = FakeKvLogStore();
    final storage = HiddenVolumeStorage.fromStore(store);
    final anchor = _MemoryAnchor()..refuse = true;

    final check = await checkContainerAgainstAnchor(
      storage: storage,
      anchor: anchor,
      reserveAhead: 32,
    );
    expect(anchor.writes, greaterThan(0), reason: 'premise: it did try');
    expect(
      check.anchorNotRecorded,
      isTrue,
      reason: 'a refused anchor write was reported as a recorded one',
    );

    // Vacuity: a store that accepts reports nothing wrong.
    anchor.refuse = false;
    final ok = await checkContainerAgainstAnchor(
      storage: storage,
      anchor: anchor,
      reserveAhead: 32,
    );
    expect(ok.anchorNotRecorded, isFalse);
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
    final anchor = _MemoryAnchor()
      ..record = const AnchorRecord(generation: 'aa', seq: 500);
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
