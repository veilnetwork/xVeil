// Conversation media gallery (media epic: "свайп между медиа"): the pure
// item collector feeding the swipeable viewer — downloaded images only, in
// display order; the paging interaction itself is device-smoked.

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chat_screen.dart';

Message _msg(
  String id, {
  String? fileId,
  String? fileContentId,
  String? name,
}) =>
    Message(
      id: id,
      conversationId: 'c',
      direction: MessageDirection.incoming,
      body: name == null ? 'text' : '📎 $name',
      timestamp: DateTime(2026, 1, 1),
      fileId: fileId,
      fileContentId: fileContentId,
      fileName: name,
    );

void main() {
  test('collects image messages in display order, keyed like the bubble', () {
    final items = conversationGalleryItems([
      _msg('t1'), // plain text — out
      _msg('a', fileId: 'fa', name: 'a.png'),
      _msg('doc', fileId: 'fd', name: 'report.pdf'), // non-image — out
      _msg('b', fileId: 'fb', name: 'B.JPEG'), // extension case-insensitive
      // Offered / content-path image: keyed by contentId (an incoming
      // content-path image keeps fileContentId even after download).
      _msg('offered', fileContentId: 'cid', name: 'later.png'),
      _msg('c', fileId: 'fc', name: 'c.webp'),
    ]);
    expect(items.map((i) => i.id), ['a', 'b', 'offered', 'c']);
    expect(items.map((i) => i.fileKey), ['fa', 'fb', 'cid', 'fc']);
    expect(items[1].name, 'B.JPEG');
  });

  test('empty and no-media conversations yield an empty set', () {
    expect(conversationGalleryItems(const []), isEmpty);
    expect(
      conversationGalleryItems([_msg('t1'), _msg('d', fileId: 'x', name: 'x.zip')]),
      isEmpty,
    );
  });
}
