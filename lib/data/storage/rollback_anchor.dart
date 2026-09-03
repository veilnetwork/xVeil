/// Telling a container that moved forward from one that was put back.
///
/// The container carries its own monotonic commit counter, and every
/// conversation's send-position reservation lives INSIDE it, next to the
/// ratchet state those positions belong to (`ratchet_persistence.dart`). That
/// pairing is what makes a rollback dangerous rather than merely annoying:
/// putting an older copy of the container in place restores the ratchet state
/// AND the reservation that was supposed to be ahead of it, so the next send
/// re-derives a key and nonce this device has already put on the wire. Two
/// different plaintexts under one key is not a lost message, it is a broken
/// one, and nothing in the app noticed (report8 M8-14).
///
/// The library provides the two primitives and leaves the policy here
/// (`Space::commit_seq`, `Space::commit_history`; see hidden-volume's
/// `docs/en/guide/multi-device.md`). This file is the policy, and nothing in
/// it does I/O — the decision is a function of four numbers so it can be
/// tested at its edges rather than inferred from a running app.
///
/// **What this defends against, said plainly.** An anchor kept beside the
/// container on the same disk stops a container that was restored, synced
/// backwards, or copied back from a backup — the ways this actually happens.
/// It does not stop an adversary who images the whole disk and puts all of it
/// back at once, because that returns the anchor too. The library says so in
/// as many words, and calling it defence-in-depth is the honest description.
/// Reaching further needs a counter the adversary cannot rewrite: a secure
/// element, or a server that remembers.
library;

/// How far back the container keeps anchors it can still recognise.
///
/// Mirrors `hidden_volume::ANCHOR_HORIZON`, which the FFI does not export —
/// so this copy can drift from the constant it mirrors while everything still
/// compiles. `test/rollback_anchor_test.dart` reads the Rust source and fails
/// when the two disagree, because a horizon that is too large here turns an
/// ordinary long-offline return into an accusation.
const int anchorHorizon = 1024;

/// What an external anchor says about the container that was just opened.
enum AnchorVerdict {
  /// Nothing was anchored yet. The first open of a space, or the first open
  /// after this was added. Record an anchor and carry on.
  firstRun,

  /// The container is at or past the anchor, and the anchored commit is one
  /// it still recognises. The ordinary case.
  clean,

  /// The container is far enough past the anchor that the anchored commit has
  /// aged out of the window. Its absence proves nothing either way, so this is
  /// NOT a fork — it is a device that was away for a long time.
  outOfRange,

  /// The container is BEHIND the anchor: an older copy is in place. Whatever
  /// was committed between the two is gone, and every send position the
  /// missing commits reserved may already have been spent.
  rolledBack,

  /// The container is ahead of the anchor and inside the window, but does not
  /// recognise the anchored commit. Its history is not the one this device
  /// wrote — a different timeline, put here.
  forked,
}

/// The verdict, plus what a caller has to do about it.
class AnchorCheck {
  const AnchorCheck({
    required this.verdict,
    this.lostCommits = 0,
    this.lostSendPositions = 0,
  });

  final AnchorVerdict verdict;

  /// How many commits the container is behind the anchor. Zero unless
  /// [AnchorVerdict.rolledBack].
  final int lostCommits;

  /// An upper bound on how far any one conversation's send position may have
  /// advanced inside those lost commits. Zero unless
  /// [AnchorVerdict.rolledBack]. See [sendPositionsAtRisk].
  final int lostSendPositions;

  /// Whether the container may have been put back far enough that a send
  /// position could be re-used.
  bool get mayReuseSendPositions => verdict == AnchorVerdict.rolledBack;

  /// Whether the timeline is not the one this device wrote. Both of these are
  /// worth telling a person about; only one of them re-uses key material.
  bool get isSuspicious =>
      verdict == AnchorVerdict.rolledBack || verdict == AnchorVerdict.forked;
}

/// An upper bound on the send positions one conversation may have spent
/// inside [lostCommits] commits that are no longer on disk.
///
/// Sound because renewing a reservation COSTS a commit: `reserveBeforePublish`
/// writes one setting per conversation whose reservation ran out, and each of
/// those settings is its own commit. So one conversation cannot renew twice
/// without two commits going by, and `lostCommits` renewals is the most that
/// can hide in `lostCommits` commits — each advancing that conversation by at
/// most [reserveAhead].
///
/// Deliberately an over-estimate. Burning too many positions costs a peer some
/// skipped keys, and past its tolerance costs a re-handshake; burning too few
/// costs a re-used nonce, which cannot be taken back.
int sendPositionsAtRisk({required int lostCommits, required int reserveAhead}) {
  if (lostCommits <= 0 || reserveAhead <= 0) return 0;
  return lostCommits * reserveAhead;
}

/// Judge a freshly-opened container against the anchor recorded for it.
///
/// [anchorSeq] is what was written outside the container after the last
/// commit, `null` when nothing was. [currentSeq] and [history] come from the
/// space just opened (`commitSeq()` / `commitHistory()`).
///
/// THE ORDER OF THE TESTS IS THE POINT. The membership test is the one that
/// says "fork", and it is only meaningful inside the window the container
/// keeps: past that, an anchor is absent because it aged out, not because
/// anybody replaced anything. A host that asks about membership before asking
/// about distance calls every long-offline device an adversary — which the
/// library's own guide warns about, having been written after that mistake.
AnchorCheck checkRollbackAnchor({
  required int? anchorSeq,
  required int currentSeq,
  required List<int> history,
  int horizon = anchorHorizon,
  int reserveAhead = 0,
}) {
  if (anchorSeq == null) {
    return const AnchorCheck(verdict: AnchorVerdict.firstRun);
  }
  // 1. Behind the anchor. Nothing else needs asking: commits that were made
  //    are not here.
  if (currentSeq < anchorSeq) {
    final lost = anchorSeq - currentSeq;
    return AnchorCheck(
      verdict: AnchorVerdict.rolledBack,
      lostCommits: lost,
      lostSendPositions: sendPositionsAtRisk(
        lostCommits: lost,
        reserveAhead: reserveAhead,
      ),
    );
  }
  // 2. Distance BEFORE membership, or step 3 accuses the innocent.
  //
  // TWO distances, because the arithmetic one is only a prediction of what
  // the container kept. `horizon` assumes it retired everything below
  // `current - 1024`; what it ACTUALLY kept is the window it just reported,
  // and that window is shorter after a compaction, after `create_space`, and
  // on any container younger than the horizon. An anchor below the oldest
  // commit the container still knows has aged out whatever the subtraction
  // says, and its absence is not evidence.
  //
  // Found by the wiring test rather than by reading: a space anchored before
  // its first commit came back to a history starting at 1, and the anchor —
  // an honest one, written by this device moments earlier — read as a forged
  // timeline.
  if (currentSeq - anchorSeq > horizon) {
    return const AnchorCheck(verdict: AnchorVerdict.outOfRange);
  }
  if (history.isEmpty || anchorSeq < history.first) {
    return const AnchorCheck(verdict: AnchorVerdict.outOfRange);
  }
  // 3. Inside the window, so the container should still know the commit this
  //    device anchored. If it does not, its history is somebody else's.
  return history.contains(anchorSeq)
      ? const AnchorCheck(verdict: AnchorVerdict.clean)
      : const AnchorCheck(verdict: AnchorVerdict.forked);
}

/// A store whose backing container can answer the two anchor questions.
///
/// NOT part of `KvLogStore`. Only a real container has a commit counter and a
/// history; the in-memory fake and the counting doubles in tests do not, and
/// widening the port would make every one of them answer a question they
/// cannot. A store that does not implement this is simply never anchored.
///
/// That is also the PRIVACY POLICY, not only a convenience. hidden-volume's
/// guide is explicit: anchor the acknowledged space, never a decoy or duress
/// space, because an anchor for a hidden space announces that the space
/// exists. The identities hosted through the multi-space handle are where
/// decoys live, and those views deliberately do not implement this.
abstract interface class CommitAnchorSource {
  /// The container's current monotonic commit counter.
  Future<int> commitSeq();

  /// The commits this container still recognises, ascending. A WINDOW bounded
  /// by [anchorHorizon], not the whole of history.
  Future<List<int>> commitHistory();
}

/// The synchronous half, for the store that runs inside the worker isolate.
abstract interface class SyncCommitAnchorSource {
  int commitSeq();
  List<int> commitHistory();
}

/// What one open of an anchored space reports about itself.
class AnchorReading {
  const AnchorReading({required this.seq, required this.history});

  final int seq;
  final List<int> history;
}

/// Where the anchor is kept — OUTSIDE the container it describes.
///
/// Inside would be worthless: the thing being detected is the container going
/// back in time, and anything inside goes back with it.
abstract interface class RollbackAnchorStore {
  /// The commit this device last recorded, or null when it never has.
  Future<int?> read();

  /// Record [seq] as the newest commit this device stands behind.
  Future<void> write(int seq);
}

/// The commit-anchor questions, asked of a storage handle.
///
/// A handle that cannot answer returns null and is simply never anchored —
/// which is how the decoy policy is kept: the identities hosted through the
/// multi-space handle do not answer, and nothing outside their container ever
/// records that they were opened.
abstract interface class RollbackAnchorReader {
  Future<AnchorReading?> readCommitAnchor();
}

/// Judge a freshly-opened space against its anchor, and record where it now
/// stands.
///
/// Returns [AnchorVerdict.firstRun] — costing nothing and burning nothing —
/// whenever the space is not anchored at all, which is every decoy and every
/// store with no container behind it.
///
/// The new anchor is written for every verdict EXCEPT a rollback. Recording
/// after a rollback would tell the next launch that this older copy is the
/// newest thing this device stands behind, and the evidence would be gone.
Future<AnchorCheck> checkContainerAgainstAnchor({
  required RollbackAnchorReader? storage,
  required RollbackAnchorStore? anchor,
  required int reserveAhead,
}) async {
  if (storage == null || anchor == null) {
    return const AnchorCheck(verdict: AnchorVerdict.firstRun);
  }
  final reading = await storage.readCommitAnchor();
  if (reading == null) {
    return const AnchorCheck(verdict: AnchorVerdict.firstRun);
  }
  final check = checkRollbackAnchor(
    anchorSeq: await anchor.read(),
    currentSeq: reading.seq,
    history: reading.history,
    reserveAhead: reserveAhead,
  );
  if (check.verdict != AnchorVerdict.rolledBack) {
    await anchor.write(reading.seq);
  }
  return check;
}
