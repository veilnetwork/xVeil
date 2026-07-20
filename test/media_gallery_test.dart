// Conversation media gallery (media epic: "свайп между медиа"): the pure
// item collector feeding the swipeable viewer — downloaded images only, in
// display order; the paging interaction itself is device-smoked.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chat_screen.dart';

Message _msg(
  String id, {
  String? fileId,
  String? fileContentId,
  String? name,
}) => Message(
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

  _iconTests();

  test('empty and no-media conversations yield an empty set', () {
    expect(conversationGalleryItems(const []), isEmpty);
    expect(
      conversationGalleryItems([
        _msg('t1'),
        _msg('d', fileId: 'x', name: 'x.zip'),
      ]),
      isEmpty,
    );
  });

  test('raw gallery byte cache is bounded to current and adjacent pages', () {
    final items = <GalleryItem>[
      for (var i = 0; i < 100; i++)
        (id: 'm$i', fileKey: 'f$i', name: '$i.png', thumb: null),
    ];

    expect(mediaGalleryRetainedKeys(items, 50), {'f49', 'f50', 'f51'});
    expect(mediaGalleryRetainedKeys(items, 0), {'f0', 'f1'});
    expect(mediaGalleryRetainedKeys(items, 99), {'f98', 'f99'});
    expect(mediaGalleryRetainedKeys(items, 500), {'f98', 'f99'});
    expect(mediaGalleryRetainedKeys(const [], 0), isEmpty);
  });

  test('inline media decode tracks physical pixels and stays bounded', () {
    expect(mediaPreviewCacheDimension(280, 1), 280);
    expect(mediaPreviewCacheDimension(280, 3), 840);
    expect(mediaPreviewCacheDimension(280, 100), 2048);
    expect(mediaPreviewCacheDimension(0, 3), 1);
    expect(mediaPreviewCacheDimension(double.nan, 3), 1);
  });
}

// documentIcon: pure extension→icon mapping for the document file row.
// (Lives here with the other media-epic pure helpers.)

void _iconTests() {
  test('documentIcon maps known types and falls back generically', () {
    expect(documentIcon('a.pdf'), Icons.picture_as_pdf_outlined);
    expect(documentIcon('A.ZIP'), Icons.folder_zip_outlined);
    expect(documentIcon('voice.opus'), Icons.audiotrack_outlined);
    expect(documentIcon('clip.mp4'), Icons.movie_outlined);
    expect(documentIcon('sheet.csv'), Icons.table_chart_outlined);
    expect(documentIcon('notes.md'), Icons.article_outlined);
    expect(documentIcon('mystery.bin'), Icons.insert_drive_file_outlined);
    expect(documentIcon('noext'), Icons.insert_drive_file_outlined);
    expect(documentIcon(null), Icons.insert_drive_file_outlined);
  });
}
