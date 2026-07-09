import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/chat_folder.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

Conversation _conv(int seed, int unread) => Conversation(
      peer: Contact(nodeId: _id(seed), name: 'c$seed'),
      unread: unread,
    );

void main() {
  final convos = [_conv(1, 3), _conv(2, 0), _conv(3, 1200)];

  test('null folder (All) sums every conversation', () {
    expect(folderUnreadCount(convos, null), 1203);
  });

  test('folder counts only member conversations', () {
    final folder = ChatFolder(
      id: 'f1',
      name: 'work',
      memberHexes: [_id(1).hex, _id(2).hex],
    );
    expect(folderUnreadCount(convos, folder), 3);
  });

  test('empty folder shows zero', () {
    const folder = ChatFolder(id: 'f2', name: 'empty');
    expect(folderUnreadCount(convos, folder), 0);
  });

  test('badge text caps at 999+', () {
    expect(unreadBadgeText(0), '0');
    expect(unreadBadgeText(999), '999');
    expect(unreadBadgeText(1000), '999+');
    expect(unreadBadgeText(1203), '999+');
  });
}
