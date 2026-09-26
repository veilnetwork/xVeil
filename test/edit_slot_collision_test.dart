import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

void main() {
  // Every device of an identity numbers its own stream, and the counterpart
  // files them all under the one author it knows: a second device's edit can
  // carry the number of the first device's message. Read as "already
  // applied", every such edit was acked and never shown (0 of 3 on the stand).
  test('a wire edit whose seq another message of the author holds still '
      'applies, and a re-drive of it does not apply twice', () async {
    final peer = _id(2);
    final storage = HiddenVolumeStorage(_mem());
    await storage.open(password: 'p', createIfMissing: true);
    Future<void> post(String id, int seq) => storage.appendMessage(
      Message(
        id: id,
        conversationId: peer.hex,
        direction: MessageDirection.incoming,
        body: 'body of $id',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000 * seq),
        status: MessageStatus.delivered,
        author: peer.hex,
        seq: seq,
      ),
    );
    await post('from-device-b', 3);
    await post('from-device-a', 4);

    // Device B edits its own message; its stream says 4, which the
    // counterpart already holds as device A's message.
    await storage.editMessage(peer.hex, 'from-device-b', 'edited', seq: 4);
    Future<Message> row(String id) async =>
        (await storage.loadMessages(peer.hex)).singleWhere((m) => m.id == id);
    expect((await row('from-device-b')).body, 'edited');
    expect((await row('from-device-a')).body, 'body of from-device-a');

    await storage.editMessage(peer.hex, 'from-device-b', 'edited', seq: 4);
    expect(
      (await storage.loadMessageHistory(peer.hex, 'from-device-b')).length,
      2,
      reason: 'the post and ONE edit: a re-drive is idempotent',
    );
  });

  // Device A edited the message at 143 of its stream; device B, whose own
  // cursor is far lower, edits it again. The counterpart keeps the higher seq,
  // so B's later edit must be numbered past A's.
  test('a local edit is numbered past every edit of the message already held',
      () async {
    final peer = _id(3);
    final storage = HiddenVolumeStorage(_mem());
    await storage.open(password: 'p', createIfMissing: true);
    await storage.appendMessage(
      Message(
        id: 'msg',
        conversationId: peer.hex,
        direction: MessageDirection.outgoing,
        body: 'first',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        status: MessageStatus.sent,
        author: 'device-a',
        seq: 1,
      ),
    );
    await storage.editMessage(peer.hex, 'msg', 'edited on A', seq: 143);
    final mine = await storage.editMessage(peer.hex, 'msg', 'edited on B');
    expect(mine, greaterThan(143));
    expect(
      (await storage.loadMessages(peer.hex)).single.body,
      'edited on B',
    );
  });
}
