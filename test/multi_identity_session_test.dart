import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/multi_identity_session.dart';
import 'package:xveil/domain/roster.dart';

import 'support/fake_multi_space.dart';

Uint8List _keys(int seed) => Uint8List.fromList(List.filled(64, seed));

RosterEntry _e(String label, int seed, {bool anonymous = false}) =>
    RosterEntry(label: label, spaceKeys: _keys(seed), anonymous: anonymous);

void main() {
  test('planIdentityBoots assigns a distinct space/dir/port per identity', () {
    final backing = FakeMultiSpaceBacking();
    final roster = [
      _e('alice', 1),
      _e('work', 2, anonymous: true),
      _e('relatives', 3),
    ];

    final specs = planIdentityBoots(roster, backing,
        runtimeDirBase: '/run', listenPortBase: 9000);

    expect(specs.map((s) => s.label), ['alice', 'work', 'relatives']);
    // Distinct hosted space ids.
    expect(specs.map((s) => s.spaceId).toSet().length, 3);
    // Distinct ports, offset from the base.
    expect(specs.map((s) => s.listenPort), [9000, 9001, 9002]);
    // Per-identity runtime dirs.
    expect(specs[0].runtimeDir, '/run/alice');
    expect(specs[1].runtimeDir, '/run/work');
    // The anonymous flag carries through.
    expect(specs.map((s) => s.anonymous), [false, true, false]);
  });

  test('bootAll hosts every identity storage even when a node boot fails',
      () async {
    final backing = FakeMultiSpaceBacking();
    // Inject a boot that always fails — exercises orchestration without a node.
    final session = MultiIdentitySession(
      backing,
      runtimeDirBase: '/run',
      listenPortBase: 9000,
      boot: (spec, storage) async => throw StateError('no node in test'),
    );

    await session.bootAll([_e('alice', 1), _e('bob', 2)]);

    // Storage views are hosted for both, usable simultaneously...
    expect(session.labels.toSet(), {'alice', 'bob'});
    final alice = session.storageFor('alice')!;
    final bob = session.storageFor('bob')!;
    await alice.putSetting('k', 'alice-val');
    await bob.putSetting('k', 'bob-val');
    expect(await alice.getSetting('k'), 'alice-val');
    expect(await bob.getSetting('k'), 'bob-val');
    // ...while no node came up (boot failed) — best-effort.
    expect(session.stackFor('alice'), isNull);
    expect(session.stackFor('bob'), isNull);
  });
}
