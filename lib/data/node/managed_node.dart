import 'dart:convert';

/// One node the user manages — typically a server they run as an exit / relay,
/// referenced by its veil [nodeId] and (optionally) reachable over SSH for
/// status + provisioning. The registry is the bridge between "Мои узлы" and
/// "Маршрутизация трафика": a managed exit's [nodeId] is what you route your
/// SOCKS5 traffic through.
///
/// Stored INSIDE the encrypted container (SSH host/user are sensitive), as a
/// JSON list under a single setting key. SSH credentials (keys/passwords) are
/// NOT held here — they are entered per-connection until the secure-key layer
/// lands, so a leaked registry never leaks an SSH secret.
class ManagedNode {
  const ManagedNode({
    required this.id,
    required this.label,
    this.nodeId,
    this.sshHost,
    this.sshPort = 22,
    this.sshUser,
  });

  /// Local stable id (uuid) — identifies the entry across edits.
  final String id;

  /// Human label ("My VPS exit", "home relay").
  final String label;

  /// The node's veil node_id (64-hex), once known — what you route through.
  final String? nodeId;

  /// Optional SSH reachability for status / future provisioning.
  final String? sshHost;
  final int sshPort;
  final String? sshUser;

  bool get hasNodeId => nodeId != null && _isHex64(nodeId!);
  bool get hasSsh => sshHost != null && sshHost!.isNotEmpty;

  static bool _isHex64(String s) =>
      s.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s);

  ManagedNode copyWith({
    String? label,
    String? nodeId,
    bool clearNodeId = false,
    String? sshHost,
    int? sshPort,
    String? sshUser,
  }) =>
      ManagedNode(
        id: id,
        label: label ?? this.label,
        nodeId: clearNodeId ? null : (nodeId ?? this.nodeId),
        sshHost: sshHost ?? this.sshHost,
        sshPort: sshPort ?? this.sshPort,
        sshUser: sshUser ?? this.sshUser,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (nodeId != null) 'nodeId': nodeId,
        if (sshHost != null) 'sshHost': sshHost,
        'sshPort': sshPort,
        if (sshUser != null) 'sshUser': sshUser,
      };

  factory ManagedNode.fromJson(Map<String, dynamic> j) => ManagedNode(
        id: j['id'] as String,
        label: j['label'] as String? ?? '',
        nodeId: j['nodeId'] as String?,
        sshHost: j['sshHost'] as String?,
        sshPort: (j['sshPort'] as num?)?.toInt() ?? 22,
        sshUser: j['sshUser'] as String?,
      );

  /// Encode/decode a whole registry to/from the single JSON string persisted
  /// under the encrypted-storage setting key.
  static String encodeList(List<ManagedNode> nodes) =>
      jsonEncode([for (final n in nodes) n.toJson()]);

  static List<ManagedNode> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (e is Map<String, dynamic>) ManagedNode.fromJson(e),
      ];
    } catch (_) {
      return const [];
    }
  }
}
