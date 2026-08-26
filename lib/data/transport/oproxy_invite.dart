import '../../domain/display_text.dart';

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
  /// The ONE place the two invariants are established: a 64-hex id, and a
  /// label that has been through the display rule and its bound. Every way of
  /// getting an instance comes through here, so nothing downstream repeats the
  /// checks — `toUri` used to carry a copy of both, and a copy no caller can
  /// reach is not a guard, it is a line no test can redden.
  OproxyInvite._(String nodeId, String label)
    : nodeId = _requireHex64(nodeId),
      label = safeDisplayLabel(label, maxChars: maxLabelChars);

  /// One to share, with the id checked and the label put through the SAME rule
  /// the parser applies.
  ///
  /// The constructor used to take anything, and `toUri` neither checked the id
  /// nor bounded the result — so this app could mint a link it could not read
  /// back, and hand it to a QR renderer regardless (report16 XV-20). A share
  /// nobody can redeem is worse than a refusal, because the person believes
  /// they have shared something.
  factory OproxyInvite.share({required String nodeId, required String label}) =>
      OproxyInvite._(nodeId, label);

  /// 64 hex characters, lowercased.
  final String nodeId;

  /// What to call it in the catalog. May be empty: the catalog falls back to
  /// the id's first eight characters.
  final String label;

  static const scheme = 'veil:oproxy?';

  /// A label is attacker-controlled text that ends up in a list a person
  /// reads before deciding what to route their traffic through. Bounded well
  /// above any real name.
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
    // One rule, shared with the producer: controls, reordering marks and
    // invisible formatting out, and a bound on the length. A name in this
    // catalog is attacker-controlled text a person reads before deciding what
    // to route through.
    return OproxyInvite._(id, label);
  }

  /// The link to share. Always one this app can read back.
  ///
  /// The label is dropped rather than the whole share refused if the encoded
  /// form would not fit: the id is what makes a share useful, and the catalog
  /// names it by its prefix when there is no label.
  String toUri() {
    final suffix = label.isEmpty ? '' : '&n=${Uri.encodeComponent(label)}';
    final uri = '${scheme}id=$nodeId$suffix';
    return uri.length <= maxUriChars ? uri : '${scheme}id=$nodeId';
  }

  /// Normalised, or refused. Case and surrounding space are not part of an id.
  static String _requireHex64(String value) {
    final id = value.trim().toLowerCase();
    if (!_isHex64(id)) {
      throw ArgumentError('an oproxy share needs a 64-hex node id: $value');
    }
    return id;
  }

  static bool _isHex64(String value) =>
      value.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
}
