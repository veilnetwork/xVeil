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

  group('link detection', () {
    test('splits an http(s) URL into a link token', () {
      expect(parseFormatted('see https://veil.im now'), [
        const FmtToken(FmtKind.plain, 'see '),
        const FmtToken(FmtKind.link, 'https://veil.im'),
        const FmtToken(FmtKind.plain, ' now'),
      ]);
    });

    test('trailing sentence punctuation stays out of the link', () {
      expect(parseFormatted('go to https://veil.im.'), [
        const FmtToken(FmtKind.plain, 'go to '),
        const FmtToken(FmtKind.link, 'https://veil.im'),
        const FmtToken(FmtKind.plain, '.'),
      ]);
    });

    test('a URL inside code stays literal (not a link)', () {
      expect(parseFormatted('`https://veil.im`'), [
        const FmtToken(FmtKind.code, 'https://veil.im'),
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

  group('parseBlocks', () {
    test('plain body is a single normal block', () {
      expect(parseBlocks('hello\nworld'), [
        const MdBlock(MdBlockKind.normal, 'hello\nworld'),
      ]);
    });

    test('a quoted run becomes one quote block, markers stripped', () {
      expect(parseBlocks('> a\n> b'), [
        const MdBlock(MdBlockKind.quote, 'a\nb'),
      ]);
    });

    test('quote then normal splits into two blocks', () {
      expect(parseBlocks('> quoted\nreply'), [
        const MdBlock(MdBlockKind.quote, 'quoted'),
        const MdBlock(MdBlockKind.normal, 'reply'),
      ]);
    });

    test('normal, quote, normal — three blocks in order', () {
      expect(parseBlocks('intro\n> mid\nend'), [
        const MdBlock(MdBlockKind.normal, 'intro'),
        const MdBlock(MdBlockKind.quote, 'mid'),
        const MdBlock(MdBlockKind.normal, 'end'),
      ]);
    });

    test('only the first following space is stripped', () {
      expect(parseBlocks('>  two spaces'), [
        const MdBlock(MdBlockKind.quote, ' two spaces'),
      ]);
      expect(parseBlocks('>nospace'), [
        const MdBlock(MdBlockKind.quote, 'nospace'),
      ]);
    });

    test('leading indentation before > still marks a quote', () {
      expect(parseBlocks('  > indented'), [
        const MdBlock(MdBlockKind.quote, 'indented'),
      ]);
    });

    test('> inside a fenced code block is code, not a quote', () {
      expect(parseBlocks('```\n> not a quote\n```'), [
        const MdBlock(MdBlockKind.code, '> not a quote'),
      ]);
    });

    test('a real quote after a closed fence is still recognised', () {
      expect(parseBlocks('```\ncode\n```\n> q'), [
        const MdBlock(MdBlockKind.code, 'code'),
        const MdBlock(MdBlockKind.quote, 'q'),
      ]);
    });
  });

  group('parseBlocks — fenced code', () {
    test('a fence becomes a code block with the inner lines', () {
      expect(parseBlocks('```\ncode\n```'), [
        const MdBlock(MdBlockKind.code, 'code'),
      ]);
    });

    test('a language tag on the opening fence is dropped', () {
      expect(parseBlocks('```dart\nx = 1;\n```'), [
        const MdBlock(MdBlockKind.code, 'x = 1;'),
      ]);
    });

    test('multi-line code is preserved verbatim', () {
      expect(parseBlocks('```\na\nb\n```'), [
        const MdBlock(MdBlockKind.code, 'a\nb'),
      ]);
    });

    test('text around a code block splits into three blocks', () {
      expect(parseBlocks('before\n```\ncode\n```\nafter'), [
        const MdBlock(MdBlockKind.normal, 'before'),
        const MdBlock(MdBlockKind.code, 'code'),
        const MdBlock(MdBlockKind.normal, 'after'),
      ]);
    });

    test('an unterminated fence stays literal normal text', () {
      expect(parseBlocks('```\ncode'), [
        const MdBlock(MdBlockKind.normal, '```\ncode'),
      ]);
    });

    test('a self-closed inline triple-backtick is not a block', () {
      expect(parseBlocks('```x```'), [
        const MdBlock(MdBlockKind.normal, '```x```'),
      ]);
    });
  });

  group('highlightSpans', () {
    const style = TextStyle();
    const hl = Color(0xFFFFFF00);
    // Shape each span as (text, isHighlighted) for readable assertions.
    List<(String, bool)> shape(List<TextSpan> spans) => [
      for (final s in spans) (s.text ?? '', s.style?.backgroundColor == hl),
    ];

    test('no query → single plain span', () {
      expect(shape(highlightSpans('hello', style, null, hl)), [
        ('hello', false),
      ]);
      expect(shape(highlightSpans('hello', style, '', hl)), [('hello', false)]);
    });

    test('single match splits into before / match / after', () {
      expect(shape(highlightSpans('foobarbaz', style, 'bar', hl)), [
        ('foo', false),
        ('bar', true),
        ('baz', false),
      ]);
    });

    test('case-insensitive; original case preserved in output', () {
      expect(shape(highlightSpans('Hello WORLD', style, 'world', hl)), [
        ('Hello ', false),
        ('WORLD', true),
      ]);
    });

    test('match at the very start has no leading span', () {
      expect(shape(highlightSpans('barbaz', style, 'bar', hl)), [
        ('bar', true),
        ('baz', false),
      ]);
    });

    test('every occurrence is highlighted', () {
      expect(shape(highlightSpans('a x a x a', style, 'a', hl)), [
        ('a', true),
        (' x ', false),
        ('a', true),
        (' x ', false),
        ('a', true),
      ]);
    });

    test('no match → single plain span', () {
      expect(shape(highlightSpans('hello', style, 'zzz', hl)), [
        ('hello', false),
      ]);
    });
  });
}
