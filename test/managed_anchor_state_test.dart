import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_anchor_state.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_metadata_blob.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';

final _id = ManagedIdentityId('1' * 32);
String _root(int index) => index.toRadixString(16).padLeft(64, '0');
ManagedGeneration _old() =>
    ManagedGeneration(marker: 'a' * 64, innerFloor: 1, offset: 0);
ManagedAnchorState _initial() =>
    ManagedAnchorState.initial(identity: _id, generation: _old());
ManagedAnchorSnapshot _source(ManagedAnchorState state, {int sequence = 20}) =>
    state.resolve(
      contentIdentity: _id,
      contentMarker: 'a' * 64,
      innerSequence: sequence,
      innerRoots: {
        for (
          var i = sequence > anchorHorizon ? sequence - anchorHorizon : 1;
          i <= sequence;
          i++
        )
          i: _root(i),
      },
    );
ManagedAnchorState _prepared(ManagedAnchorState state) => state.prepare(
  source: _source(state),
  replacement: ManagedGeneration(marker: 'b' * 64, innerFloor: 3, offset: 18),
);

void main() {
  test(
    'repack retains the old host anchor while advancing the logical head',
    () {
      final pending = ManagedAnchorState.decode(_prepared(_initial()).encode());
      final snapshot = pending.resolve(
        contentIdentity: _id,
        contentMarker: 'b' * 64,
        innerSequence: 3,
        innerRoots: {1: _root(100), 2: _root(101), 3: _root(102)},
      );
      expect(snapshot.sequence, 21);
      expect(snapshot.roots[20], _root(20));
      expect(snapshot.roots[21], _root(102));
      expect(
        checkRollbackAnchor(
          anchorSeq: 20,
          anchorRoot: _root(20),
          currentSeq: snapshot.sequence,
          history: snapshot.history,
          roots: snapshot.roots,
        ).verdict,
        AnchorVerdict.clean,
      );
      final settled = pending.settle(snapshot);
      expect(settled.prepared, isNull);
      expect(settled.active.marker, 'b' * 64);
      final cold = ManagedAnchorState.decode(settled.encode()).resolve(
        contentIdentity: _id,
        contentMarker: 'b' * 64,
        innerSequence: 4,
        innerRoots: {
          1: _root(100),
          2: _root(101),
          3: _root(102),
          4: _root(103),
        },
      );
      expect(cold.sequence, 22);
      expect(cold.roots[20], _root(20));
      expect(cold.roots[22], _root(103));
    },
  );

  test('unpublished preparation chooses the authenticated old content', () {
    final pending = ManagedAnchorState.decode(_prepared(_initial()).encode());
    final old = _source(pending);
    expect(old.sequence, 20);
    final settled = pending.settle(old);
    expect(settled.active.marker, 'a' * 64);
    expect(settled.prepared, isNull);
    expect(
      _source(
        ManagedAnchorState.decode(settled.encode()),
        sequence: 21,
      ).sequence,
      21,
    );
    expect(
      () => _source(pending, sequence: 21),
      throwsStateError,
      reason:
          'source must not change while the native publisher holds its lease',
    );
    expect(() => _source(settled, sequence: 19), throwsStateError);
  });

  test(
    'replaying either file is refused and replaying both is detected by host anchor',
    () {
      final initial = _initial();
      final pending = _prepared(initial);
      final replacement = pending.resolve(
        contentIdentity: _id,
        contentMarker: 'b' * 64,
        innerSequence: 3,
        innerRoots: {3: _root(102)},
      );
      final complete = pending.settle(replacement);
      expect(() => _source(complete), throwsStateError);
      expect(
        () => initial.resolve(
          contentIdentity: _id,
          contentMarker: 'b' * 64,
          innerSequence: 3,
          innerRoots: {3: _root(102)},
        ),
        throwsStateError,
      );
      final rolledBack = _source(initial);
      expect(
        checkRollbackAnchor(
          anchorSeq: replacement.sequence,
          anchorRoot: replacement.roots[replacement.sequence],
          currentSeq: rolledBack.sequence,
          history: rolledBack.history,
          roots: rolledBack.roots,
        ).verdict,
        AnchorVerdict.rolledBack,
      );
    },
  );

  test(
    'copied staging history cannot shadow source commits with the same projected number',
    () {
      final pending = _prepared(_initial());
      final snapshot = pending.resolve(
        contentIdentity: _id,
        contentMarker: 'b' * 64,
        innerSequence: 3,
        innerRoots: {1: _root(500), 2: _root(501), 3: _root(502)},
      );
      expect(snapshot.roots[19], _root(19));
      expect(snapshot.roots[20], _root(20));
      expect(snapshot.roots[21], _root(502));
    },
  );

  test('history stays bounded and eventually ages out old anchors', () {
    final state = _initial();
    final pending = state.prepare(
      source: _source(state, sequence: 2000),
      replacement: ManagedGeneration(
        marker: 'b' * 64,
        innerFloor: 3,
        offset: 1998,
      ),
    );
    expect(pending.encode().length, lessThan(ManagedMetadataBlob.maxBytes));
    expect(
      ManagedAnchorState.decode(pending.encode()).encode(),
      pending.encode(),
    );
    final snapshot = pending.resolve(
      contentIdentity: _id,
      contentMarker: 'b' * 64,
      innerSequence: 1028,
      innerRoots: {for (var i = 4; i <= 1028; i++) i: _root(i + 10000)},
    );
    expect(snapshot.roots.length, anchorHorizon + 1);
    expect(snapshot.history.first, 2002);
    expect(snapshot.sequence, 3026);
    expect(
      checkRollbackAnchor(
        anchorSeq: 2000,
        anchorRoot: _root(2000),
        currentSeq: snapshot.sequence,
        history: snapshot.history,
        roots: snapshot.roots,
      ).verdict,
      AnchorVerdict.outOfRange,
    );
  });

  test(
    'wrong owner, marker, absent head, fork and malformed roots fail closed',
    () {
      final state = _initial();
      final snapshot = _source(state);
      final pending = _prepared(state);
      expect(
        () => _initial().prepare(
          source: snapshot,
          replacement: pending.prepared!,
        ),
        throwsStateError,
      );
      expect(() => pending.settle(snapshot), throwsStateError);
      expect(
        () => state.resolve(
          contentIdentity: ManagedIdentityId('2' * 32),
          contentMarker: 'a' * 64,
          innerSequence: 20,
          innerRoots: {20: _root(20)},
        ),
        throwsStateError,
      );
      expect(
        () => state.resolve(
          contentIdentity: _id,
          contentMarker: 'c' * 64,
          innerSequence: 20,
          innerRoots: {20: _root(20)},
        ),
        throwsStateError,
      );
      expect(
        () => state.resolve(
          contentIdentity: _id,
          contentMarker: 'a' * 64,
          innerSequence: 20,
          innerRoots: {19: _root(19)},
        ),
        throwsStateError,
      );
      expect(
        () => pending.resolve(
          contentIdentity: _id,
          contentMarker: 'a' * 64,
          innerSequence: 20,
          innerRoots: {20: _root(999)},
        ),
        throwsStateError,
      );
      expect(
        () => state.resolve(
          contentIdentity: _id,
          contentMarker: 'a' * 64,
          innerSequence: 20,
          innerRoots: {20: 'PRIVATE_INVALID_ROOT'},
        ),
        throwsStateError,
      );
      expect(
        () => pending.resolve(
          contentIdentity: _id,
          contentMarker: 'b' * 64,
          innerSequence: 2,
          innerRoots: {2: _root(2)},
        ),
        throwsStateError,
      );
    },
  );

  test('negative offsets work and additions cannot wrap sequence integers', () {
    final negative = ManagedGeneration(
      marker: 'b' * 64,
      innerFloor: 100,
      offset: -79,
    );
    expect(negative.logicalFloor, 21);
    expect(negative.project(101), 22);
    final full = ManagedGeneration(
      marker: 'b' * 64,
      innerFloor: 1,
      offset: 0x7ffffffffffffffe,
    );
    expect(full.project(1), 0x7fffffffffffffff);
    expect(() => full.project(2), throwsStateError);
    expect(
      () => ManagedGeneration(marker: 'b' * 64, innerFloor: 1, offset: -1),
      throwsArgumentError,
    );
    expect(
      () => ManagedGeneration(
        marker: 'b' * 64,
        innerFloor: 1,
        offset: -0x7fffffffffffffff - 1,
      ),
      throwsArgumentError,
    );
  });

  test(
    'prepared generation must advance exactly once and use a fresh marker',
    () {
      final state = _initial();
      for (final generation in [
        ManagedGeneration(marker: 'a' * 64, innerFloor: 3, offset: 18),
        ManagedGeneration(marker: 'b' * 64, innerFloor: 3, offset: 17),
        ManagedGeneration(marker: 'b' * 64, innerFloor: 3, offset: 19),
      ]) {
        expect(
          () => state.prepare(source: _source(state), replacement: generation),
          throwsArgumentError,
        );
      }
      final pending = _prepared(state);
      expect(
        () => pending.prepare(
          source: _source(pending),
          replacement: pending.prepared!,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'serialized state rejects truncation, trailing data and invalid counters',
    () {
      final encoded = _prepared(_initial()).encode();
      for (var length = 0; length < encoded.length; length++) {
        expect(
          () => ManagedAnchorState.decode(encoded.sublist(0, length)),
          throwsFormatException,
        );
      }
      expect(
        () => ManagedAnchorState.decode(Uint8List.fromList([...encoded, 0])),
        throwsFormatException,
      );
      for (final offset in [0, 4, 5, 6, 7, 24]) {
        final bad = Uint8List.fromList(encoded)..[offset] = 255;
        expect(() => ManagedAnchorState.decode(bad), throwsFormatException);
      }
      final maximumCount = Uint8List.fromList(encoded)
        ..[128] = 255
        ..[129] = 255;
      expect(
        () => ManagedAnchorState.decode(maximumCount),
        throwsFormatException,
      );
      final duplicateRoot = Uint8List.fromList(encoded)
        ..setRange(170, 178, encoded.sublist(130, 138));
      expect(
        () => ManagedAnchorState.decode(duplicateRoot),
        throwsFormatException,
      );
    },
  );

  test('snapshots and decoded state own their input history', () {
    final state = _initial();
    final input = {1: _root(1)};
    final snapshot = state.resolve(
      contentIdentity: _id,
      contentMarker: 'a' * 64,
      innerSequence: 1,
      innerRoots: input,
    );
    input[1] = _root(2);
    expect(snapshot.roots[1], _root(1));
    expect(() => snapshot.roots[1] = _root(3), throwsUnsupportedError);
    final pending = state.prepare(
      source: snapshot,
      replacement: ManagedGeneration(
        marker: 'b' * 64,
        innerFloor: 1,
        offset: 1,
      ),
    );
    final bytes = pending.encode();
    final decoded = ManagedAnchorState.decode(bytes);
    bytes.fillRange(0, bytes.length, 0);
    expect(decoded.encode(), pending.encode());
    expect(() => decoded.retainedRoots.clear(), throwsUnsupportedError);
  });
}
