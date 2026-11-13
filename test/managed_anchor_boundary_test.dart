import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_anchor_state.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_metadata_blob.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';

String root(int n) => n.toRadixString(16).padLeft(64, '0');

void main() {
  test('untrimmed native epochs yield the inclusive bounded host window', () {
    final id = ManagedIdentityId('1' * 32);
    final state = ManagedAnchorState.initial(
      identity: id,
      generation: ManagedGeneration(marker: 'a' * 64, innerFloor: 1, offset: 0),
    );
    const head = 1200;
    final snapshot = state.resolve(
      contentIdentity: id,
      contentMarker: 'a' * 64,
      innerSequence: head,
      innerRoots: {for (var n = 1; n <= head; n++) n: root(n)},
    );
    expect(snapshot.roots.length, anchorHorizon + 1);
    expect(snapshot.history.first, head - anchorHorizon);
    expect(
      checkRollbackAnchor(
        anchorSeq: head - anchorHorizon,
        anchorRoot: root(head - anchorHorizon),
        currentSeq: snapshot.sequence,
        history: snapshot.history,
        roots: snapshot.roots,
      ).verdict,
      AnchorVerdict.clean,
    );
    expect(
      () => state.resolve(
        contentIdentity: id,
        contentMarker: 'a' * 64,
        innerSequence: head,
        innerRoots: {1: 'invalid-old-root', head: root(head)},
      ),
      throwsStateError,
    );
  });
  test(
    'prepared codec and settled generation retain the exact horizon boundary',
    () {
      final id = ManagedIdentityId('1' * 32);
      final state = ManagedAnchorState.initial(
        identity: id,
        generation: ManagedGeneration(
          marker: 'a' * 64,
          innerFloor: 1,
          offset: 0,
        ),
      );
      const head = 1200;
      final source = state.resolve(
        contentIdentity: id,
        contentMarker: 'a' * 64,
        innerSequence: head,
        innerRoots: {
          for (var n = head - anchorHorizon; n <= head; n++) n: root(n),
        },
      );
      final prepared = state.prepare(
        source: source,
        replacement: ManagedGeneration(
          marker: 'b' * 64,
          innerFloor: 3,
          offset: head - 2,
        ),
      );
      expect(prepared.encode().length, lessThan(ManagedMetadataBlob.maxBytes));
      final pending = ManagedAnchorState.decode(prepared.encode());
      final published = pending.resolve(
        contentIdentity: id,
        contentMarker: 'b' * 64,
        innerSequence: 3,
        innerRoots: {3: root(9000)},
      );
      final complete = ManagedAnchorState.decode(
        pending.settle(published).encode(),
      );
      final observed = complete.resolve(
        contentIdentity: id,
        contentMarker: 'b' * 64,
        innerSequence: 3,
        innerRoots: {3: root(9000)},
      );
      final boundary = observed.sequence - anchorHorizon;
      expect(observed.roots.length, anchorHorizon + 1);
      expect(
        checkRollbackAnchor(
          anchorSeq: boundary,
          anchorRoot: root(boundary),
          currentSeq: observed.sequence,
          history: observed.history,
          roots: observed.roots,
        ).verdict,
        AnchorVerdict.clean,
      );
      expect(
        checkRollbackAnchor(
          anchorSeq: boundary - 1,
          anchorRoot: root(boundary - 1),
          currentSeq: observed.sequence,
          history: observed.history,
          roots: observed.roots,
        ).verdict,
        AnchorVerdict.outOfRange,
      );
    },
  );
}
