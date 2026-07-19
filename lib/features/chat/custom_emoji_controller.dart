import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../domain/inline_custom_emoji.dart';

typedef CustomEmojiWireValue = ({
  String body,
  List<InlineCustomEmoji> customEmoji,
});

/// Text controller that keeps each inline image as one private-use code unit.
/// Selection/caret math therefore stays identical to an ordinary character;
/// [toWireValue] swaps it for the backward-compatible `☺` plus bounded bytes.
class CustomEmojiEditingController extends TextEditingController {
  static const int _sentinelStart = 0xe000;
  static const int _sentinelEnd = 0xf8ff;

  final Map<int, Uint8List> _images = {};

  int get customEmojiCount =>
      text.codeUnits.where((code) => _images.containsKey(code)).length;

  int? _allocateSentinel() {
    final active = text.codeUnits.toSet();
    _images.removeWhere((code, _) => !active.contains(code));
    for (var code = _sentinelStart; code <= _sentinelEnd; code++) {
      if (!active.contains(code)) return code;
    }
    return null;
  }

  bool insertCustomEmoji(Uint8List png) {
    if (png.isEmpty ||
        png.length > kInlineCustomEmojiMaxBytes ||
        customEmojiCount >= kInlineCustomEmojiMaxCount) {
      return false;
    }
    final code = _allocateSentinel();
    if (code == null) return false;
    _images[code] = Uint8List.fromList(png);
    final current = value;
    final selection = current.selection;
    final start = selection.isValid ? selection.start : current.text.length;
    final end = selection.isValid ? selection.end : current.text.length;
    final sentinel = String.fromCharCode(code);
    value = current.copyWith(
      text: current.text.replaceRange(start, end, sentinel),
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
    return true;
  }

  CustomEmojiWireValue toWireValue() {
    final body = StringBuffer();
    final items = <InlineCustomEmoji>[];
    for (final code in text.codeUnits) {
      final bytes = _images[code];
      if (bytes == null) {
        body.writeCharCode(code);
        continue;
      }
      final offset = body.length;
      body.write(kInlineCustomEmojiFallback);
      if (items.length < kInlineCustomEmojiMaxCount) {
        items.add(
          InlineCustomEmoji(offset: offset, dataB64: base64Encode(bytes)),
        );
      }
    }
    final untrimmed = body.toString();
    final trimmedLeft = untrimmed.trimLeft();
    final leading = untrimmed.length - trimmedLeft.length;
    final trimmed = trimmedLeft.trimRight();
    return (
      body: trimmed,
      customEmoji: List.unmodifiable([
        for (final item in items)
          if (item.offset >= leading && item.offset - leading < trimmed.length)
            InlineCustomEmoji(
              offset: item.offset - leading,
              dataB64: item.dataB64,
            ),
      ]),
    );
  }

  /// Restore a stored/wire value for an edit surface. Invalid sidecars remain
  /// ordinary fallback glyphs; valid ones regain one-code-unit sentinels.
  void loadWireValue(String body, List<InlineCustomEmoji> items) {
    _images.clear();
    if (items.isEmpty) {
      text = body;
      return;
    }
    final byOffset = {for (final item in items) item.offset: item};
    final restored = StringBuffer();
    final used = body.codeUnits.toSet();
    var candidate = _sentinelStart;
    for (var offset = 0; offset < body.length; offset++) {
      final item = byOffset[offset];
      if (item == null) {
        restored.writeCharCode(body.codeUnitAt(offset));
        continue;
      }
      while (candidate <= _sentinelEnd && used.contains(candidate)) {
        candidate++;
      }
      if (candidate > _sentinelEnd) {
        restored.write(kInlineCustomEmojiFallback);
        continue;
      }
      _images[candidate] = Uint8List.fromList(base64Decode(item.dataB64));
      restored.writeCharCode(candidate);
      used.add(candidate);
      candidate++;
    }
    text = restored.toString();
    selection = TextSelection.collapsed(offset: text.length);
  }

  void clearWithCustomEmoji() {
    _images.clear();
    clear();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final spans = <InlineSpan>[];
    final plain = StringBuffer();
    void flush() {
      if (plain.isEmpty) return;
      spans.add(TextSpan(text: plain.toString(), style: style));
      plain.clear();
    }

    for (final code in text.codeUnits) {
      final bytes = _images[code];
      if (bytes == null) {
        plain.writeCharCode(code);
        continue;
      }
      flush();
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Image.memory(
              bytes,
              width: 24,
              height: 24,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) =>
                  Text(kInlineCustomEmojiFallback, style: style),
            ),
          ),
        ),
      );
    }
    flush();
    return TextSpan(style: style, children: spans);
  }
}
