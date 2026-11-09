import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';

void main() {
  final id = NodeId(Uint8List(32)..fillRange(0, 32, 7));
  for (final name in [null, '', '  \t\n']) {
    test(
      'empty contact name uses the node label: ${name == null ? 'null' : name.length}',
      () {
        final label = Contact(nodeId: id, name: name).label;
        expect(label, id.short);
        expect(label.characters.first, isNotEmpty);
      },
    );
  }
  test('a nonempty chosen name is preserved', () {
    expect(Contact(nodeId: id, name: '  Example  ').label, '  Example  ');
  });
}
