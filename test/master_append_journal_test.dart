import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/master_setup_journal.dart';
import 'package:xveil/domain/master_setup_intent.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_setup.dart';
import 'master_append_intent_test.dart' as fixture;

class _Raw extends FakeKvLogStore {
  _Raw() : super(keys: fixture.key(1));
  int commits = 0;
  bool loseReply = false;
  @override
  int commit(List<KvLogOp> ops) {
    commits++;
    final result = super.commit(ops);
    if (loseReply &&
        ops.whereType<PutOp>().any(
          (op) =>
              utf8.decode(op.key) == 'set:$kPendingMasterSetupSetting' &&
              utf8.decode(op.value) == '0',
        )) {
      loseReply = false;
      throw StateError('synthetic lost accepted reply');
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Raw raw;
  late HiddenVolumeStorage parent;
  late List<RosterEntry> base;
  late MasterSetupIntent intent;
  setUp(() async {
    raw = _Raw();
    parent = HiddenVolumeStorage.fromStore(raw);
    base = fixture.largeBase();
    await parent.saveRoster(base);
    intent = fixture.plan(base);
  });
  tearDown(() async {
    intent.destroy();
    fixture.wipe(base);
    await parent.close();
  });
  Future<void> prepare(MasterSetupIntent value) => MasterSetupJournal.prepare(
    storage: parent,
    intent: value,
    root: fixture.root,
    keys: fixture.key(1),
    check: () {},
  );
  Future<void> abort(MasterSetupIntent value) =>
      MasterSetupJournal.abortPrepared(
        storage: parent,
        intent: value,
        root: fixture.root,
        keys: fixture.key(1),
        check: () {},
      );
  final failure = throwsA(isA<MasterSetupFailure>());

  test(
    'large legacy master keeps all rows through append and a second append',
    () async {
      await prepare(intent);
      final pending = (await MasterSetupJournal.read(parent, () {}))!;
      try {
        expect(pending.same(intent), isTrue);
      } finally {
        pending.destroy();
      }
      final ready = await MasterSetupJournal.attachChild(
        storage: parent,
        intent: intent,
        childKeys: fixture.key(200),
        root: fixture.root,
        keys: fixture.key(1),
        check: () {},
      );
      final child = HiddenVolumeStorage.fromStore(
        FakeKvLogStore(keys: fixture.key(200)),
      );
      try {
        final proof = await MasterSetupJournal.initializeChild(
          storage: child,
          intent: ready,
          child: fixture.child,
          childKeys: fixture.key(200),
          check: () {},
        );
        await MasterSetupJournal.publishAndFinish(
          storage: parent,
          intent: ready,
          childProof: proof,
          root: fixture.root,
          keys: fixture.key(1),
          check: () {},
        );
        final full = (await parent.loadRoster())!;
        try {
          expect(full.length, base.length + 1);
          for (var i = 0; i < base.length; i++) {
            expect(full[i].label, base[i].label);
            expect(full[i].spaceKeys, base[i].spaceKeys);
          }
          // A later source change is captured by the next accepted plan rather
          // than overwritten with the prior receipt's obsolete roster.
          full[0] = full[0].copyWith(anonymous: !full[0].anonymous);
          await parent.saveRoster(full);
          final next = MasterSetupIntent.create(
            root: fixture.root,
            keys: fixture.key(1),
            base: full,
            childLocator: const LegacyStorageLocator(),
            childLabel: 'second new child',
            append: true,
          );
          try {
            await prepare(next);
          } finally {
            next.destroy();
          }
        } finally {
          fixture.wipe(full);
        }
      } finally {
        ready.destroy();
        await child.close();
      }
    },
  );

  test(
    'rejected candidate abort is read-only on retry and permits a fresh plan',
    () async {
      await prepare(intent);
      await abort(intent);
      final before = raw.commits;
      await abort(intent);
      expect(raw.commits, before);
      final rows = (await parent.loadRoster())!;
      try {
        expect(rows.length, base.length);
        expect(rows.first.spaceKeys, base.first.spaceKeys);
        final next = MasterSetupIntent.create(
          root: fixture.root,
          keys: fixture.key(1),
          base: rows,
          childLocator: fixture.child,
          childLabel: 'replacement label',
          append: true,
        );
        try {
          await prepare(next);
        } finally {
          next.destroy();
        }
      } finally {
        fixture.wipe(rows);
      }
    },
  );

  test('lost abort reply preserves the base and retry is read-only', () async {
    await prepare(intent);
    raw.loseReply = true;
    await expectLater(abort(intent), failure);
    expect(await parent.getSetting(kPendingMasterSetupSetting), '0');
    final before = raw.commits;
    await abort(intent);
    expect(raw.commits, before);
    final rows = (await parent.loadRoster())!;
    try {
      expect(rows.map((row) => row.label), base.map((row) => row.label));
    } finally {
      fixture.wipe(rows);
    }
  });

  test('stale abort cannot cancel a newly prepared replacement plan', () async {
    await prepare(intent);
    await abort(intent);
    final next = MasterSetupIntent.create(
      root: fixture.root,
      keys: fixture.key(1),
      base: base,
      childLocator: fixture.child,
      childLabel: 'replacement',
      append: true,
    );
    try {
      await prepare(next);
      final before = raw.commits;
      await expectLater(abort(intent), failure);
      expect(raw.commits, before);
      final actual = (await MasterSetupJournal.read(parent, () {}))!;
      try {
        expect(actual.same(next), isTrue);
      } finally {
        actual.destroy();
      }
    } finally {
      next.destroy();
    }
  });

  test(
    'stale abort cannot cancel a distinct attempt with identical parameters',
    () async {
      await prepare(intent);
      await abort(intent);
      final next = fixture.plan(base);
      try {
        await prepare(next);
        final before = raw.commits;
        await expectLater(abort(intent), failure);
        expect(raw.commits, before);
        expect(await parent.getSetting(kPendingMasterSetupSetting), '1');
      } finally {
        next.destroy();
      }
    },
  );

  test(
    'a retired attempt cannot be prepared again as a fresh operation',
    () async {
      await prepare(intent);
      await abort(intent);
      final before = raw.commits;
      await expectLater(prepare(intent), failure);
      expect(raw.commits, before);
    },
  );

  test(
    'accepted legacy plans without an attempt tag still finish; fresh reuse refuses',
    () async {
      final original = intent.encode();
      final m = jsonDecode(utf8.decode(original));
      m.remove('attempt');
      original.fillRange(0, original.length, 0);
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(m)));
      final legacy = MasterSetupIntent.decode(bytes, roster: base);
      MasterSetupIntent? ready;
      final child = HiddenVolumeStorage.fromStore(
        FakeKvLogStore(keys: fixture.key(200)),
      );
      try {
        final before = raw.commits;
        await expectLater(prepare(legacy), failure);
        expect(raw.commits, before);
        await parent.storeFileWithSetting(
          StoredFileWrite(kMasterSetupJournalFile, bytes),
          settingKey: kPendingMasterSetupSetting,
          settingValue: '1',
        );
        await prepare(
          legacy,
        ); // read-only retry of already accepted legacy work
        ready = await MasterSetupJournal.attachChild(
          storage: parent,
          intent: legacy,
          childKeys: fixture.key(200),
          root: fixture.root,
          keys: fixture.key(1),
          check: () {},
        );
        final proof = await MasterSetupJournal.initializeChild(
          storage: child,
          intent: ready,
          child: fixture.child,
          childKeys: fixture.key(200),
          check: () {},
        );
        await MasterSetupJournal.publishAndFinish(
          storage: parent,
          intent: ready,
          childProof: proof,
          root: fixture.root,
          keys: fixture.key(1),
          check: () {},
        );
        final record = (await parent.loadFile(kMasterSetupJournalFile))!;
        try {
          expect(jsonDecode(utf8.decode(record)), {
            'v': 1,
            'complete': true,
            'digest': isA<String>(),
          });
        } finally {
          record.fillRange(0, record.length, 0);
        }
        final rows = (await parent.loadRoster())!;
        try {
          final next = MasterSetupIntent.create(
            root: fixture.root,
            keys: fixture.key(1),
            base: rows,
            childLocator: const LegacyStorageLocator(),
            childLabel: 'after upgrade',
            append: true,
          );
          try {
            await prepare(next);
          } finally {
            next.destroy();
          }
        } finally {
          fixture.wipe(rows);
        }
      } finally {
        legacy.destroy();
        ready?.destroy();
        bytes.fillRange(0, bytes.length, 0);
        await child.close();
      }
    },
  );

  test('abort cannot forget attached child keys', () async {
    await prepare(intent);
    final ready = await MasterSetupJournal.attachChild(
      storage: parent,
      intent: intent,
      childKeys: fixture.key(200),
      root: fixture.root,
      keys: fixture.key(1),
      check: () {},
    );
    try {
      final before = raw.commits;
      await expectLater(abort(intent), failure);
      await expectLater(abort(ready), failure);
      expect(raw.commits, before);
      final actual = (await MasterSetupJournal.read(parent, () {}))!;
      try {
        expect(actual.same(ready), isTrue);
      } finally {
        actual.destroy();
      }
    } finally {
      ready.destroy();
    }
  });

  test(
    'changed accepted base refuses recovery and abort without writes',
    () async {
      await prepare(intent);
      final changed = base
          .map((r) => r.copyWith(spaceKeys: Uint8List.fromList(r.spaceKeys)))
          .toList();
      changed[0] = changed[0].copyWith(anonymous: !changed[0].anonymous);
      await parent.saveRoster(changed);
      final before = raw.commits;
      try {
        await expectLater(MasterSetupJournal.read(parent, () {}), failure);
        await expectLater(abort(intent), failure);
        expect(raw.commits, before);
        final actual = (await parent.loadRoster())!;
        try {
          expect(actual.first.anonymous, changed.first.anonymous);
        } finally {
          fixture.wipe(actual);
        }
      } finally {
        fixture.wipe(changed);
      }
    },
  );

  test(
    'malformed prior retirement record is preserved, never reset for append',
    () async {
      await parent.storeFile(
        kMasterSetupJournalFile,
        Uint8List.fromList([123]),
      );
      final before = raw.commits;
      await expectLater(prepare(intent), failure);
      expect(raw.commits, before);
      expect(await parent.loadFile(kMasterSetupJournalFile), [123]);
    },
  );
}
