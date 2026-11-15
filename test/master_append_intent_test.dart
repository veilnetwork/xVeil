import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/domain/master_setup_intent.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

Uint8List key(int n) => Uint8List(64)..fillRange(0, 64, n);
final root = ManagedStorageLocator(
  id: ManagedIdentityId('a' * 32),
  protection: StorageProtection.encrypted,
);
final child = ManagedStorageLocator(
  id: ManagedIdentityId('b' * 32),
  protection: StorageProtection.encrypted,
);
List<RosterEntry> largeBase() => List.generate(
  128,
  (i) => RosterEntry(
    label: '$i:${'Ж' * 800}',
    spaceKeys: key(i + 2),
    anonymous: i.isEven,
  ),
);
MasterSetupIntent plan(List<RosterEntry> base) => MasterSetupIntent.create(
  root: root,
  keys: key(1),
  base: base,
  childLocator: child,
  childLabel: 'new child',
  append: true,
);
void wipe(List<RosterEntry> rows) {
  for (final row in rows) {
    row.spaceKeys.fillRange(0, 64, 0);
  }
}

void main() {
  test('attempt tags are canonical 16-byte values', () {
    final rows = [RosterEntry(label: 'original', spaceKeys: key(2))];
    final intent = plan(rows);
    final bytes = intent.encode();
    try {
      for (final bad in [
        null,
        42,
        '',
        base64.encode(Uint8List(15)),
        base64.encode(Uint8List(17)),
      ]) {
        final m = jsonDecode(utf8.decode(bytes));
        m['attempt'] = bad;
        final changed = Uint8List.fromList(utf8.encode(jsonEncode(m)));
        try {
          expect(
            () => MasterSetupIntent.decode(changed, roster: rows),
            throwsA(isA<MasterSetupFailure>()),
          );
        } finally {
          changed.fillRange(0, changed.length, 0);
        }
      }
      expect(rows.first.spaceKeys, key(2));
    } finally {
      intent.destroy();
      bytes.fillRange(0, bytes.length, 0);
      wipe(rows);
    }
  });
  test('identical parameters still create distinct append attempts', () {
    final rows = [RosterEntry(label: 'original', spaceKeys: key(2))];
    final first = plan(rows), second = plan(rows);
    final ready = first.withChildKeys(key(200));
    try {
      expect(first.same(second), isFalse);
      expect(ready.same(first, planOnly: true), isTrue);
      expect(ready.same(second, planOnly: true), isFalse);
    } finally {
      first.destroy();
      second.destroy();
      ready.destroy();
      wipe(rows);
    }
  });
  test(
    'large existing roster uses a bounded commitment, never serialized source keys',
    () {
      final rows = largeBase();
      final intent = plan(rows);
      try {
        final bytes = intent.encode();
        try {
          expect(rows.length, greaterThan(MasterSetupIntent.maxBaseEntries));
          expect(
            utf8.encode(jsonEncode(rows.map((r) => r.label).toList())).length,
            greaterThan(48 * 3800),
          );
          expect(bytes.length, lessThan(StoredFileSettingWriter.maxBytes));
          final encoded = jsonDecode(utf8.decode(bytes));
          expect(encoded['v'], 2);
          expect(encoded['base'], {'count': 128, 'digest': isA<String>()});
          expect(base64.decode(encoded['base']['digest']), hasLength(32));
          expect(
            MasterSetupIntent.maxAppendEntries * 88,
            greaterThan(kMaxStoredFileBytes),
          );
          expect(
            () => MasterSetupIntent.decode(bytes),
            throwsA(isA<MasterSetupFailure>()),
          );
          final decoded = MasterSetupIntent.decode(bytes, roster: rows);
          try {
            expect(decoded.same(intent), isTrue);
          } finally {
            decoded.destroy();
          }
          expect(rows.first.spaceKeys, key(2));
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      } finally {
        intent.destroy();
        wipe(rows);
      }
    },
  );

  test('append snapshot owns all base keys despite compact serialization', () {
    final rows = largeBase();
    final original = plan(rows);
    final copy = original.copy();
    original.destroy();
    wipe(rows);
    try {
      final base = copy.copyBase();
      try {
        expect(base.first.spaceKeys, key(2));
        expect(base.last.spaceKeys, key(129));
      } finally {
        wipe(base);
      }
      final ready = copy.withChildKeys(key(200));
      final full = ready.copyRoster();
      final bytes = ready.encode();
      try {
        final decoded = MasterSetupIntent.decode(bytes, roster: full);
        try {
          expect(decoded.same(ready), isTrue);
        } finally {
          decoded.destroy();
        }
        expect(full.last.spaceKeys, key(200));
      } finally {
        bytes.fillRange(0, bytes.length, 0);
        wipe(full);
        ready.destroy();
      }
    } finally {
      copy.destroy();
    }
  });

  for (final field in [
    'label',
    'keys',
    'anonymous',
    'locator',
    'order',
    'count',
  ]) {
    test('changed base $field never hydrates an old append obligation', () {
      final rows = [
        RosterEntry(label: 'one', spaceKeys: key(2)),
        RosterEntry(label: 'two', spaceKeys: key(3)),
      ];
      final intent = plan(rows);
      final bytes = intent.encode();
      final changed = [
        for (final row in rows)
          row.copyWith(spaceKeys: Uint8List.fromList(row.spaceKeys)),
      ];
      switch (field) {
        case 'label':
          changed[0] = changed[0].copyWith(label: 'other');
        case 'keys':
          changed[0].spaceKeys[0] ^= 1;
        case 'anonymous':
          changed[0] = changed[0].copyWith(anonymous: true);
        case 'locator':
          changed[0] = changed[0].copyWith(storageLocator: child);
        case 'order':
          final old = changed[0];
          changed[0] = changed[1];
          changed[1] = old;
        case 'count':
          changed.add(RosterEntry(label: 'extra', spaceKeys: key(8)));
      }
      try {
        expect(
          () => MasterSetupIntent.decode(bytes, roster: changed),
          throwsA(isA<MasterSetupFailure>()),
        );
        expect(rows.first.spaceKeys, key(2));
      } finally {
        intent.destroy();
        bytes.fillRange(0, bytes.length, 0);
        wipe(rows);
        wipe(changed);
      }
    });
  }

  for (final field in ['label', 'keys', 'anonymous', 'locator']) {
    test(
      'published full roster must include the exact planned child $field',
      () {
        final rows = [RosterEntry(label: 'one', spaceKeys: key(2))];
        final base = plan(rows), ready = base.withChildKeys(key(200));
        final bytes = ready.encode(), full = ready.copyRoster();
        switch (field) {
          case 'label':
            full.last = full.last.copyWith(label: 'other');
          case 'keys':
            full.last.spaceKeys[0] ^= 1;
          case 'anonymous':
            full.last = full.last.copyWith(anonymous: true);
          case 'locator':
            full.last = full.last.copyWith(
              storageLocator: const LegacyStorageLocator(),
            );
        }
        try {
          expect(
            () => MasterSetupIntent.decode(bytes, roster: full),
            throwsA(isA<MasterSetupFailure>()),
          );
          expect(
            () => MasterSetupIntent.decode(base.encode(), roster: full),
            throwsA(isA<MasterSetupFailure>()),
          );
        } finally {
          base.destroy();
          ready.destroy();
          bytes.fillRange(0, bytes.length, 0);
          wipe(rows);
          wipe(full);
        }
      },
    );
  }
}
