import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/proxy_routing.dart';

const _exit =
    'aa11bb22cc33dd44ee55ff66007788990011223344556677889900aabbccddee';
const _backup =
    'bb11bb22cc33dd44ee55ff66007788990011223344556677889900aabbccddee';

void main() {
  group('ProxyRouting', () {
    test('socks5 is inert without a valid 64-hex exit', () {
      const noExit = ProxyRouting(socks5Enabled: true);
      expect(noExit.socks5Active, isFalse);
      expect(noExit.isActive, isFalse);

      const badExit = ProxyRouting(socks5Enabled: true, exitNodeId: 'xyz');
      expect(badExit.socks5Active, isFalse);

      const ok = ProxyRouting(socks5Enabled: true, exitNodeId: _exit);
      expect(ok.socks5Active, isTrue);
      expect(ok.isActive, isTrue);

      const vpnOnly = ProxyRouting(exitNodeId: _exit);
      expect(vpnOnly.vpnTransportReady, isTrue);
      expect(vpnOnly.socks5Active, isFalse);
      expect(vpnOnly.isActive, isFalse);
    });

    test('exit role is independent of socks5', () {
      const exitOnly = ProxyRouting(exitEnabled: true);
      expect(exitOnly.socks5Active, isFalse);
      expect(exitOnly.isActive, isTrue);
    });

    test('round-trips through json', () {
      const cfg = ProxyRouting(
        socks5Enabled: true,
        socks5Listen: '127.0.0.1:9050',
        exitNodeId: _exit,
        oProxies: [
          OproxyEndpoint(nodeId: _exit, label: 'Primary'),
          OproxyEndpoint(nodeId: _backup, label: 'Backup'),
        ],
        defaultOproxyNodeIds: [_exit, _backup],
        exitEnabled: true,
        exitAllowPrivate: true,
      );
      final back = ProxyRouting.fromJson(cfg.toJson());
      expect(back.socks5Enabled, isTrue);
      expect(back.socks5Listen, '127.0.0.1:9050');
      expect(back.exitNodeId, _exit);
      expect(back.effectiveOproxies, hasLength(2));
      expect(back.effectiveDefaultOproxyNodeIds, [_exit, _backup]);
      expect(back.exitEnabled, isTrue);
      expect(back.exitAllowPrivate, isTrue);
    });
  });

  group('EmbeddedNode.withProxy', () {
    const base = '[identity]\nx = 1\n';

    test('disabled routing injects nothing', () {
      expect(EmbeddedNode.withProxy(base, ProxyRouting.disabled), base);
    });

    test('socks5 with a valid exit injects [proxy.socks5]', () {
      const cfg = ProxyRouting(
        socks5Enabled: true,
        socks5Listen: '127.0.0.1:1080',
        exitNodeId: _exit,
      );
      final out = EmbeddedNode.withProxy(base, cfg);
      expect(out, contains('[proxy.socks5]'));
      expect(out, contains('enabled = true'));
      expect(out, contains('listen = "127.0.0.1:1080"'));
      expect(out, contains('exit_node_id = "$_exit"'));
      expect(out, contains('exit_node_ids = ["$_exit"]'));
      // No exit role requested.
      expect(out, isNot(contains('[proxy.exit]')));
    });

    test('runtime profiles keep independent ordered fallback chains', () {
      const cfg = ProxyRouting(
        runtimeSocksProfiles: [
          ProxySocksProfile(
            listen: '127.0.0.1:1081',
            exitNodeIds: [_exit, _backup],
          ),
          ProxySocksProfile(listen: '127.0.0.1:1082', exitNodeIds: [_backup]),
        ],
      );
      final out = EmbeddedNode.withProxy(base, cfg);
      expect('[proxy.socks5_profiles]'.allMatches(out), hasLength(2));
      expect(out, contains('listen = "127.0.0.1:1081"'));
      expect(out, contains('exit_node_ids = ["$_exit", "$_backup"]'));
    });

    test('socks5 without a valid exit injects nothing', () {
      const cfg = ProxyRouting(socks5Enabled: true); // no exit
      expect(EmbeddedNode.withProxy(base, cfg), base);
    });

    test(
      'a TOML-injecting or non-loopback listen is rejected (fail-closed)',
      () {
        // Quote/newline break-out attempt — must NOT reach the config.
        const inject = ProxyRouting(
          socks5Enabled: true,
          exitNodeId: _exit,
          socks5Listen: '127.0.0.1:1080"\nallow = true',
        );
        expect(inject.socks5Active, isFalse);
        expect(
          EmbeddedNode.withProxy(base, inject),
          isNot(contains('allow = true')),
        );
        expect(
          EmbeddedNode.withProxy(base, inject),
          isNot(contains('[proxy.socks5]')),
        );

        // Non-loopback bind (open-proxy footgun) — rejected.
        const open = ProxyRouting(
          socks5Enabled: true,
          exitNodeId: _exit,
          socks5Listen: '0.0.0.0:1080',
        );
        expect(open.socks5Active, isFalse);
        expect(
          EmbeddedNode.withProxy(base, open),
          isNot(contains('[proxy.socks5]')),
        );

        // A normal loopback listen is fine.
        expect(ProxyRouting.isValidListen('127.0.0.1:1080'), isTrue);
        expect(ProxyRouting.isValidListen('localhost:9050'), isTrue);
        expect(ProxyRouting.isValidListen('8.8.8.8:53'), isFalse);
        expect(ProxyRouting.isValidListen('127.0.0.1:0'), isFalse);
        expect(ProxyRouting.isValidListen('127.0.0.1:99999'), isFalse);
      },
    );

    test('exit role injects [proxy.exit] with allow_private', () {
      const cfg = ProxyRouting(exitEnabled: true, exitAllowPrivate: false);
      final out = EmbeddedNode.withProxy(base, cfg);
      expect(out, contains('[proxy.exit]'));
      expect(out, contains('allow_private = false'));
      expect(out, isNot(contains('[proxy.socks5]')));
    });

    test('both roles can be injected together', () {
      const cfg = ProxyRouting(
        socks5Enabled: true,
        exitNodeId: _exit,
        exitEnabled: true,
      );
      final out = EmbeddedNode.withProxy(base, cfg);
      expect(out, contains('[proxy.socks5]'));
      expect(out, contains('[proxy.exit]'));
    });

    test('is idempotent — never double-injects', () {
      const cfg = ProxyRouting(exitEnabled: true);
      final once = EmbeddedNode.withProxy(base, cfg);
      final twice = EmbeddedNode.withProxy(once, cfg);
      expect(twice, once);
    });
  });

  group('EmbeddedNode.withTransportRotation', () {
    const base = '[global]\nruntime_flavor = "multi_thread"\n';

    test('injects [transport.rotation] with a 6-12h window', () {
      final out = EmbeddedNode.withTransportRotation(base);
      expect(out, contains('[transport.rotation]'));
      // 6h floor / 12h ceiling: rotations rarer than any delivery window so the
      // recipient's rendezvous session (and its relay subscriber) survives.
      expect(out, contains('min_lifetime_secs = 21600'));
      expect(out, contains('max_lifetime_secs = 43200'));
    });

    test('window is valid (>= 60 floor, max >= min)', () {
      // veil rejects positive lifetimes < 60 and max < min; guard the constants.
      const min = 21600, max = 43200;
      expect(min, greaterThanOrEqualTo(60));
      expect(max, greaterThanOrEqualTo(min));
    });

    test('is idempotent — never double-injects', () {
      final once = EmbeddedNode.withTransportRotation(base);
      final twice = EmbeddedNode.withTransportRotation(once);
      expect(twice, once);
    });

    // The case production actually hands it, and the one the tests above never
    // did: `veil_config_compose` renders a FULL config, so the section arrives
    // already present, carrying veil's own defaults — 1800/3600, the very
    // numbers this helper exists to replace. The old guard returned early on
    // exactly this input, so the helper did nothing for as long as it existed
    // while every test above stayed green. Measured 23.08 on the phone:
    // sessions to one seed reopened at 37, 27 and 32 minutes.
    const rendered =
        '[global]\nruntime_flavor = "multi_thread"\n'
        '[transport.rotation]\n'
        'min_lifetime_secs = 1800\n'
        'max_lifetime_secs = 3600\n';

    test('replaces veil defaults when the section is ALREADY rendered', () {
      final out = EmbeddedNode.withTransportRotation(rendered);
      expect(out, contains('min_lifetime_secs = 21600'));
      expect(out, contains('max_lifetime_secs = 43200'));
      expect(out, isNot(contains('min_lifetime_secs = 1800')));
      expect(out, isNot(contains('max_lifetime_secs = 3600')));
    });

    test('does not duplicate the rendered section', () {
      final out = EmbeddedNode.withTransportRotation(rendered);
      expect(
        '[transport.rotation]'.allMatches(out).length,
        1,
        reason: 'a second table is a duplicate key the TOML parser rejects',
      );
      expect('min_lifetime_secs'.allMatches(out).length, 1);
    });
  });

  group('EmbeddedNode.withOutboundCoalescing', () {
    // Every frame costs framing and obfs4 padding whatever it carries: measured
    // 23.08 over 599 s on one seed link, 260 bytes per frame against 190 B/s of
    // bodies — about twice the payload. Outbound frames cluster, so a 200 ms
    // window merges 39% of them.
    test('sets both keys when [mobile] is absent', () {
      const base = '[global]\nruntime_flavor = "multi_thread"\n';
      final out = EmbeddedNode.withOutboundCoalescing(base);
      expect(out, contains('[mobile]'));
      expect(out, contains('outbound_batch_window_ms = 200'));
      expect(out, contains('outbound_batch_always = true'));
    });

    // `always` is not optional: veil gates the window behind a LOW BATTERY
    // reading because it was built as a radio-wake saver. Without the flag the
    // window is inert on a charging phone, which is where it was measured.
    test('always is set, or the window never engages on mains', () {
      const base = '[global]\n';
      expect(
        EmbeddedNode.withOutboundCoalescing(base),
        contains('outbound_batch_always = true'),
      );
    });

    test('replaces rendered values instead of duplicating the table', () {
      const rendered =
          '[global]\n[mobile]\n'
          'low_battery_multiplier = 0\n'
          'outbound_batch_window_ms = 999\n';
      final out = EmbeddedNode.withOutboundCoalescing(rendered);
      expect(out, contains('outbound_batch_window_ms = 200'));
      expect(out, isNot(contains('999')));
      expect(out, contains('outbound_batch_always = true'));
      expect('[mobile]'.allMatches(out).length, 1);
      expect('outbound_batch_window_ms'.allMatches(out).length, 1);
      expect(
        out,
        contains('low_battery_multiplier = 0'),
        reason: 'untouched keys in the same table must survive',
      );
    });

    test('is idempotent', () {
      const base = '[global]\n[mobile]\nlow_battery_multiplier = 0\n';
      final once = EmbeddedNode.withOutboundCoalescing(base);
      expect(EmbeddedNode.withOutboundCoalescing(once), once);
    });
  });

  /// The catalog is "nodes this app can route through", and what makes a node
  /// that is veil's `[proxy.exit]` — the node runtime registers the well-known
  /// exit app id only when it is enabled, and the connector dials nothing else.
  ///
  /// The rule used to follow the `oproxy-server` COMPONENT, a separate program
  /// answering a separate derived app id this app never speaks. Wrong in both
  /// directions, and the second half is the one the first live run hit: an exit
  /// was deployed, no catalog entry appeared, and the 64-hex node id had to be
  /// typed in by hand.
  group('what a finished deployment puts in the exit catalog', () {
    const empty = ProxyRouting();

    test('an exit is registered', () {
      final updated = routingWithDeployedExit(
        empty,
        isExit: true,
        nodeId: _exit,
        label: 'exit-host',
      );
      expect(updated, isNotNull);
      expect(updated!.oProxies.single.nodeId, _exit);
      expect(updated.oProxies.single.label, 'exit-host');
    });

    test('a node deployed WITHOUT the exit is not registered', () {
      expect(
        routingWithDeployedExit(
          empty,
          isExit: false,
          nodeId: _exit,
          label: 'relay only',
        ),
        isNull,
        reason:
            'without [proxy.exit] the node registers no exit endpoint, so a '
            'catalog entry for it is one nothing can dial',
      );
      // Premise: the same call DOES register when the exit is on, so this null
      // is a decision about the exit and not a rejected node id.
      expect(
        routingWithDeployedExit(
          empty,
          isExit: true,
          nodeId: _exit,
          label: 'relay only',
        ),
        isNotNull,
      );
    });

    test('a node that reported no usable id is not registered', () {
      expect(
        routingWithDeployedExit(empty, isExit: true, nodeId: null, label: 'x'),
        isNull,
      );
      expect(
        routingWithDeployedExit(
          empty,
          isExit: true,
          nodeId: 'not-hex',
          label: 'x',
        ),
        isNull,
        reason: 'a blank or malformed entry is worse than none',
      );
    });

    test('a node already routable is not added twice', () {
      // Present only through the default chain, not in oProxies: the dedup has
      // to look at the EFFECTIVE catalog or it duplicates under a new label.
      const viaDefaultChain = ProxyRouting(defaultOproxyNodeIds: [_exit]);
      expect(viaDefaultChain.effectiveOproxies.single.nodeId, _exit);
      expect(
        routingWithDeployedExit(
          viaDefaultChain,
          isExit: true,
          nodeId: _exit,
          label: 'same node, new label',
        ),
        isNull,
      );
    });

    test('an unrelated entry already in the catalog is kept', () {
      const withOther = ProxyRouting(
        oProxies: [OproxyEndpoint(nodeId: _backup, label: 'other')],
      );
      final updated = routingWithDeployedExit(
        withOther,
        isExit: true,
        nodeId: _exit,
        label: 'new',
      );
      expect(updated!.oProxies.map((e) => e.nodeId), [_backup, _exit]);
    });
  });

  /// `vpnTransportReady` is a conjunction of two unrelated requirements — an
  /// exit to route through, and a loopback address to listen on — and both
  /// screens answered a false with ONE sentence: "choose a valid exit node".
  ///
  /// Someone whose exit chain was already correct and whose listen field held
  /// `127.0.0.1: by1080` was therefore sent to fix the exit, with the VPN
  /// button greyed out and nothing else to read. Measured on myself: several
  /// minutes hunting a chain that was right.
  group('which half of the VPN transport is missing', () {
    test('an empty catalog names the exit', () {
      expect(const ProxyRouting().vpnTransportGap, VpnTransportGap.noExit);
    });

    test('a bad listen address names the listen address', () {
      const routing = ProxyRouting(
        defaultOproxyNodeIds: [_exit],
        socks5Listen: '127.0.0.1: by1080',
      );
      expect(routing.vpnTransportGap, VpnTransportGap.badListen);
      expect(routing.vpnTransportReady, isFalse);
    });

    test('a non-loopback listen is named the same way', () {
      const routing = ProxyRouting(
        defaultOproxyNodeIds: [_exit],
        socks5Listen: '0.0.0.0:1080',
      );
      expect(routing.vpnTransportGap, VpnTransportGap.badListen);
    });

    test('both present is no gap at all', () {
      // Vacuity guard: the same shape with both halves right reports nothing
      // missing, so the answers above are about the missing half and not about
      // the getter always finding something.
      const routing = ProxyRouting(
        defaultOproxyNodeIds: [_exit],
        socks5Listen: '127.0.0.1:1080',
      );
      expect(routing.vpnTransportGap, isNull);
      expect(routing.vpnTransportReady, isTrue);
    });

    test('the exit is named before the listen when both are missing', () {
      // An arbitrary order, but a fixed one: a reader fixing the first thing
      // named should not be told the same sentence twice.
      const routing = ProxyRouting(socks5Listen: 'nonsense');
      expect(routing.vpnTransportGap, VpnTransportGap.noExit);
    });
  });

  /// `withProxy` used to step aside whenever the document already carried a
  /// `[proxy.…]` table, as a guard against appending a second copy. It replaces
  /// now: for the embedded node this app AUTHORS the config, so a table it
  /// finds is last boot's answer to a question the user has since answered
  /// differently — and replacing makes composition idempotent, which stepping
  /// aside was not.
  ///
  /// ⚠️ An earlier version of this comment claimed a composed config always
  /// carries those tables and that the routing screen was therefore inert.
  /// That was wrong: it generalised from a DEPLOYED node.toml (where the
  /// deployment explicitly enables the exit) to a COMPOSED one. Measured
  /// since — a default `veil-cli config init` renders `[global] [transport]
  /// [transport.rotation] [transport.tls_fingerprint] [Identity] [mobile]` and
  /// no `[proxy.…]`, because `ProxyConfig` is skipped when default. The guard
  /// did not fire. The single exit candidate seen on a phone came from the
  /// VPN's own pinned chain, which is a different field.
  ///
  /// The tests below are unchanged and still worth having: they pin the
  /// replacement behaviour itself.
  group('a config that already carries a proxy table', () {
    const withTable =
        '[identity]\nx = 1\n\n'
        '[proxy.socks5]\nenabled = false\nlisten = "127.0.0.1:9999"\n'
        'exit_node_id = "$_backup"\n\n'
        '[dht]\nbucket = 8\n';

    test('the app replaces it instead of standing down', () {
      const cfg = ProxyRouting(
        socks5Enabled: true,
        socks5Listen: '127.0.0.1:1080',
        defaultOproxyNodeIds: [_exit, _backup],
        oProxies: [
          OproxyEndpoint(nodeId: _exit, label: 'one'),
          OproxyEndpoint(nodeId: _backup, label: 'two'),
        ],
      );
      final out = EmbeddedNode.withProxy(withTable, cfg);
      expect(
        out,
        contains('exit_node_ids = ["$_exit", "$_backup"]'),
        reason: 'the chain the person configured has to reach the node',
      );
      expect(
        out,
        isNot(contains('127.0.0.1:9999')),
        reason: 'the stale listen is last boot\'s answer, not a setting',
      );
      expect(
        '[proxy.socks5]'.allMatches(out).length,
        1,
        reason: 'replacing must not leave two tables for veil to choose from',
      );
    });

    test('tables that are not ours survive', () {
      const cfg = ProxyRouting(
        socks5Enabled: true,
        socks5Listen: '127.0.0.1:1080',
        exitNodeId: _exit,
      );
      final out = EmbeddedNode.withProxy(withTable, cfg);
      expect(out, contains('[identity]'));
      expect(out, contains('[dht]'));
      expect(out, contains('bucket = 8'), reason: 'a table AFTER ours too');
    });

    test('turning routing off takes the stale table with it', () {
      // Otherwise "off" would mean "keep whatever the node was last told",
      // which is the same silence in the other direction.
      final out = EmbeddedNode.withProxy(withTable, ProxyRouting.disabled);
      expect(out, isNot(contains('[proxy.')));
      expect(out, contains('[dht]'));
    });

    test('repeated composition does not grow the file', () {
      const cfg = ProxyRouting(
        socks5Enabled: true,
        socks5Listen: '127.0.0.1:1080',
        exitNodeId: _exit,
      );
      final once = EmbeddedNode.withProxy(withTable, cfg);
      final twice = EmbeddedNode.withProxy(once, cfg);
      expect(twice, once, reason: 'composing the same routing is idempotent');
    });
  });
}
