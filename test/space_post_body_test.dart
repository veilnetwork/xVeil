import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/spaces/space_post_body.dart';
import 'package:xveil/features/spaces/space_post_body_editor.dart';
import 'package:xveil/features/chat/custom_emoji_controller.dart';
import 'package:xveil/l10n/app_localizations.dart';

Widget _host(Widget child) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: const [
      AppL10n.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppL10n.supportedLocales,
    home: Scaffold(body: child),
  ),
);

void main() {
  test('publication Markdown parser preserves all supported block kinds', () {
    final blocks = parseSpacePostTextBlocks('''
# Release

Intro with **bold**.

> quoted line
> second line

- first
- second

3. third
4. fourth

---

```dart
final value = 1;
```
''');

    expect(blocks.map((block) => block.kind), [
      SpacePostTextBlockKind.heading1,
      SpacePostTextBlockKind.paragraph,
      SpacePostTextBlockKind.quote,
      SpacePostTextBlockKind.bulletList,
      SpacePostTextBlockKind.orderedList,
      SpacePostTextBlockKind.divider,
      SpacePostTextBlockKind.code,
    ]);
    expect(blocks[2].text, 'quoted line\nsecond line');
    expect(blocks[3].items, ['first', 'second']);
    expect(blocks[4].startOrdinal, 3);
    expect(blocks[4].items, ['third', 'fourth']);
    expect(blocks.last.text, 'final value = 1;');
  });

  test('block style replaces existing markers across selected lines', () {
    final heading = applySpacePostBlockStyle(
      'Alpha\nBeta',
      const TextSelection(baseOffset: 0, extentOffset: 10),
      SpacePostBlockStyle.heading2,
    );
    expect(heading.text, '## Alpha\n## Beta');

    final numbered = applySpacePostBlockStyle(
      heading.text,
      TextSelection(baseOffset: 0, extentOffset: heading.text.length),
      SpacePostBlockStyle.orderedList,
    );
    expect(numbered.text, '1. Alpha\n2. Beta');

    final code = applySpacePostBlockStyle(
      'final value = 1;',
      const TextSelection.collapsed(offset: 0),
      SpacePostBlockStyle.code,
    );
    expect(code.text, '```\nfinal value = 1;\n```');
    expect(code.selection.textInside(code.text), 'final value = 1;');
  });

  testWidgets('editor applies blocks and previews the structured result', (
    tester,
  ) async {
    final controller = CustomEmojiEditingController()..text = 'Alpha\nBeta';
    addTearDown(controller.dispose);
    var changed = '';
    await tester.pumpWidget(
      _host(
        Padding(
          padding: const EdgeInsets.all(16),
          child: SpacePostBodyEditor(
            controller: controller,
            maxLength: 1000,
            hintText: 'Body',
            onChanged: (value) => changed = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 10);
    await tester.tap(find.byKey(const ValueKey('space-post-block-menu')));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(SpacePostBodyEditor)));
    await tester.tap(find.text(l.spacePostBlockBulletList));
    await tester.pumpAndSettle();

    expect(controller.text, '- Alpha\n- Beta');
    expect(changed, controller.text);
    await tester.tap(find.byKey(const ValueKey('space-post-preview-toggle')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('space-post-body-preview')),
      findsOneWidget,
    );
    expect(find.text('•'), findsNWidgets(2));
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('renderer shows headings, quotes, lists, divider and code', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const Padding(
          padding: EdgeInsets.all(16),
          child: SpacePostBody('''
# Heading

> A quote

1. First
2. Second

---

```
copy me
```
'''),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Heading'), findsOneWidget);
    expect(find.text('A quote'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(find.text('copy me'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
  });
}
