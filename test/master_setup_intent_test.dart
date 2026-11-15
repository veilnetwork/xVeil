import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/master_setup_intent.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

Uint8List _key(int n) => Uint8List(64)..fillRange(0, 64, n);
ManagedStorageLocator _location(String n, {bool plain = false}) =>
    ManagedStorageLocator(
      id: ManagedIdentityId(n * 32),
      protection: plain
          ? StorageProtection.unencrypted
          : StorageProtection.encrypted,
    );
MasterSetupIntent _intent({
  List<RosterEntry>? base,
  IdentityStorageLocator? child,
}) => MasterSetupIntent.create(
  root: _location('a'),
  keys: _key(1),
  base:
      base ??
      [RosterEntry(label: 'original', spaceKeys: _key(3), anonymous: true)],
  childLocator: child ?? _location('b'),
  childLabel: 'new child',
  childAnonymous: true,
);

void main() {
  final invalid = isA<MasterSetupFailure>();
  test('base intent persists planned slot before child keys exist', () {
    final intent = _intent();
    addTearDown(intent.destroy);
    expect(intent.childKnown, isFalse);
    expect(intent.copyRoster, throwsA(invalid));
    final bytes = intent.encode();
    final json = jsonDecode(utf8.decode(bytes)) as Map;
    expect((json['child'] as Map)['locator'], _location('b').encode());
    expect((json['child'] as Map)['keys'], isNull);
    final decoded = MasterSetupIntent.decode(bytes);
    addTearDown(decoded.destroy);
    expect(decoded.same(intent), isTrue);
    expect(
      () => decoded.validateOwner(_location('a'), _key(1)),
      returnsNormally,
    );
    expect(
      () => decoded.validateOwner(_location('c'), _key(1)),
      throwsA(invalid),
    );
    expect(
      () => decoded.validateOwner(_location('a'), _key(2)),
      throwsA(invalid),
    );
    bytes.fillRange(0, bytes.length, 0);
  });
  test('owned snapshots survive caller mutation and base destruction', () {
    final source = _key(3), parent = _key(1);
    final rows = [RosterEntry(label: 'original', spaceKeys: source)];
    final base = MasterSetupIntent.create(
      root: _location('a'),
      keys: parent,
      base: rows,
      childLocator: _location('b'),
      childLabel: 'new child',
    );
    rows.clear();
    source.fillRange(0, source.length, 0);
    parent.fillRange(0, parent.length, 0);
    final child = _key(4);
    final next = base.withChildKeys(child);
    addTearDown(next.destroy);
    child.fillRange(0, child.length, 0);
    base.destroy();
    expect(base.encode, throwsA(invalid));
    final copies = next.copyRoster();
    expect(copies.first.spaceKeys, _key(3));
    expect(copies.last.spaceKeys, _key(4));
    for (final row in copies) {
      row.spaceKeys.fillRange(0, row.spaceKeys.length, 0);
    }
    final again = next.copyRoster();
    expect(again.last.spaceKeys, _key(4));
    for (final row in again) {
      row.spaceKeys.fillRange(0, row.spaceKeys.length, 0);
    }
  });
  test(
    'child attachment is monotone and plan equality includes every source row',
    () {
      final base = _intent();
      final first = base.withChildKeys(_key(4));
      final second = base.withChildKeys(_key(5));
      addTearDown(base.destroy);
      addTearDown(first.destroy);
      addTearDown(second.destroy);
      expect(first.same(second, planOnly: true), isTrue);
      expect(first.same(second), isFalse);
      expect(() => first.withChildKeys(_key(5)), throwsA(invalid));
      expect(() => base.withChildKeys(_key(1)), throwsA(invalid));
      expect(() => base.withChildKeys(_key(3)), throwsA(invalid));
      final changed = _intent(
        base: [RosterEntry(label: 'other', spaceKeys: _key(3))],
      );
      addTearDown(changed.destroy);
      expect(changed.same(base, planOnly: true), isFalse);
    },
  );
  for (final row in [
    RosterEntry(label: '', spaceKeys: _key(3)),
    RosterEntry(label: 'new child', spaceKeys: _key(3)),
    RosterEntry(label: 'bad', spaceKeys: Uint8List(63)),
    RosterEntry(label: 'self', spaceKeys: _key(1)),
    RosterEntry(
      label: 'same target',
      spaceKeys: _key(3),
      storageLocator: _location('b'),
    ),
    RosterEntry(
      label: 'same root',
      spaceKeys: _key(3),
      storageLocator: _location('a', plain: true),
    ),
  ]) {
    test(
      'invalid source row cannot become an intent (case ${row.label.length}/${row.spaceKeys.length})',
      () {
        expect(() => _intent(base: [row]), throwsA(invalid));
        expect(
          row.spaceKeys,
          row.spaceKeys.length == 63
              ? Uint8List(63)
              : _key(row.label == 'self' ? 1 : 3),
        );
      },
    );
  }
  test('duplicate source identities and root/child aliasing are rejected', () {
    expect(
      () => _intent(
        base: [
          RosterEntry(label: 'one', spaceKeys: _key(3)),
          RosterEntry(label: 'two', spaceKeys: _key(3)),
        ],
      ),
      throwsA(invalid),
    );
    expect(() => _intent(child: _location('a')), throwsA(invalid));
    expect(() => _intent(base: []), throwsA(invalid));
  });
  test('multiple hidden references need no public hidden IDs', () {
    final intent = MasterSetupIntent.create(
      root: const LegacyStorageLocator(),
      keys: _key(1),
      base: [
        RosterEntry(label: 'hidden one', spaceKeys: _key(3)),
        RosterEntry(label: 'hidden two', spaceKeys: _key(4)),
      ],
      childLocator: const LegacyStorageLocator(),
      childLabel: 'hidden child',
    );
    addTearDown(intent.destroy);
    final next = intent.withChildKeys(_key(5));
    addTearDown(next.destroy);
    final rows = next.copyRoster();
    expect(
      rows.map((r) => r.storageLocator),
      everyElement(const LegacyStorageLocator()),
    );
    for (final row in rows) {
      row.spaceKeys.fillRange(0, row.spaceKeys.length, 0);
    }
  });
  final mutations = <void Function(Map<String, dynamic>)>[
    (m) => m['extra'] = true,
    (m) => m.remove('root'),
    (m) => m['v'] = 1.0,
    (m) => m['base'] = [],
    (m) => m['owner'] = base64.encode(_key(1)),
    (m) => m['owner'] = '%%',
    (m) => (m['child'] as Map)['anonymous'] = 1,
    (m) => (m['child'] as Map)['keys'] = base64.encode(Uint8List(63)),
    (m) => (m['child'] as Map)['locator'] = {'v': 1, 'kind': 'unknown'},
    (m) => ((m['base'] as List).first as Map)['anonymous'] = null,
    (m) => ((m['base'] as List).first as Map)['keys'] = base64.encode(_key(1)),
    (m) => m['base'] = List.filled(
      MasterSetupIntent.maxBaseEntries + 1,
      (m['base'] as List).first,
    ),
  ];
  for (var i = 0; i < mutations.length; i++) {
    test('strict journal codec rejects mutation $i without mutating input', () {
      final intent = _intent();
      final bytes = intent.encode();
      intent.destroy();
      final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      mutations[i](m);
      final bad = Uint8List.fromList(utf8.encode(jsonEncode(m))),
          before = <int>[];
      before.addAll(bad);
      expect(() => MasterSetupIntent.decode(bad), throwsA(invalid));
      expect(bad, before);
      bytes.fillRange(0, bytes.length, 0);
      bad.fillRange(0, bad.length, 0);
    });
  }
  test('encoded journal has a bound shared with atomic file publication', () {
    expect(
      () => MasterSetupIntent.decode(Uint8List(MasterSetupIntent.maxBytes + 1)),
      throwsA(invalid),
    );
    expect(
      () => _intent(
        base: [
          for (var i = 0; i < 32; i++)
            RosterEntry(
              label: '$i${List.filled(240, '界').join()}',
              spaceKeys: _key(i + 3),
            ),
        ],
      ),
      throwsA(invalid),
    );
  });
}
