import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'inline_custom_emoji.dart';

/// A stable value identity for an edit. Device clocks and JSON map insertion
/// order do not select the winner. Inline emoji are part of the edited text.
String messageEditContentHash(String body, List<InlineCustomEmoji> emoji) =>
    crypto.sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'xveil.message.edit.v1',
              body,
              encodeInlineCustomEmoji(emoji),
            ]),
          ),
        )
        .toString();

/// Edits of one logical message share its revision stream across devices.
/// Concurrent writers can allocate the same revision; the larger content hash
/// breaks that tie identically in storage, device sync and history recovery.
bool messageEditWins({
  required int revision,
  required String contentHash,
  required int? heldRevision,
  required String heldContentHash,
}) =>
    heldRevision == null ||
    revision > heldRevision ||
    (revision == heldRevision && contentHash.compareTo(heldContentHash) > 0);
