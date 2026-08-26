/// A share of ONE exit node — `veil:oproxy?id=<64 hex>&n=<label>`.
///
/// What it carries is deliberately small: which node to route through, and a
/// name to show for it. No identity of the sharer, no credentials, nothing
/// dialable — the recipient's own node resolves the id the same way it resolves
/// any other. It is the counterpart of the server-side allowlist: the operator
/// admits a contact's node id there, and hands them this so they know what to
/// point at.
///
/// It is NOT a bootstrap invite. Redeeming it adds an entry to the exit
/// catalog; it creates no contact, exchanges no keys, and adds no peer.
class OproxyInvite {
  const OproxyInvite({required this.nodeId, required this.label});

  /// 64 hex characters, lowercased.
  final String nodeId;

  /// What to call it in the catalog. May be empty: the catalog falls back to
  /// the id's first eight characters.
  final String label;

  static const scheme = 'veil:oproxy?';

  /// A hostile link is attacker-controlled text that ends up in a list the
  /// person reads. Bound it well above any real name.
  static const maxLabelChars = 64;

  /// Bound the whole token too: everything after the scheme is either a 64-char
  /// id or a bounded label, so anything much larger is not a share.
  static const maxUriChars = 512;

  static bool looksLikeOproxyInvite(String uri) =>
      uri.trim().toLowerCase().startsWith(scheme);

  static OproxyInvite parse(String uri) {
    final trimmed = uri.trim();
    if (!looksLikeOproxyInvite(trimmed)) {
      throw const FormatException('not a veil oproxy share');
    }
    if (trimmed.length > maxUriChars) {
      throw const FormatException('oproxy share too large');
    }
    String? id;
    var label = '';
    for (final part in trimmed.substring(scheme.length).split('&')) {
      final at = part.indexOf('=');
      if (at <= 0) continue;
      final key = part.substring(0, at);
      final value = part.substring(at + 1);
      switch (key) {
        case 'id':
          id = value.trim().toLowerCase();
        case 'n':
          // A label that fails to decode is dropped, not fatal: the id is what
          // makes the share useful, and the catalog can name it by its prefix.
          try {
            label = Uri.decodeComponent(value).trim();
          } catch (_) {
            label = '';
          }
      }
    }
    if (id == null || !_isHex64(id)) {
      throw const FormatException('oproxy share has no usable node id');
    }
    if (label.length > maxLabelChars) {
      label = label.substring(0, maxLabelChars);
    }
    // Control characters in a name that is rendered in a list, and newlines
    // that would break the single line it is rendered on.
    label = label.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    return OproxyInvite(nodeId: id, label: label);
  }

  String toUri() {
    final name = label.trim();
    final suffix = name.isEmpty ? '' : '&n=${Uri.encodeComponent(name)}';
    return '${scheme}id=$nodeId$suffix';
  }

  static bool _isHex64(String value) =>
      value.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
}
