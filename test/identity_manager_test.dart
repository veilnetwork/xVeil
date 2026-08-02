import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/identity_manager.dart';

import 'support/fake_hv_container.dart';

void main() {
  late FakeHvContainer container;
  late IdentityManager mgr;

  setUp(() {
    container = FakeHvContainer();
    mgr = IdentityManager(container.storage);
  });

  test('addIdentity creates a child, records it, and it opens by keys', () async {
    await mgr.addIdentity(
      masterPassword: 'master',
      label: 'alice',
      childPassword: 'pw-alice',
      setup: (child) async => child.putSetting('who', 'alice'),
    );

    expect((await mgr.roster('master')).map((e) => e.label), ['alice']);

    final active = await mgr.openIdentity('master', 'alice');
    expect(await active.getSetting('who'), 'alice');
    await active.close();
  });

  test('manages several identities; each opens with the master closed first',
      () async {
    await mgr.addIdentity(
        masterPassword: 'm',
        label: 'me',
        childPassword: 'pw-me',
        setup: (c) async => c.putSetting('who', 'me'));
    await mgr.addIdentity(
        masterPassword: 'm',
        label: 'work',
        childPassword: 'pw-work',
        setup: (c) async => c.putSetting('who', 'worker'));

    expect((await mgr.roster('m')).map((e) => e.label), ['me', 'work']);

    final a = await mgr.openIdentity('m', 'me');
    expect(await a.getSetting('who'), 'me');
    await a.close(); // must close before opening the next (exclusive lock)

    final b = await mgr.openIdentity('m', 'work');
    expect(await b.getSetting('who'), 'worker');
    await b.close();
  });

  test('a child stays openable by its OWN password too', () async {
    await mgr.addIdentity(
        masterPassword: 'm', label: 'x', childPassword: 'pw-x',
        setup: (c) async => c.putSetting('k', 'v'));

    final direct = container.storage();
    expect(await direct.open(password: 'pw-x'), isTrue);
    expect(await direct.getSetting('k'), 'v');
    await direct.close();
  });

  test('re-adding a label replaces it, does not duplicate', () async {
    await mgr.addIdentity(
        masterPassword: 'm', label: 'alice', childPassword: 'pw-a1');
    await mgr.addIdentity(
        masterPassword: 'm', label: 'alice', childPassword: 'pw-a2',
        setup: (c) async => c.putSetting('gen', '2'));

    final roster = await mgr.roster('m');
    expect(roster.length, 1);
    final active = await mgr.openIdentity('m', 'alice');
    expect(await active.getSetting('gen'), '2'); // the newer space's keys
    await active.close();
  });

  test('removeIdentity drops it from the roster but keeps the space', () async {
    await mgr.addIdentity(
        masterPassword: 'm', label: 'temp', childPassword: 'pw-temp',
        setup: (c) async => c.putSetting('k', 'v'));
    await mgr.removeIdentity('m', 'temp');

    expect(await mgr.roster('m'), isEmpty);
    // The space still exists — its own password still opens it.
    final direct = container.storage();
    expect(await direct.open(password: 'pw-temp'), isTrue);
    expect(await direct.getSetting('k'), 'v');
    await direct.close();
  });

  test('the roster persists across sessions', () async {
    await mgr.addIdentity(
        masterPassword: 'm', label: 'alice', childPassword: 'pw-alice');
    final fresh = IdentityManager(container.storage);
    expect((await fresh.roster('m')).map((e) => e.label), ['alice']);
  });

  test('opening an unknown identity throws', () async {
    await mgr.addIdentity(
        masterPassword: 'm', label: 'alice', childPassword: 'pw-alice');
    expect(() => mgr.openIdentity('m', 'ghost'), throwsStateError);
  });

  // The lock is real: holding one identity open and trying to open another
  // (without closing) is rejected — exactly the native exclusive-flock behaviour
  // the manager is built to serialize around.
  test('two identities open at once is rejected (exclusive lock)', () async {
    await mgr.addIdentity(
        masterPassword: 'm', label: 'a', childPassword: 'pw-a');
    await mgr.addIdentity(
        masterPassword: 'm', label: 'b', childPassword: 'pw-b');

    final a = await mgr.openIdentity('m', 'a');
    // 'a' is still open → opening 'b' (which must open the master to read the
    // roster) hits the busy lock.
    expect(() => mgr.openIdentity('m', 'b'), throwsStateError);
    await a.close();
    // After closing, switching works.
    final b = await mgr.openIdentity('m', 'b');
    expect(b.isOpen, isTrue);
    await b.close();
  });

  group('a password that already opens a space', () {
    test('re-using a child password is refused before anything is written',
        () async {
      // Audit X-01, the copy that lived here. A space is DERIVED from its
      // password, so `open(createIfMissing: true)` with one already in use
      // opens the EXISTING space. `setup` then wrote into somebody else's
      // storage, and only afterwards were the keys read back and recorded —
      // leaving two roster rows pointing at one space.
      await mgr.addIdentity(
        masterPassword: 'master',
        label: 'alice',
        childPassword: 'pw-alice',
        setup: (child) async => child.putSetting('who', 'alice'),
      );

      var setupRan = false;
      await expectLater(
        mgr.addIdentity(
          masterPassword: 'master',
          label: 'bob',
          childPassword: 'pw-alice', // the same space
          setup: (child) async {
            setupRan = true;
            await child.putSetting('who', 'bob');
          },
        ),
        throwsA(isA<IdentitySpaceCollision>()),
      );
      expect(setupRan, isFalse, reason: 'nothing may be written on collision');

      // Alice is untouched, and no second row was recorded.
      expect((await mgr.roster('master')).map((e) => e.label), ['alice']);
      final active = await mgr.openIdentity('master', 'alice');
      expect(await active.getSetting('who'), 'alice');
      await active.close();
    });

    test('re-using the MASTER password is refused', () async {
      // The worse case: the master's roster gets replaced by child data, and
      // removing that "child" then takes the master's storage with it.
      await mgr.addIdentity(
        masterPassword: 'master',
        label: 'alice',
        childPassword: 'pw-alice',
      );

      await expectLater(
        mgr.addIdentity(
          masterPassword: 'master',
          label: 'self',
          childPassword: 'master',
        ),
        throwsA(isA<IdentitySpaceCollision>()),
      );
      expect((await mgr.roster('master')).map((e) => e.label), ['alice']);
    });

    test('a fresh password still works', () async {
      // The guard must refuse collisions, not additions.
      await mgr.addIdentity(
        masterPassword: 'master',
        label: 'alice',
        childPassword: 'pw-alice',
      );
      await mgr.addIdentity(
        masterPassword: 'master',
        label: 'bob',
        childPassword: 'pw-bob',
      );
      expect(
        (await mgr.roster('master')).map((e) => e.label).toList()..sort(),
        ['alice', 'bob'],
      );
    });
  });
}
