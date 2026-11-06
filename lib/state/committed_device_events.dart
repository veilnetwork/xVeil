import 'dart:convert';

import '../domain/group_message.dart';

/// Full commitments used to check fresh events against the durable bundle.
/// This is a synchronous membership index, not an authorization verdict.
Set<String> committedDeviceEventHashes(
  Iterable<GroupMessage> committed,
  Iterable<GroupMessage> fresh, {
  required String Function(GroupMessage) hashMessage,
}) {
  // Unequal author/sequence/signature cannot have the same full commitment.
  // Equal slots are only candidates: payload, group/channel, lifecycle and
  // every other canonical field still have to match the ordinary full hash.
  final slots = {for (final message in fresh) _slot(message)};
  if (slots.isEmpty) return {};
  return {
    for (final message in committed)
      if (slots.contains(_slot(message))) hashMessage(message),
  };
}

(String, int, String) _slot(GroupMessage message) =>
    (message.author.hex, message.seq, base64Encode(message.signature));
