import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/master_setup_journal.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/master_setup_intent.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_initialization.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_setup.dart';

Uint8List _key(int n) => Uint8List(64)..fillRange(0, 64, n);
final _root = ManagedStorageLocator(
  id: ManagedIdentityId('a' * 32),
  protection: StorageProtection.encrypted,
);
final _child = ManagedStorageLocator(
  id: ManagedIdentityId('b' * 32),
  protection: StorageProtection.encrypted,
);
MasterSetupIntent _intent({String label = 'new child'}) =>
    MasterSetupIntent.create(
      root: _root,
      keys: _key(1),
      base: [RosterEntry(label: 'original', spaceKeys: _key(3))],
      childLocator: _child,
      childLabel: label,
    );

class _Store extends FakeKvLogStore {
  _Store() : super(keys: _key(1));
  bool reject = false, loseReply = false;
  void Function()? afterPublication;
  int commits = 0, publications = 0;
  @override
  int commit(List<KvLogOp> ops) {
    commits++;
    final publishing = ops.whereType<PutOp>().any(
      (op) => utf8.decode(op.key) == 'set:$kPendingMasterSetupSetting',
    );
    if (publishing) {
      publications++;
      if (reject) throw StateError('synthetic publication refusal');
    }
    final result = super.commit(ops);
    if (publishing) afterPublication?.call();
    if (publishing && loseReply) {
      loseReply = false;
      throw StateError('synthetic lost publication reply');
    }
    return result;
  }
}

class _Gated extends HiddenVolumeStorage {
  _Gated(super.store) : super.fromStore();
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<Uint8List> exportSpaceKeys() async {
    final actual = await super.exportSpaceKeys();
    entered.complete();
    await release.future;
    return actual;
  }
}

class _ReadOnly
    implements Storage, MasterSetupInspectionSource, RosterMaintenanceReader {
  _ReadOnly(this.inner);
  final HiddenVolumeStorage inner;
  int unexpected = 0;
  @override
  bool get isOpen => inner.isOpen;
  @override
  Future<Uint8List> exportSpaceKeys() => inner.exportSpaceKeys();
  @override
  Future<UserProfile?> loadProfile() => inner.loadProfile();
  @override
  Future<String?> loadNodeConfig() => inner.loadNodeConfig();
  @override
  Future<String?> getSetting(String key) => inner.getSetting(key);
  @override
  Future<Uint8List?> loadFile(String id, {int? maxBytes}) =>
      inner.loadFile(id, maxBytes: maxBytes);
  @override
  Future<bool> hasFile(String id) => inner.hasFile(id);
  @override
  Future<List<RosterEntry>?> loadRosterForMaintenance() =>
      inner.loadRosterForMaintenance();
  @override
  Future<bool> masterSetupHasOnlyBootstrapData() =>
      inner.masterSetupHasOnlyBootstrapData();
  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpected++;
    throw StateError('unexpected write');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Store raw;
  late HiddenVolumeStorage storage;
  late MasterSetupIntent intent;
  final failure = isA<MasterSetupFailure>();
  Future<void> prepare({
    Storage? target,
    IdentityStorageLocator? root,
    Uint8List? keys,
  }) => MasterSetupJournal.prepare(
    storage: target ?? storage,
    intent: intent,
    root: root ?? _root,
    keys: keys ?? _key(1),
    check: () {},
  );
  Future<MasterSetupIntent> attach({
    Uint8List? keys,
    MasterSetupIntent? proposal,
  }) => MasterSetupJournal.attachChild(
    storage: storage,
    intent: proposal ?? intent,
    childKeys: keys ?? _key(4),
    root: _root,
    keys: _key(1),
    check: () {},
  );
  setUp(() {
    raw = _Store();
    storage = HiddenVolumeStorage.fromStore(raw);
    intent = _intent();
  });
  tearDown(() async {
    intent.destroy();
    await storage.close();
  });

  test(
    'marker and base plan publish together; exact retry performs no writes',
    () async {
      expect(await MasterSetupJournal.read(storage, () {}), isNull);
      await prepare();
      expect(await storage.getSetting(kPendingMasterSetupSetting), '1');
      final actual = (await MasterSetupJournal.read(storage, () {}))!;
      try {
        expect(actual.same(intent), isTrue);
        expect(actual.childKnown, isFalse);
      } finally {
        actual.destroy();
      }
      final commits = raw.commits;
      await prepare();
      expect(raw.commits, commits);
      expect(await storage.loadRoster(), isNull);
      expect(await storage.loadProfile(), isNull);
    },
  );
  test(
    'refused final commit leaves neither pending marker nor published intent',
    () async {
      raw.reject = true;
      await expectLater(prepare(), throwsA(failure));
      expect(await storage.getSetting(kPendingMasterSetupSetting), isNull);
      expect(await storage.hasFile(kMasterSetupJournalFile), isFalse);
      raw.reject = false;
      await prepare();
      expect(await storage.getSetting(kPendingMasterSetupSetting), '1');
    },
  );
  test(
    'lost publication reply preserves both values and permits exact retry',
    () async {
      raw.loseReply = true;
      await expectLater(prepare(), throwsA(failure));
      expect(await storage.getSetting(kPendingMasterSetupSetting), '1');
      final actual = (await MasterSetupJournal.read(storage, () {}))!;
      try {
        expect(actual.same(intent), isTrue);
      } finally {
        actual.destroy();
      }
      final commits = raw.commits;
      await prepare();
      expect(raw.commits, commits);
    },
  );
  test(
    'child attachment is monotone, retains its plan and accepts only exact retry',
    () async {
      await prepare();
      final ready = await attach();
      try {
        expect(ready.childKnown, isTrue);
        expect(ready.same(intent, planOnly: true), isTrue);
        final before = raw.commits;
        final again = await attach();
        again.destroy();
        expect(raw.commits, before);
        await expectLater(attach(keys: _key(5)), throwsA(failure));
        final changed = _intent(label: 'changed');
        try {
          await expectLater(attach(proposal: changed), throwsA(failure));
        } finally {
          changed.destroy();
        }
        final actual = (await MasterSetupJournal.read(storage, () {}))!;
        try {
          expect(actual.same(ready), isTrue);
        } finally {
          actual.destroy();
        }
        expect(raw.commits, before);
      } finally {
        ready.destroy();
      }
    },
  );
  test(
    'lost child-attachment reply does not lose or replace its keys',
    () async {
      await prepare();
      raw.loseReply = true;
      await expectLater(attach(), throwsA(failure));
      final expected = intent.withChildKeys(_key(4));
      final actual = await attach();
      try {
        expect(actual.same(expected), isTrue);
      } finally {
        actual.destroy();
        expected.destroy();
      }
    },
  );
  test('intent bound fits the atomic publication capability', () {
    expect(
      MasterSetupIntent.maxBytes,
      lessThanOrEqualTo(StoredFileSettingWriter.maxBytes),
    );
  });
  test('refused child publication retains its earlier base intent', () async {
    await prepare();
    raw.reject = true;
    await expectLater(attach(), throwsA(failure));
    final current = (await MasterSetupJournal.read(storage, () {}))!;
    try {
      expect(current.same(intent), isTrue);
      expect(current.childKnown, isFalse);
    } finally {
      current.destroy();
    }
    expect(await storage.getSetting(kPendingMasterSetupSetting), '1');
    raw.reject = false;
    final ready = await attach();
    ready.destroy();
  });
  test(
    'cancellation after publication keeps the accepted intent for recovery',
    () async {
      var current = true;
      raw.afterPublication = () => current = false;
      await expectLater(
        MasterSetupJournal.prepare(
          storage: storage,
          intent: intent,
          root: _root,
          keys: _key(1),
          check: () {
            if (!current) throw StateError('cancelled');
          },
        ),
        throwsA(failure),
      );
      final accepted = (await MasterSetupJournal.read(storage, () {}))!;
      try {
        expect(accepted.same(intent), isTrue);
      } finally {
        accepted.destroy();
      }
      expect(await storage.getSetting(kPendingMasterSetupSetting), '1');
    },
  );
  test(
    'malformed existing journal remains intact without replacement',
    () async {
      final payload = Uint8List.fromList([1, 2, 3, 4]);
      await storage.storeFile(kMasterSetupJournalFile, payload);
      await storage.putSetting(kPendingMasterSetupSetting, '1');
      final commits = raw.commits;
      await expectLater(prepare(), throwsA(failure));
      await expectLater(attach(), throwsA(failure));
      expect(raw.commits, commits);
      expect(await storage.loadFile(kMasterSetupJournalFile), payload);
      expect(await storage.getSetting(kPendingMasterSetupSetting), '1');
    },
  );
  test(
    'master inspection does not widen ordinary identity setup inspection',
    () async {
      await storage.saveRoster([
        RosterEntry(label: 'existing row', spaceKeys: _key(3)),
      ]);
      final before = raw.commits;
      expect(await storage.masterSetupHasOnlyBootstrapData(), isTrue);
      expect(
        await storage.setupHasOnlyBootstrapData(files: {}, settings: {}),
        isFalse,
      );
      expect(raw.commits, before);
      await storage.putSetting('unrelated', 'keep');
      final after = raw.commits;
      expect(await storage.masterSetupHasOnlyBootstrapData(), isFalse);
      expect(raw.commits, after);
    },
  );
  test(
    'chunked exact roster is inspectable; changed accepted rows are preserved',
    () async {
      intent.destroy();
      intent = MasterSetupIntent.create(
        root: _root,
        keys: _key(1),
        base: [
          for (var n = 10; n < 26; n++)
            RosterEntry(label: 'source row $n', spaceKeys: _key(n)),
        ],
        childLocator: _child,
        childLabel: 'new child',
      );
      await prepare();
      final ready = await attach();
      try {
        final rows = ready.copyRoster();
        await storage.saveRoster(rows);
        final before = raw.commits;
        final repeated = await attach();
        repeated.destroy();
        expect(raw.commits, before);
        rows[0] = rows[0].copyWith(label: 'changed after preparation');
        await storage.saveRoster(rows);
        final changed = raw.commits;
        await expectLater(attach(), throwsA(failure));
        expect(raw.commits, changed);
        final actual = (await storage.loadRoster())!;
        expect(actual.first.label, 'changed after preparation');
        for (final row in [...rows, ...actual]) {
          row.spaceKeys.fillRange(0, row.spaceKeys.length, 0);
        }
      } finally {
        ready.destroy();
      }
    },
  );
  test(
    'foreign opened root or declared location refuses before any writes',
    () async {
      await expectLater(prepare(keys: _key(8)), throwsA(failure));
      await expectLater(prepare(root: _child), throwsA(failure));
      final other = HiddenVolumeStorage.fromStore(
        FakeKvLogStore(keys: _key(9)),
      );
      try {
        await expectLater(prepare(target: other), throwsA(failure));
      } finally {
        await other.close();
      }
      expect(raw.commits, 0);
    },
  );
  test('unsupported atomic capability has no sequential fallback', () async {
    final facade = _ReadOnly(storage);
    await expectLater(prepare(target: facade), throwsA(failure));
    expect(facade.unexpected, 0);
    expect(raw.commits, 0);
  });
  for (final content in [
    'profile',
    'config',
    'setting',
    'file',
    'roster',
    'pending-master',
    'pending-identity',
  ]) {
    test(
      'existing $content refuses preparation without modifying its data',
      () async {
        switch (content) {
          case 'profile':
            await storage.saveProfile(const UserProfile(displayName: 'keep'));
          case 'config':
            await storage.saveNodeConfig('synthetic config');
          case 'setting':
            await storage.putSetting('unrelated', 'keep');
          case 'file':
            await storage.storeFile('unrelated', _key(8));
          case 'roster':
            await storage.saveRoster([
              RosterEntry(label: 'keep', spaceKeys: _key(8)),
            ]);
          case 'pending-master':
            await storage.putSetting(kPendingMasterSetupSetting, '1');
          case 'pending-identity':
            await storage.putSetting(kPendingIdentitySetupSetting, '1');
        }
        final before = raw.commits;
        await expectLater(prepare(), throwsA(failure));
        expect(raw.commits, before);
        expect(await storage.hasFile(kMasterSetupJournalFile), isFalse);
      },
    );
  }
  for (final cancel in [false, true]) {
    test(
      'accepted request owns its keys and intent while authentication awaits (cancel=$cancel)',
      () async {
        await storage.close();
        storage = _Gated(raw);
        final gated = storage as _Gated;
        final keys = _key(1), expected = intent.encode();
        var current = true;
        final writing = MasterSetupJournal.prepare(
          storage: storage,
          intent: intent,
          root: _root,
          keys: keys,
          check: () {
            if (!current) throw StateError('cancelled');
          },
        );
        await gated.entered.future;
        intent.destroy();
        keys.fillRange(0, keys.length, 0);
        current = !cancel;
        gated.release.complete();
        if (cancel) {
          await expectLater(writing, throwsA(failure));
          expect(raw.commits, 0);
        } else {
          await writing;
          final actual = (await MasterSetupJournal.read(storage, () {}))!;
          try {
            expect(actual.encode(), expected);
          } finally {
            actual.destroy();
          }
        }
        expected.fillRange(0, expected.length, 0);
      },
    );
  }
}
