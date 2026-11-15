import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/master_setup_journal.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/master_setup_intent.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_initialization.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_setup.dart';

Uint8List key(int value) => Uint8List(64)..fillRange(0, 64, value);
final root = ManagedStorageLocator(
  id: ManagedIdentityId('a' * 32),
  protection: StorageProtection.encrypted,
);
final child = ManagedStorageLocator(
  id: ManagedIdentityId('b' * 32),
  protection: StorageProtection.encrypted,
);

class Raw extends FakeKvLogStore {
  Raw(int value) : super(keys: key(value));
  int commits = 0;
  bool rejectFinish = false, loseFinish = false;
  void Function(List<KvLogOp>)? after;
  @override
  int commit(List<KvLogOp> ops) {
    commits++;
    final finish = ops.whereType<PutOp>().any(
      (op) =>
          utf8.decode(op.key) == 'set:$kPendingMasterSetupSetting' &&
          utf8.decode(op.value) == '0',
    );
    if (finish && rejectFinish) throw StateError('synthetic refused finish');
    final result = super.commit(ops);
    after?.call(ops);
    if (finish && loseFinish) {
      loseFinish = false;
      throw StateError('synthetic lost finish reply');
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Raw parentRaw, childRaw;
  late HiddenVolumeStorage parent, candidate;
  late MasterSetupIntent intent;
  setUp(() async {
    parentRaw = Raw(1);
    childRaw = Raw(4);
    parent = HiddenVolumeStorage.fromStore(parentRaw);
    candidate = HiddenVolumeStorage.fromStore(childRaw);
    final base = MasterSetupIntent.create(
      root: root,
      keys: key(1),
      base: [RosterEntry(label: 'original', spaceKeys: key(3))],
      childLocator: child,
      childLabel: 'planned child',
    );
    try {
      await MasterSetupJournal.prepare(
        storage: parent,
        intent: base,
        root: root,
        keys: key(1),
        check: () {},
      );
      intent = await MasterSetupJournal.attachChild(
        storage: parent,
        intent: base,
        childKeys: key(4),
        root: root,
        keys: key(1),
        check: () {},
      );
    } finally {
      base.destroy();
    }
  });
  tearDown(() async {
    intent.destroy();
    await parent.close();
    await candidate.close();
  });
  Future<MasterSetupChildProof> initialize({void Function()? check}) =>
      MasterSetupJournal.initializeChild(
        storage: candidate,
        intent: intent,
        child: child,
        childKeys: key(4),
        check: check ?? () {},
      );
  Future<void> finish(MasterSetupChildProof proof, {void Function()? check}) =>
      MasterSetupJournal.publishAndFinish(
        storage: parent,
        intent: intent,
        childProof: proof,
        root: root,
        keys: key(1),
        check: check ?? () {},
      );
  final failure = isA<MasterSetupFailure>();

  test(
    'child and master finish; receipt cannot resurrect a later unbound row',
    () async {
      final proof = await initialize();
      expect(
        await candidate.loadProfile(),
        const UserProfile(displayName: 'planned child'),
      );
      expect(await candidate.getSetting(kPendingIdentitySetupSetting), '0');
      final childCommits = childRaw.commits;
      await initialize();
      expect(childRaw.commits, childCommits);
      await finish(proof);
      expect(await parent.getSetting(kPendingMasterSetupSetting), '0');
      expect(await parent.loadProfile(), isNull);
      final rows = (await parent.loadRoster())!;
      expect(rows.map((r) => r.label), ['original', 'planned child']);
      final bytes = (await parent.loadFile(kMasterSetupJournalFile))!;
      final receipt = jsonDecode(utf8.decode(bytes));
      expect(receipt, {'v': 1, 'complete': true, 'digest': isA<String>()});
      expect(base64.decode(receipt['digest'] as String), hasLength(32));
      bytes.fillRange(0, bytes.length, 0);
      await parent.saveRoster([rows.first]);
      final commits = parentRaw.commits;
      await finish(proof);
      expect(parentRaw.commits, commits);
      expect((await parent.loadRoster())!.map((r) => r.label), ['original']);
      for (final row in rows) {
        row.spaceKeys.fillRange(0, 64, 0);
      }
    },
  );

  test(
    'refused final publication leaves full roster and original intent pending',
    () async {
      final proof = await initialize();
      parentRaw.rejectFinish = true;
      await expectLater(finish(proof), throwsA(failure));
      expect(await parent.getSetting(kPendingMasterSetupSetting), '1');
      final saved = (await MasterSetupJournal.read(parent, () {}))!;
      expect(saved.same(intent), isTrue);
      saved.destroy();
      expect((await parent.loadRoster())!.map((r) => r.label), [
        'original',
        'planned child',
      ]);
      parentRaw.rejectFinish = false;
      await finish(proof);
      expect(await parent.getSetting(kPendingMasterSetupSetting), '0');
    },
  );

  test('lost final reply retains completion; retry makes no writes', () async {
    final proof = await initialize();
    parentRaw.loseFinish = true;
    await expectLater(finish(proof), throwsA(failure));
    expect(await parent.getSetting(kPendingMasterSetupSetting), '0');
    final commits = parentRaw.commits;
    await finish(proof);
    expect(parentRaw.commits, commits);
  });

  test(
    'cancellation after finish preserves the accepted receipt and roster',
    () async {
      final proof = await initialize();
      var current = true;
      parentRaw.after = (ops) {
        if (ops.whereType<PutOp>().any(
          (op) =>
              utf8.decode(op.key) == 'set:$kPendingMasterSetupSetting' &&
              utf8.decode(op.value) == '0',
        )) {
          current = false;
        }
      };
      await expectLater(
        finish(
          proof,
          check: () {
            if (!current) throw StateError('synthetic cancelled generation');
          },
        ),
        throwsA(failure),
      );
      expect(await parent.getSetting(kPendingMasterSetupSetting), '0');
      final commits = parentRaw.commits;
      await finish(proof);
      expect(parentRaw.commits, commits);
    },
  );

  test('changed accepted roster is preserved on finish refusal', () async {
    final proof = await initialize();
    await parent.saveRoster([RosterEntry(label: 'changed', spaceKeys: key(9))]);
    final commits = parentRaw.commits;
    await expectLater(finish(proof), throwsA(failure));
    expect(parentRaw.commits, commits);
    expect((await parent.loadRoster())!.single.label, 'changed');
    expect(await parent.getSetting(kPendingMasterSetupSetting), '1');
  });

  test(
    'proof for a different authenticated plan cannot complete this master',
    () async {
      final other = MasterSetupIntent.create(
        root: root,
        keys: key(1),
        base: [RosterEntry(label: 'original', spaceKeys: key(3))],
        childLocator: child,
        childLabel: 'other child',
      );
      final ready = other.withChildKeys(key(4));
      try {
        final proof = await MasterSetupJournal.initializeChild(
          storage: candidate,
          intent: ready,
          child: child,
          childKeys: key(4),
          check: () {},
        );
        final commits = parentRaw.commits;
        await expectLater(finish(proof), throwsA(failure));
        expect(parentRaw.commits, commits);
        expect(await parent.loadRoster(), isNull);
      } finally {
        other.destroy();
        ready.destroy();
      }
    },
  );

  for (final (name, change) in <(String, Future<void> Function())>[
    (
      'foreign profile',
      () => candidate.saveProfile(const UserProfile(displayName: 'foreign')),
    ),
    ('node config', () => candidate.saveNodeConfig('synthetic foreign config')),
    ('foreign setting', () => candidate.putSetting('foreign', 'preserve')),
    (
      'master roster',
      () => candidate.saveRoster([
        RosterEntry(label: 'foreign', spaceKeys: key(8)),
      ]),
    ),
    (
      'unknown setup stage',
      () => candidate.putSetting(kPendingIdentitySetupSetting, 'future'),
    ),
  ]) {
    test('child initialization refuses $name without writes', () async {
      await change();
      final commits = childRaw.commits;
      await expectLater(initialize(), throwsA(failure));
      expect(childRaw.commits, commits);
      expect(await parent.loadRoster(), isNull);
    });
  }

  test('foreign child locator and key refuse before payload writes', () async {
    final commits = childRaw.commits;
    for (final (location, keys) in [(root, key(4)), (child, key(9))]) {
      await expectLater(
        MasterSetupJournal.initializeChild(
          storage: candidate,
          intent: intent,
          child: location,
          childKeys: keys,
          check: () {},
        ),
        throwsA(failure),
      );
      expect(childRaw.commits, commits);
    }
  });

  test(
    'cancellation after child profile preserves pending data for exact retry',
    () async {
      var current = true;
      childRaw.after = (ops) {
        if (ops.whereType<PutOp>().any(
          (op) => utf8.decode(op.key) == 'identity',
        )) {
          current = false;
        }
      };
      await expectLater(
        initialize(
          check: () {
            if (!current) throw StateError('synthetic cancelled child');
          },
        ),
        throwsA(failure),
      );
      expect(await candidate.getSetting(kPendingIdentitySetupSetting), '1');
      expect(
        await candidate.loadProfile(),
        const UserProfile(displayName: 'planned child'),
      );
      childRaw.after = null;
      final proof = await initialize();
      await finish(proof);
      expect(await parent.getSetting(kPendingMasterSetupSetting), '0');
    },
  );

  test(
    'completed child keeps later profile, node and user data on parent retry',
    () async {
      await initialize();
      await candidate.saveProfile(
        const UserProfile(displayName: 'renamed later'),
      );
      await candidate.saveNodeConfig('synthetic later node');
      await candidate.putSetting('later-data', 'preserve');
      final commits = childRaw.commits;
      final proof = await initialize();
      expect(childRaw.commits, commits);
      await finish(proof);
      expect(
        await candidate.loadProfile(),
        const UserProfile(displayName: 'renamed later'),
      );
      expect(await candidate.loadNodeConfig(), 'synthetic later node');
      expect(await candidate.getSetting('later-data'), 'preserve');
    },
  );

  test(
    'a completed marker with a missing profile never remints a child',
    () async {
      await candidate.putSetting(kPendingIdentitySetupSetting, '0');
      final commits = childRaw.commits;
      await expectLater(initialize(), throwsA(failure));
      expect(childRaw.commits, commits);
      expect(await candidate.loadProfile(), isNull);
    },
  );
}
