import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/group_crypto.dart';

void main() {
  test('two active identities keep both document sources until disposal', () {
    final a = NodeId.fromHex(List.filled(32, '11').join());
    final c = NodeId.fromHex(List.filled(32, '22').join());
    final aDoc = Uint8List.fromList([1, 2, 3]);
    final cDoc = Uint8List.fromList([4, 5, 6]);
    final removeA = registerIdentityDocumentLookup(
      (identity) => identity == a ? aDoc : null,
    );
    final removeC = registerIdentityDocumentLookup(
      (identity) => identity == c ? cDoc : null,
    );
    addTearDown(removeA);
    addTearDown(removeC);

    expect(identityDocumentFor(a), aDoc);
    expect(identityDocumentFor(c), cDoc);
    removeC();
    expect(identityDocumentFor(a), aDoc);
    expect(identityDocumentFor(c), isNull);
  });
}
