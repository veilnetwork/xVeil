import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/space_lifecycle.dart';
import 'package:xveil/domain/space_post.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

String _hash(String nibble) => List.filled(64, nibble).join();

void main() {
  test('recoverable deletion and restoration have a strict v2 wire shape', () {
    final spaceId = _id(1);
    final owner = _id(2);
    final checkpoint = SpaceControlCheckpoint([
      SpaceControlHead(author: owner, seq: 3, hash: _hash('a')),
    ]);
    final deleted = SpaceLifecycleTransition(
      spaceId: spaceId,
      state: SpaceLifecycleState.deleted,
      previousTransitionHash: '',
      controlCheckpoint: checkpoint,
      contentPolicyVersion: 4,
      messageHeads: const [],
      postHeads: const [],
      reactionHeads: const [],
      changedAtMs: 1000,
      recoveryDeadlineMs: 2000,
    );

    expect(deleted.isStructurallyValid, isTrue);
    expect(deleted.toJson()['v'], 2);
    expect(
      SpaceLifecycleTransition.fromJson(deleted.toJson())?.state,
      SpaceLifecycleState.deleted,
    );

    final missingDeadline = Map<String, dynamic>.from(deleted.toJson())
      ..['v'] = 1
      ..remove('recoveryDeadline');
    expect(SpaceLifecycleTransition.fromJson(missingDeadline), isNull);

    final lateRestore = Map<String, dynamic>.from(deleted.toJson())
      ..['state'] = SpaceLifecycleState.active.name
      ..['previous'] = _hash('b')
      ..['ts'] = 2001;
    expect(SpaceLifecycleTransition.fromJson(lateRestore), isNull);

    final restored = Map<String, dynamic>.from(deleted.toJson())
      ..['state'] = SpaceLifecycleState.active.name
      ..['previous'] = _hash('b')
      ..['ts'] = 1999;
    expect(
      SpaceLifecycleTransition.fromJson(restored)?.state,
      SpaceLifecycleState.active,
    );
  });

  test('deletion tombstone rejects an impossible pre-deadline purge', () {
    final valid = SpaceDeletionTombstone(
      spaceId: _id(3),
      deleteTransitionHash: _hash('c'),
      recoveryDeadlineMs: 2000,
      purgedAtMs: 2000,
    );
    expect(valid.isStructurallyValid, isTrue);
    expect(
      SpaceDeletionTombstone.fromJson(valid.toJson())?.deleteTransitionHash,
      valid.deleteTransitionHash,
    );
    final invalid = Map<String, dynamic>.from(valid.toJson())
      ..['purgedAt'] = 1999;
    expect(SpaceDeletionTombstone.fromJson(invalid), isNull);
  });
}
