import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/inline_custom_emoji.dart';
import 'package:xveil/features/chat/custom_emoji_controller.dart';

void main() {
  test('composer emits visible fallback plus recalculated UTF-16 offsets', () {
    final controller = CustomEmojiEditingController();
    addTearDown(controller.dispose);
    controller.text = '  hello  ';
    controller.selection = const TextSelection.collapsed(offset: 2);
    expect(controller.insertCustomEmoji(Uint8List.fromList([1, 2, 3])), isTrue);
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    expect(controller.insertCustomEmoji(Uint8List.fromList([4, 5])), isTrue);

    final wire = controller.toWireValue();
    expect(wire.body, '☺hello  ☺');
    expect(wire.customEmoji.map((e) => e.offset), [0, 8]);
    expect(base64Decode(wire.customEmoji.first.dataB64), [1, 2, 3]);
  });

  test('load/edit preserves images while text insertion shifts offsets', () {
    final controller = CustomEmojiEditingController();
    addTearDown(controller.dispose);
    final data = base64Encode([9, 8, 7]);
    controller.loadWireValue('a☺b', [
      InlineCustomEmoji(offset: 1, dataB64: data),
    ]);
    controller.selection = const TextSelection.collapsed(offset: 0);
    controller.value = controller.value.copyWith(
      text: 'z${controller.text}',
      selection: const TextSelection.collapsed(offset: 1),
    );

    final wire = controller.toWireValue();
    expect(wire.body, 'za☺b');
    expect(wire.customEmoji.single.offset, 2);
    expect(wire.customEmoji.single.dataB64, data);
  });

  test('at most four active images enter one message', () {
    final controller = CustomEmojiEditingController();
    addTearDown(controller.dispose);
    for (var i = 0; i < kInlineCustomEmojiMaxCount; i++) {
      expect(controller.insertCustomEmoji(Uint8List.fromList([i + 1])), isTrue);
    }
    expect(controller.insertCustomEmoji(Uint8List.fromList([99])), isFalse);
    expect(controller.toWireValue().customEmoji.length, 4);
  });

  testWidgets('editable composer renders one image as one caret position', (
    tester,
  ) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final controller = CustomEmojiEditingController()..text = 'ab';
    addTearDown(controller.dispose);
    controller.selection = const TextSelection.collapsed(offset: 1);
    expect(controller.insertCustomEmoji(base64Decode(png)), isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(controller: controller, maxLines: null)),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(controller.text.length, 3);
    expect(controller.selection, const TextSelection.collapsed(offset: 2));
    final wire = controller.toWireValue();
    expect(wire.body, 'a☺b');
    expect(wire.customEmoji.single.offset, 1);
    expect(tester.takeException(), isNull);
  });
}
