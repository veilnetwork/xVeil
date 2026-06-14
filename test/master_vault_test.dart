import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/master_vault.dart';

ChildSpaceRef _ref(String label) => ChildSpaceRef(
      label: label,
      containerPath: '/spaces/$label.store',
      password: Uint8List.fromList(utf8Pw(label)),
    );

List<int> utf8Pw(String s) => 'pw-$s'.codeUnits;

void main() {
  late MasterVault vault;

  setUp(() => vault = MasterVault(FakeKvLogStore()));

  test('starts empty', () {
    expect(vault.listChildren(), isEmpty);
    expect(vault.getChild('alice'), isNull);
  });

  test('adds children and lists them; round-trips fields', () {
    vault.addChild(_ref('alice'));
    vault.addChild(_ref('work'));

    final children = vault.listChildren();
    expect(children.map((c) => c.label), containsAll(['alice', 'work']));

    final alice = vault.getChild('alice')!;
    expect(alice.containerPath, '/spaces/alice.store');
    expect(alice.password, Uint8List.fromList(utf8Pw('alice')));
  });

  test('re-adding a label replaces, does not duplicate the index', () {
    vault.addChild(_ref('alice'));
    vault.addChild(ChildSpaceRef(
      label: 'alice',
      containerPath: '/spaces/alice2.store',
      password: Uint8List.fromList(utf8Pw('alice')),
    ));
    expect(vault.listChildren().length, 1);
    expect(vault.getChild('alice')!.containerPath, '/spaces/alice2.store');
  });

  test('removes a child and updates the index', () {
    vault.addChild(_ref('alice'));
    vault.addChild(_ref('work'));
    vault.removeChild('alice');

    expect(vault.getChild('alice'), isNull);
    expect(vault.listChildren().map((c) => c.label), ['work']);
  });

  test('survives a fresh vault over the same store (persistence)', () {
    final store = FakeKvLogStore();
    MasterVault(store).addChild(_ref('alice'));
    // A new vault instance over the same unlocked space sees the child.
    expect(MasterVault(store).getChild('alice')!.label, 'alice');
  });
}
