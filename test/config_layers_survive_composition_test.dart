import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/proxy_routing.dart';

/// Every `with*` layer's answer must survive composition.
///
/// The layers are appended one after another to whatever the native
/// `veil_config_compose` produced, and several of them step aside when they see
/// their own marker already in the document. That is fine only while the base
/// does not carry that marker — and the base is not this app's to control: it
/// is whatever veil's serializer writes, which changes when veil changes.
///
/// It has gone wrong for real. `withTransportRotation` did nothing for months
/// because `[transport.rotation]` IS always serialized (`TransportConfig` has
/// no `skip_serializing_if`), so the helper always returned early and the phone
/// rotated on veil's 30–60 minute default exactly as if the fix had never been
/// written. A per-layer unit test did not catch it: each layer was correct in
/// isolation, over a base that did not have the marker.
///
/// So this composes over the REAL base. The sections below are what a default
/// `veil-cli config init` renders, measured on a live node on 2026-08-26:
///
///     [global] [transport] [transport.rotation] [transport.tls_fingerprint]
///     [Identity] [mobile]
///
/// If veil starts serializing another table by default, whichever layer keys on
/// it goes quiet — and this test goes red instead.
void main() {
  /// What veil actually writes for a fresh node, including the rotation window
  /// at ITS defaults, which is the pair the app exists to replace.
  const base = '''
[global]
admin_socket = "unix:///tmp/admin.sock"
builtin_seed_policy = "auto"

[transport]
handshake_timeout_ms = 10000

[transport.rotation]
min_lifetime_secs = 1800
max_lifetime_secs = 3600

[transport.tls_fingerprint]
enabled = false

[Identity]
node_id = "aa"

[mobile]
enabled = false
''';

  /// The layers in the order `composeConfig` applies them.
  String composeLike(String toml, {required ProxyRouting proxy}) {
    var out = EmbeddedNode.withAnonymity(toml, false);
    out = EmbeddedNode.withLazyMining(out, false);
    out = EmbeddedNode.withClientNodeRole(out);
    out = EmbeddedNode.withDhtParticipation(out, participate: false);
    out = EmbeddedNode.withMobileServiceBudget(out, isMobile: true);
    out = EmbeddedNode.withBootstrapPeers(out, const []);
    out = EmbeddedNode.withProxy(out, proxy);
    out = EmbeddedNode.withUdpReflectors(out, const ['1.2.3.4:5000']);
    out = EmbeddedNode.withObfs4PskFile(out, '/var/lib/veil/psk.b64');
    out = EmbeddedNode.withSessionKeepalive(out);
    out = EmbeddedNode.withTransportRotation(out);
    out = EmbeddedNode.withBuiltinSeedPolicy(out, false);
    out = EmbeddedNode.withIdentityDir(out, '/data/identity');
    return out;
  }

  final exit = 'b95b118d'.padRight(64, 'a');
  final proxy = ProxyRouting.disabled.copyWith(
    socks5Enabled: true,
    socks5Listen: '127.0.0.1:1080',
    oProxies: [OproxyEndpoint(nodeId: exit, label: 'exit')],
    defaultOproxyNodeIds: [exit],
  );

  test('the rotation window is the app’s, not veil’s default', () {
    final out = composeLike(base, proxy: proxy);

    // The exact defect that shipped silently: veil's own 1800/3600 surviving
    // because the helper saw its section and stepped aside.
    expect(
      out,
      isNot(contains('min_lifetime_secs = 1800')),
      reason: 'veil’s default rotation window must not survive composition',
    );
    expect(out, contains('[transport.rotation]'));
  });

  test('every layer that was asked for something leaves a trace', () {
    final out = composeLike(base, proxy: proxy);

    final expected = {
      'session keepalive': 'keepalive_interval_secs',
      'dht participation': 'participate',
      'mobile service budget': 'service_budget_bytes_per_hour',
      'udp reflectors': 'udp_reflectors',
      'obfs4 psk file': 'obfs4_psk_file',
      'builtin seed policy': 'builtin_seed_policy',
      'identity directory': 'identity_dir',
      'proxy socks5': '[proxy.socks5]',
      'exit chain': exit,
    };
    final missing = <String>[
      for (final entry in expected.entries)
        if (!out.contains(entry.value)) '${entry.key} (${entry.value})',
    ];

    expect(missing, isEmpty, reason: 'these layers went quiet: $missing');
  });

  test('the base’s own sections are not duplicated', () {
    final out = composeLike(base, proxy: proxy);

    // A layer that appends instead of replacing gives veil two answers and
    // whichever it parses last wins — silently.
    for (final section in [
      '[transport.rotation]',
      '[proxy.socks5]',
      '[Identity]',
      '[mobile]',
    ]) {
      expect(
        RegExp(RegExp.escape(section)).allMatches(out).length,
        1,
        reason: '$section appears more than once',
      );
    }
  });

  test('composing twice neither loses nor duplicates anything', () {
    final once = composeLike(base, proxy: proxy);
    final twice = composeLike(once, proxy: proxy);

    // NOT byte equality: `withProxy` strips its tables and re-appends them, so
    // a second pass moves them after `[nat]`. Table order carries no meaning in
    // TOML, and composition always starts from a fresh native template in
    // production anyway. What WOULD matter is a line appearing twice or
    // vanishing — measured here as a multiset, which is exactly the drift a
    // non-idempotent layer produces.
    List<String> lines(String toml) =>
        (toml.split('\n').where((l) => l.trim().isNotEmpty).toList()..sort());

    expect(lines(twice), lines(once));
  });

  test('a base WITHOUT the rotation section still gets the window', () {
    // Premise for the first test: it must fail because the layer replaced a
    // value, not because the value is absent from every document.
    const bare = '[global]\nadmin_socket = "unix:///tmp/a.sock"\n';
    final out = composeLike(bare, proxy: proxy);

    expect(out, contains('[transport.rotation]'));
    expect(out, isNot(contains('min_lifetime_secs = 1800')));
  });
}
