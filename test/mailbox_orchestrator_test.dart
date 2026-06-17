import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/state/mailbox_orchestrator.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));
Uint8List _cid(int s) => Uint8List.fromList(List.filled(32, s));
Uint8List _appId(int s) => Uint8List.fromList(List.filled(32, s));

void main() {
  late InMemoryMailboxRelay relay;
  late MailboxOrchestrator orch;
  final me = _id(1);
  final peer = _id(2);
  final cookie = Uint8List.fromList(List.filled(16, 7));

  setUp(() {
    relay = InMemoryMailboxRelay();
    orch = MailboxOrchestrator(LoopbackMailboxCrypto(), relay);
  });

  Future<bool> never(Uint8List _) async => false;

  test('stash seals + puts; drain opens, returns, and acks', () async {
    final data = Uint8List.fromList([10, 20, 30]);
    await orch.stash(
      me: peer,
      recipient: me,
      appId: _appId(0xAA),
      endpointId: 9,
      data: data,
      contentId: _cid(0xC1),
    );
    // The blob is now pending for `me`.
    expect((await relay.fetch(me: me, authCookie: cookie)), hasLength(1));

    final drained = await orch.drain(
      me: me,
      authCookie: cookie,
      ourCertVersion: 1,
      alreadyHave: never,
    );
    expect(drained, hasLength(1));
    expect(drained.single.data, data);
    expect(drained.single.endpointId, 9);
    expect(drained.single.appId, _appId(0xAA));
    expect(drained.single.sender, peer);
    // Acked → relay drained.
    expect((await relay.fetch(me: me, authCookie: cookie)), isEmpty);
  });

  test('drain dedups: a blob we already have is skipped but still acked',
      () async {
    await orch.stash(
      me: peer,
      recipient: me,
      appId: _appId(1),
      endpointId: 0,
      data: Uint8List.fromList([1]),
      contentId: _cid(0xC2),
    );
    final drained = await orch.drain(
      me: me,
      authCookie: cookie,
      ourCertVersion: 1,
      alreadyHave: (c) async => true, // we already stored this message live
    );
    expect(drained, isEmpty); // not re-delivered
    expect((await relay.fetch(me: me, authCookie: cookie)), isEmpty); // but acked
  });

  test('drain acks + skips a corrupt blob without wedging the inbox', () async {
    // A malformed blob (too short to open) deposited directly + a good one.
    await relay.put(
      receiver: me,
      contentId: _cid(0xBA),
      sender: peer,
      blob: Uint8List.fromList([0, 1, 2]), // < 36 bytes -> open throws
    );
    await orch.stash(
      me: peer,
      recipient: me,
      appId: _appId(2),
      endpointId: 3,
      data: Uint8List.fromList([42]),
      contentId: _cid(0xC3),
    );

    final drained = await orch.drain(
      me: me,
      authCookie: cookie,
      ourCertVersion: 1,
      alreadyHave: never,
    );
    // The good one is delivered; the corrupt one is dropped — both acked.
    expect(drained, hasLength(1));
    expect(drained.single.data, Uint8List.fromList([42]));
    expect((await relay.fetch(me: me, authCookie: cookie)), isEmpty);
  });
}
