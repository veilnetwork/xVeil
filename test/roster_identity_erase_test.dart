import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/roster_identity_erase.dart';
import 'package:xveil/domain/pending_identity_erase.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

class _Master extends HiddenVolumeStorage {
  _Master() : super.fromStore(FakeKvLogStore());
  bool failIntentBefore = false,
      failIntentAfter = false,
      failRosterBefore = false,
      failRosterAfter = false,
      failClearBefore = false;
  void Function()? afterIntent, afterRoster;
  @override
  Future<void> putSetting(String key, String value) async {
    if (key == kPendingIdentityErase && value.isNotEmpty && failIntentBefore) {
      failIntentBefore = false;
      throw StateError('fixture intent refusal');
    }
    if (key == kPendingIdentityErase && value.isEmpty && failClearBefore) {
      failClearBefore = false;
      throw StateError('fixture clear refusal');
    }
    await super.putSetting(key, value);
    if (key == kPendingIdentityErase && value.isNotEmpty) {
      afterIntent?.call();
      if (failIntentAfter) {
        failIntentAfter = false;
        throw StateError('fixture lost intent reply');
      }
    }
  }

  @override
  Future<void> saveRoster(List<RosterEntry> rows) async {
    if (failRosterBefore) {
      failRosterBefore = false;
      throw StateError('fixture roster refusal');
    }
    await super.saveRoster(rows);
    afterRoster?.call();
    if (failRosterAfter) {
      failRosterAfter = false;
      throw StateError('fixture lost roster reply');
    }
  }
}

void main() {
  late _Master master;
  late Uint8List masterKeys;
  late List<RosterEntry> original;
  late ManagedStorageLocator root;
  final ownedKeys = <Uint8List>[];
  late bool alive;
  late int erases;
  Uint8List? observedTargetKeys;
  ManagedStorageLocator locator(int i) => ManagedStorageLocator(
    id: ManagedIdentityId('$i' * 32),
    protection: StorageProtection.encrypted,
  );
  void retain(List<RosterEntry> rows) =>
      ownedKeys.addAll(rows.map((e) => e.spaceKeys));
  void check() {
    if (!alive) throw StateError('fixture lifecycle ended');
  }

  Future<void> erase(RosterEntry entry) async {
    erases++;
    observedTargetKeys = entry.spaceKeys;
    expect(entry.storageLocator, original[1].storageLocator);
    expect(entry.spaceKeys, original[1].spaceKeys);
    expect(await master.getSetting(kPendingIdentityErase), isNotEmpty);
  }

  Future<List<RosterEntry>> read() async {
    final rows = (await master.loadRoster())!;
    retain(rows);
    return rows;
  }

  Future<List<RosterEntry>> start({
    Future<void> Function(RosterEntry)? action,
  }) => RosterIdentityErase.start(
    master: master,
    root: root,
    masterKeys: masterKeys,
    roster: original,
    target: original[1],
    check: check,
    erase: action ?? erase,
    retainRoster: retain,
  );
  Future<List<RosterEntry>> resume() async => RosterIdentityErase.resume(
    master: master,
    root: root,
    masterKeys: masterKeys,
    roster: await read(),
    check: check,
    erase: erase,
    retainRoster: retain,
  );
  setUp(() async {
    master = _Master();
    masterKeys = Uint8List.fromList(List.filled(64, 9));
    root = locator(9);
    original = [
      for (var i = 1; i <= 2; i++)
        RosterEntry(
          label: 'fixture-$i',
          storageLocator: locator(i),
          spaceKeys: Uint8List.fromList(List.filled(64, i)),
        ),
    ];
    retain(original);
    ownedKeys.add(masterKeys);
    alive = true;
    erases = 0;
    observedTargetKeys = null;
    await master.saveRoster(original);
  });
  tearDown(() async {
    await master.close();
    for (final key in ownedKeys) {
      key.fillRange(0, key.length, 0);
    }
    ownedKeys.clear();
  });

  test(
    'codec binds the hidden parent, is bounded and destroys owned keys only',
    () {
      final intent = PendingIdentityErase.authorized(
        root: const LegacyStorageLocator(),
        masterKeys: masterKeys,
        target: original[1],
      );
      final encoded = intent.encode();
      expect(
        utf8.encode(encoded).length,
        lessThan(PendingIdentityErase.maxEncodedBytes),
      );
      expect(encoded, isNot(contains(original[1].label)));
      final decoded = PendingIdentityErase.decode(encoded);
      expect(decoded.matches(original[1]), isTrue);
      expect(
        () => decoded.validate(const LegacyStorageLocator(), Uint8List(64)),
        throwsA(isA<IdentityEraseFailure>()),
      );
      decoded.destroy();
      intent.destroy();
      expect(() => decoded.encode(), throwsA(isA<IdentityEraseFailure>()));
      expect(original[1].spaceKeys, everyElement(2));
      for (final source in [
        '{}',
        '{',
        encoded.replaceFirst('"v":1', '"v":2'),
        'a' * 1025,
      ]) {
        expect(
          () => PendingIdentityErase.decode(source),
          throwsA(isA<IdentityEraseFailure>()),
        );
      }
    },
  );

  test(
    'durable intent precedes erase; parent roster precedes clearing intent',
    () async {
      final updated = await start();
      expect(updated.map((e) => e.label), ['fixture-1']);
      expect((await read()).map((e) => e.label), ['fixture-1']);
      expect(await master.getSetting(kPendingIdentityErase), '');
      expect(erases, 1);
      expect(observedTargetKeys, everyElement(0));
      expect(original[1].spaceKeys, everyElement(2));
    },
  );

  for (final after in [false, true]) {
    test(
      'intent ${after ? 'reply loss' : 'refusal'} never starts premature erasure',
      () async {
        if (after) {
          master.failIntentAfter = true;
        } else {
          master.failIntentBefore = true;
        }
        await expectLater(start(), throwsStateError);
        expect(erases, 0);
        expect((await read()).length, 2);
        expect(
          (await master.getSetting(kPendingIdentityErase))?.isNotEmpty ?? false,
          after,
        );
        if (after) {
          await resume();
          expect(erases, 1);
        }
      },
    );
  }

  test(
    'lost roster save response resumes against the already reduced roster',
    () async {
      master.failRosterAfter = true;
      await expectLater(start(), throwsStateError);
      expect((await read()).length, 1);
      expect(await master.getSetting(kPendingIdentityErase), isNotEmpty);
      expect((await resume()).length, 1);
      expect(erases, 2);
      expect(await master.getSetting(kPendingIdentityErase), '');
    },
  );

  test(
    'failed intent clear retries without losing the surviving child',
    () async {
      master.failClearBefore = true;
      await expectLater(start(), throwsStateError);
      expect((await read()).single.label, 'fixture-1');
      expect((await resume()).single.label, 'fixture-1');
      expect(await master.getSetting(kPendingIdentityErase), '');
    },
  );

  test(
    'failed roster publication leaves intent and old roster for retry',
    () async {
      master.failRosterBefore = true;
      await expectLater(start(), throwsStateError);
      expect((await read()).length, 2);
      expect(await master.getSetting(kPendingIdentityErase), isNotEmpty);
      expect((await resume()).single.label, 'fixture-1');
      expect(erases, 2);
    },
  );

  test('reload preserves a new row reusing the deleted label', () async {
    final replacement = RosterEntry(
      label: original[1].label,
      storageLocator: locator(3),
      spaceKeys: Uint8List.fromList(List.filled(64, 3)),
    );
    ownedKeys.add(replacement.spaceKeys);
    final updated = await start(
      action: (entry) async {
        await erase(entry);
        await master.saveRoster([original[0], replacement]);
      },
    );
    expect(updated.map((e) => e.storageLocator), [
      original[0].storageLocator,
      replacement.storageLocator,
    ]);
  });

  test(
    'lock after durable intent leaves authorized work for the next unlock',
    () async {
      master.afterIntent = () => alive = false;
      await expectLater(start(), throwsStateError);
      expect(erases, 0);
      master.afterIntent = null;
      alive = true;
      expect((await resume()).single.label, 'fixture-1');
    },
  );

  test(
    'lock during erase cannot save or publish the old continuation',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final deleting = start(
        action: (entry) async {
          await erase(entry);
          entered.complete();
          await release.future;
        },
      );
      await entered.future;
      alive = false;
      final rejected = expectLater(deleting, throwsStateError);
      release.complete();
      await rejected;
      expect((await read()).length, 2);
      expect(observedTargetKeys, everyElement(0));
      alive = true;
      expect((await resume()).length, 1);
    },
  );

  test(
    'lock after roster publication preserves the uncleared intent',
    () async {
      master.afterRoster = () => alive = false;
      await expectLater(start(), throwsStateError);
      expect((await read()).length, 1);
      expect(await master.getSetting(kPendingIdentityErase), isNotEmpty);
      master.afterRoster = null;
      alive = true;
      expect((await resume()).length, 1);
    },
  );

  test('another pending target is never overwritten', () async {
    final other = PendingIdentityErase.authorized(
      root: root,
      masterKeys: masterKeys,
      target: original[0],
    );
    final encoded = other.encode();
    other.destroy();
    await master.putSetting(kPendingIdentityErase, encoded);
    await expectLater(start(), throwsA(isA<IdentityEraseFailure>()));
    expect(erases, 0);
    expect(await master.getSetting(kPendingIdentityErase), encoded);
  });

  test('master-target and last-child guards precede all writes', () async {
    final self = original[1].copyWith(spaceKeys: masterKeys);
    await expectLater(
      RosterIdentityErase.start(
        master: master,
        root: root,
        masterKeys: masterKeys,
        roster: [original[0], self],
        target: self,
        check: check,
        erase: erase,
        retainRoster: retain,
      ),
      throwsA(isA<IdentityEraseFailure>()),
    );
    await expectLater(
      RosterIdentityErase.start(
        master: master,
        root: root,
        masterKeys: masterKeys,
        roster: [original[1]],
        target: original[1],
        check: check,
        erase: erase,
        retainRoster: retain,
      ),
      throwsA(isA<IdentityEraseFailure>()),
    );
    expect(await master.getSetting(kPendingIdentityErase), isNull);
    expect(erases, 0);
  });
}
