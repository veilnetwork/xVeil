import 'dart:convert';

/// A local-only grouping of conversations (like Telegram folders). A
/// conversation may belong to ANY number of folders. Membership is stored by
/// peer node-id hex. Purely local + encrypted (in the settings KV) — nothing
/// about folders ever goes on the wire.
class ChatFolder {
  const ChatFolder({
    required this.id,
    required this.name,
    this.memberHexes = const [],
  });

  /// Stable id (a uuid) so a rename doesn't lose membership.
  final String id;
  final String name;

  /// Peer node-id hexes in this folder. A List (not Set) for stable JSON order;
  /// callers treat it as a set.
  final List<String> memberHexes;

  bool contains(String hex) => memberHexes.contains(hex);

  ChatFolder copyWith({String? name, List<String>? memberHexes}) => ChatFolder(
        id: id,
        name: name ?? this.name,
        memberHexes: memberHexes ?? this.memberHexes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'm': memberHexes,
      };

  static ChatFolder fromJson(Map<String, dynamic> j) => ChatFolder(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        memberHexes:
            (j['m'] as List?)?.whereType<String>().toList() ?? const [],
      );

  /// Encode a folder list to the settings-KV string.
  static String encodeList(List<ChatFolder> folders) =>
      jsonEncode(folders.map((f) => f.toJson()).toList());

  /// Decode the settings-KV string (null/malformed → empty list).
  static List<ChatFolder> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(ChatFolder.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
