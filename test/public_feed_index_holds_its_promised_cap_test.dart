import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/group_service.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _Signer implements GroupSigner {
  _Signer(this._self);
  final NodeId _self;

  @override
  NodeId get selfId => _self;
  @override
  Uint8List get selfPubKey => _self.bytes;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

void main() {
  /// The durable-feed index must hold the number of packages it promises.
  ///
  /// It lived in one settings value, and a container caps one value at 2048
  /// bytes. An entry costs about 183 of them — a 64-character space id, a
  /// content-id manifest hash, a timestamp and their keys — so the index
  /// stopped being writable at twelve while
  /// `_kMaxDurablePublicFeedPackages` promised sixty-four. The write that
  /// failed was the LAST step of caching a package that had already been
  /// stored: a file on disk with nothing listing it, which no later sweep has
  /// a reason to retain or remove (report27 X33).
  test('the durable-feed index holds every package the cap allows', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(_id(1)));

    final cap = GroupService.debugMaxDurablePublicFeedPackages;
    expect(cap, greaterThan(12), reason: 'premise: the cap is past one value');
    final full = jsonEncode([
      for (var n = 0; n < cap; n += 1)
        {
          'space': _id(n).hex,
          // A content id, which is what a manifest hash is here.
          'manifest': 'b3:${'0' * 64}',
          'retainUntil': 1700000000000 + n,
        },
    ]);
    expect(
      full.length,
      greaterThan(2048),
      reason:
          'premise: a full index is ${full.length} bytes, which has to be more '
          'than one settings value holds or this proves nothing',
    );

    await service.debugWritePublicFeedCacheIndex(full);

    expect(
      await service.debugReadPublicFeedCacheIndex(),
      full,
      reason:
          'the index did not survive its own write at the size its cap '
          'promises — the packages it lists are on disk with nothing naming '
          'them',
    );
  });
}
