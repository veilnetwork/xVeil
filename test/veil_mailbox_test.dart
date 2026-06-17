import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

void main() {
  test('LoopbackMailboxCrypto round-trips seal -> open', () async {
    final m = LoopbackMailboxCrypto();
    final appId = Uint8List.fromList(List.filled(32, 0xAB));
    final data = Uint8List.fromList([1, 2, 3, 4, 5, 9, 9, 9]);

    final blob = await m.seal(
      recipient: _id(2),
      appId: appId,
      endpointId: 0x01020304,
      data: data,
    );
    final opened = await m.open(blob: blob, sender: _id(1), ourCertVersion: 7);

    expect(opened.appId, appId);
    expect(opened.endpointId, 0x01020304);
    expect(opened.data, data);
  });

  test('LoopbackMailboxCrypto handles empty data', () async {
    final m = LoopbackMailboxCrypto();
    final appId = Uint8List.fromList(List.filled(32, 1));
    final blob = await m.seal(
      recipient: _id(2),
      appId: appId,
      endpointId: 0,
      data: Uint8List(0),
    );
    final opened = await m.open(blob: blob, sender: _id(1), ourCertVersion: 1);
    expect(opened.data, isEmpty);
    expect(opened.appId, appId);
  });

  test('LoopbackMailboxCrypto rejects a truncated blob', () async {
    final m = LoopbackMailboxCrypto();
    expect(
      () => m.open(blob: Uint8List(10), sender: _id(1), ourCertVersion: 1),
      throwsA(isA<FormatException>()),
    );
  });
}
