import 'dart:convert';

/// One node the user manages — typically a server they run as an exit / relay,
/// referenced by its veil [nodeId] and (optionally) reachable over SSH for
/// status + provisioning. The registry is the bridge between "Мои узлы" and
/// "Маршрутизация трафика": a managed exit's [nodeId] is what you route your
/// SOCKS5 traffic through.
///
/// Stored INSIDE the encrypted container (SSH host/user are sensitive), as a
/// JSON list under a single setting key. SSH passwords and private keys are
/// deliberately kept out of this catalog: they live in separate per-node
/// encrypted settings managed by `SshCredentialsRepository`.
class ManagedNode {
  const ManagedNode({
    required this.id,
    required this.label,
    this.nodeId,
    this.sshHost,
    this.sshPort = 22,
    this.sshUser,
    this.sshHostFingerprint,
    this.autoUpdate = false,
    this.veilVersion,
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

  /// Pinned `SHA256:…` SSH host-key fingerprint, captured trust-on-first-use on
  /// the first successful connect. Once set, every later [sshRun] verifies the
  /// server still presents it — a changed key is refused as a possible MITM
  /// (which would otherwise capture the SSH password / run as root).
  final String? sshHostFingerprint;

  /// Whether this server keeps its own veil-cli current on a timer.
  ///
  /// Default FALSE, and false for records written before the field existed.
  /// Deployment installs no timer: unattended root-level updates are opt-in,
  /// because what they trust is whoever can publish a release, and the ordinary
  /// path is the app noticing a new version and offering to install it while a
  /// person is present.
  ///
  /// A local record of what was asked for, not a reading of the server. What
  /// the node actually runs is only ever changed by running the script, and
  /// this is set from that run's result.
  final bool autoUpdate;

  /// The veil-cli version this node last REPORTED, without a leading `v`.
  ///
  /// Remembered so the app can say "there is a newer release than what you are
  /// running" without an SSH round trip every time the screen opens. Stale by
  /// construction — it is what the node said at the last inventory, not what it
  /// runs now — which is exactly why the offer runs an inventory before it
  /// installs anything.
  final String? veilVersion;

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
    String? sshHostFingerprint,
    bool? autoUpdate,
    String? veilVersion,
  }) =>
      ManagedNode(
        id: id,
        label: label ?? this.label,
        nodeId: clearNodeId ? null : (nodeId ?? this.nodeId),
        sshHost: sshHost ?? this.sshHost,
        sshPort: sshPort ?? this.sshPort,
        sshUser: sshUser ?? this.sshUser,
        sshHostFingerprint: sshHostFingerprint ?? this.sshHostFingerprint,
        autoUpdate: autoUpdate ?? this.autoUpdate,
        veilVersion: veilVersion ?? this.veilVersion,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (nodeId != null) 'nodeId': nodeId,
        if (sshHost != null) 'sshHost': sshHost,
        'sshPort': sshPort,
        if (sshUser != null) 'sshUser': sshUser,
        if (sshHostFingerprint != null)
          'sshHostFingerprint': sshHostFingerprint,
        'autoUpdate': autoUpdate,
        if (veilVersion != null) 'veilVersion': veilVersion,
      };

  factory ManagedNode.fromJson(Map<String, dynamic> j) => ManagedNode(
        id: j['id'] as String,
        label: j['label'] as String? ?? '',
        nodeId: j['nodeId'] as String?,
        sshHost: j['sshHost'] as String?,
        sshPort: (j['sshPort'] as num?)?.toInt() ?? 22,
        sshUser: j['sshUser'] as String?,
        sshHostFingerprint: j['sshHostFingerprint'] as String?,
        autoUpdate: j['autoUpdate'] as bool? ?? false,
        veilVersion: j['veilVersion'] as String?,
      );

  /// Encode/decode a whole registry to/from the single JSON string persisted
  /// under the encrypted-storage setting key.
  static String encodeList(List<ManagedNode> nodes) =>
      jsonEncode([for (final n in nodes) n.toJson()]);

  /// Decode the registry, QUARANTINING a record rather than the whole list.
  ///
  /// `fromJson` throws on a record with no `id`, and the throw used to escape
  /// the comprehension into the outer catch — so one malformed entry returned
  /// an EMPTY registry and every other node the user had configured vanished
  /// from the screen. Nothing was lost on disk, which made it worse: the list
  /// came back empty, the user re-added a node, and that write replaced the
  /// whole key (report9 X-05).
  ///
  /// A record that cannot be read is skipped and the rest are kept. The outer
  /// catch stays for the case that really is all-or-nothing: the string is not
  /// JSON at all.
  static List<ManagedNode> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final List<dynamic> decoded;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! List) return const [];
      decoded = parsed;
    } catch (_) {
      return const [];
    }
    final out = <ManagedNode>[];
    for (final e in decoded) {
      if (e is! Map<String, dynamic>) continue;
      try {
        out.add(ManagedNode.fromJson(e));
      } catch (_) {
        // One unreadable record costs its own entry and nothing else.
        continue;
      }
    }
    return out;
  }
}
