import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/notifications/windows_toast_content.dart';

void main() {
  test('ordinary preview and routing token are not rewritten', () {
    final content = windowsToastContent(
      title: 'Контакт 👩🏽‍💻',
      body: 'Привет! <проверка> & ответ',
      payload: 'mention:/chat/opaque?msg=123',
    );
    expect(content, (
      title: 'Контакт 👩🏽‍💻',
      body: 'Привет! <проверка> & ответ',
    ));
  });

  for (final character in [
    'x',
    '&',
    '<',
    '"',
    '\n',
    '😀',
    'е\u0301',
    '👩🏽‍💻',
  ]) {
    test(
      'long preview is a complete-character XML-safe prefix: $character',
      () {
        final title = character * 10000;
        final body = character * 65536;
        final content = windowsToastContent(title: title, body: body)!;
        expect(content.title.endsWith('…'), isTrue);
        expect(content.body.endsWith('…'), isTrue);
        final prefix = content.body.substring(0, content.body.length - 1);
        expect(body.startsWith(prefix), isTrue);
        expect(prefix.characters.every((c) => c == character), isTrue);
        const escape = HtmlEscape();
        expect(
          utf8.encode(escape.convert(content.title)).length,
          lessThanOrEqualTo(384),
        );
        expect(
          utf8.encode(escape.convert(content.body)).length,
          lessThanOrEqualTo(2048),
        );
        expect(content.body, isNot(contains('\uFFFD')));
      },
    );
  }

  test('one enormous grapheme cannot bypass the budget', () {
    final cluster = 'a${'\u0301' * 20000}';
    expect(cluster.characters.length, 1);
    expect(windowsToastContent(title: cluster, body: cluster), (
      title: '…',
      body: '…',
    ));
  });

  test('oversized route is refused rather than shortened', () {
    expect(
      windowsToastContent(title: 'xVeil', body: 'Call', payload: '&' * 204),
      isNotNull,
    );
    expect(
      windowsToastContent(title: 'xVeil', body: 'Call', payload: '&' * 205),
      isNull,
    );
    expect(
      windowsToastContent(title: 'xVeil', body: 'Call', payload: '😀' * 257),
      isNull,
    );
  });
}
