import 'package:flutter/material.dart';

export '../../domain/message_mention.dart';

class ActiveMentionQuery {
  const ActiveMentionQuery({
    required this.start,
    required this.end,
    required this.query,
  });

  final int start;
  final int end;
  final String query;
}

/// The unfinished `@query` immediately before the caret. E-mail-like text does
/// not trigger: `@` must begin the field or follow whitespace/open punctuation.
ActiveMentionQuery? activeMentionQuery(String text, TextSelection selection) {
  if (!selection.isValid || !selection.isCollapsed) return null;
  final caret = selection.extentOffset.clamp(0, text.length);
  if (caret == 0) return null;
  final start = text.lastIndexOf('@', caret - 1);
  if (start < 0) return null;
  if (start > 0 && !RegExp(r'[\s\(\[\{]').hasMatch(text[start - 1])) {
    return null;
  }
  final query = text.substring(start + 1, caret);
  if (query.length > 64 || query.contains(RegExp(r'[\s@\[\]\|]'))) {
    return null;
  }
  return ActiveMentionQuery(start: start, end: caret, query: query);
}
