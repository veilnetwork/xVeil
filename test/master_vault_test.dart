import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/master_vault.dart';

import 'support/fake_hv_container.dart';

void main() {
  late FakeHvContainer container;
  late MasterVault vault;

  setUp(() async {
    container = FakeHvContainer();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    vault = MasterVault(master, container.storage);
  });

  test('starts with an empty roster', () async {
    expect(await vault.children(), isEmpty);
  });

  test('addChild creates a child space, records it, opens it by keys',
      () async {
    final child = await vault.addChild('alice', 'pw-alice');
    await child.putSetting('who', 'alice');

    final entries = await vault.children();
    expect(entries.map((e) => e.label), ['alice']);
    expect(entries.single.spaceKeys.length, 64);

    // The master reopens the child from its stored keys — no password.
    final reopened = await vault.openChild(entries.single);
    expect(await reopened.getSetting('who'), 'alice');
  });

  test('a child stays openable by its OWN password too', () async {
    final child = await vault.addChild('work', 'pw-work');
    await child.putSetting('k', 'v');

    final direct = container.storage();
    expect(await direct.open(password: 'pw-work'), isTrue);
    expect(await direct.getSetting('k'), 'v');
  });

  test('re-adding a label replaces, does not duplicate', () async {
    await vault.addChild('alice', 'pw-a1');
    await vault.addChild('alice', 'pw-a2');
    final entries = await vault.children();
    expect(entries.length, 1);
    // The newer space's keys are kept.
    final reopened = await vault.openChild(entries.single);
    expect(reopened.isOpen, isTrue);
  });

  test('linkChild records an existing identity as a shared child', () async {
    // An identity created independently (e.g. already a child of the real
    // master) is linked into THIS master too — the shared-decoy case.
    final existing = container.storage();
    await existing.open(password: 'pw-rel', createIfMissing: true);
    await existing.putSetting('who', 'mom');

    await vault.linkChild('relatives', existing);

    final entry =
        (await vault.children()).firstWhere((e) => e.label == 'relatives');
    final viaMaster = await vault.openChild(entry);
    expect(await viaMaster.getSetting('who'), 'mom');
  });

  test('removeChild drops it from the roster but not the space', () async {
    final child = await vault.addChild('temp', 'pw-temp');
    await child.putSetting('k', 'v');
    await vault.removeChild('temp');

    expect(await vault.children(), isEmpty);
    // The space still exists — its own password still opens it.
    final direct = container.storage();
    expect(await direct.open(password: 'pw-temp'), isTrue);
    expect(await direct.getSetting('k'), 'v');
  });

  test('roster persists across a fresh master session', () async {
    await vault.addChild('alice', 'pw-alice');

    final master2 = container.storage();
    await master2.open(password: 'masterpw');
    final vault2 = MasterVault(master2, container.storage);
    expect((await vault2.children()).map((e) => e.label), ['alice']);
  });
}
