import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/chat/message_markdown.dart';

void main() {
  group('parseFormatted', () {
    test('plain text is one plain run', () {
      expect(parseFormatted('hello world'), [
        const FmtToken(FmtKind.plain, 'hello world'),
      ]);
    });

    test('bold / italic / strike / underline', () {
      expect(parseFormatted('**b**'), [const FmtToken(FmtKind.bold, 'b')]);
      expect(parseFormatted('*i*'), [const FmtToken(FmtKind.italic, 'i')]);
      expect(parseFormatted('~~s~~'), [const FmtToken(FmtKind.strike, 's')]);
      expect(parseFormatted('__u__'), [const FmtToken(FmtKind.underline, 'u')]);
    });

    test('longest marker wins: ** over *, ``` over `', () {
      expect(parseFormatted('**bold**'), [const FmtToken(FmtKind.bold, 'bold')]);
      expect(parseFormatted('```code```'), [
        const FmtToken(FmtKind.codeBlock, 'code'),
      ]);
    });

    test('inline code and spoiler', () {
      expect(parseFormatted('`x`'), [const FmtToken(FmtKind.code, 'x')]);
      expect(parseFormatted('||secret||'), [
        const FmtToken(FmtKind.spoiler, 'secret'),
      ]);
    });

    test('mixed runs coalesce plain and split styled', () {
      expect(parseFormatted('a **b** c'), [
        const FmtToken(FmtKind.plain, 'a '),
        const FmtToken(FmtKind.bold, 'b'),
        const FmtToken(FmtKind.plain, ' c'),
      ]);
    });

    test('unmatched / empty markers stay literal', () {
      expect(parseFormatted('2 * 3 = 6'), [
        const FmtToken(FmtKind.plain, '2 * 3 = 6'),
      ]);
      expect(parseFormatted('a ** b'), [
        const FmtToken(FmtKind.plain, 'a ** b'),
      ]);
      expect(parseFormatted('****'), [const FmtToken(FmtKind.plain, '****')]);
    });

    test('code content is literal (markers inside are not parsed)', () {
      expect(parseFormatted('`a*b*c`'), [
        const FmtToken(FmtKind.code, 'a*b*c'),
      ]);
    });
  });

  group('applyMarker', () {
    test('wraps a selection and keeps it selected', () {
      final r = applyMarker(
        'hello world',
        const TextSelection(baseOffset: 6, extentOffset: 11),
        '**',
      );
      expect(r.text, 'hello **world**');
      expect(r.selection.start, 8);
      expect(r.selection.end, 13);
      expect(r.text.substring(r.selection.start, r.selection.end), 'world');
    });

    test('collapsed cursor inserts marker pair with cursor between', () {
      final r = applyMarker(
        'ab',
        const TextSelection.collapsed(offset: 1),
        '*',
      );
      expect(r.text, 'a**b');
      expect(r.selection.isCollapsed, isTrue);
      expect(r.selection.start, 2); // between the two '*'
    });

    test('invalid selection appends at end', () {
      final r = applyMarker('x', const TextSelection.collapsed(offset: -1), '~~');
      expect(r.text, 'x~~~~');
      expect(r.selection.start, 3);
    });
  });
}
