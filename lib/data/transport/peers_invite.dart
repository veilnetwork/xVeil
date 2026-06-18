import 'dart:convert';

import 'bootstrap_invite.dart';

/// A peers-only share token — `veil:peers?p=<base64url(json)>` — carrying a list
/// of DIALABLE bootstrap descriptors (transport + public_key + nonce + algo) and
/// NOTHING about the sharer's identity.
///
/// Purpose: hand a friend working entry nodes — e.g. when the app's default
/// seeds are censored in their country — without revealing who you are. It is
/// deliberately distinct from a `veil:bootstrap?` contact invite: redeeming it
/// only adds bootstrap peers, it never creates a contact or exchanges keys.
class SharedPeers {
  const SharedPeers(this.peers);

  /// Each entry is a full, dialable descriptor (transport is always present).
  final List<BootstrapInvite> peers;

  static const _scheme = 'veil:peers?';

  static bool looksLikeSharedPeers(String uri) =>
      uri.trim().startsWith(_scheme);

  static SharedPeers parse(String uri) {
    final trimmed = uri.trim();
    if (!trimmed.startsWith(_scheme)) {
      throw const FormatException('not a veil peers share');
    }
    final body = trimmed.substring(_scheme.length);
    final i = body.indexOf('='); // the `p=` separator (first '=')
    if (i <= 0 || body.substring(0, i) != 'p') {
      throw const FormatException('peers share missing p=');
    }
    final jsonStr = utf8.decode(base64Url.decode(_pad(body.substring(i + 1))));
    final decoded = jsonDecode(jsonStr);
    if (decoded is! List) {
      throw const FormatException('peers share payload is not a list');
    }
    final out = <BootstrapInvite>[];
    for (final e in decoded) {
      if (e is! Map) continue;
      final pk = e['pk'], t = e['t'], nc = e['nc'];
      if (pk is! String || t is! String || nc is! String) continue;
      // Defense-in-depth: a scanned share is attacker-controlled and its
      // transport is handed to the node's bootstrap-join over IPC. Require a
      // structural `scheme://rest` URI with no whitespace/control/quote chars,
      // and skip (don't fail the whole share on) any malformed base64 entry.
      if (!_validTransport(t)) continue;
      try {
        out.add(BootstrapInvite(
          publicKey: base64.decode(pk),
          transport: t,
          nonce: base64.decode(nc),
          algo: (e['a'] as String?) ?? 'ed25519',
        ));
      } catch (_) {
        continue;
      }
    }
    if (out.isEmpty) throw const FormatException('peers share has no entries');
    return SharedPeers(out);
  }

  static bool _validTransport(String t) =>
      RegExp(r'^[a-z0-9.+-]+://[^\s\x00-\x1f"\\]+$').hasMatch(t);

  String toUri() {
    final arr = [
      for (final p in peers)
        {
          'pk': base64.encode(p.publicKey),
          't': p.transport,
          'nc': base64.encode(p.nonce),
          'a': p.algo,
        }
    ];
    final b64 = base64Url.encode(utf8.encode(jsonEncode(arr)));
    return '${_scheme}p=$b64';
  }

  static String _pad(String s) {
    final m = s.length % 4;
    return m == 0 ? s : s + '=' * (4 - m);
  }
}
