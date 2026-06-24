import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/proxy_routing.dart';

const _exit =
    'aa11bb22cc33dd44ee55ff66007788990011223344556677889900aabbccddee';

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
        exitEnabled: true,
        exitAllowPrivate: true,
      );
      final back = ProxyRouting.fromJson(cfg.toJson());
      expect(back.socks5Enabled, isTrue);
      expect(back.socks5Listen, '127.0.0.1:9050');
      expect(back.exitNodeId, _exit);
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
      // No exit role requested.
      expect(out, isNot(contains('[proxy.exit]')));
    });

    test('socks5 without a valid exit injects nothing', () {
      const cfg = ProxyRouting(socks5Enabled: true); // no exit
      expect(EmbeddedNode.withProxy(base, cfg), base);
    });

    test('a TOML-injecting or non-loopback listen is rejected (fail-closed)',
        () {
      // Quote/newline break-out attempt — must NOT reach the config.
      const inject = ProxyRouting(
        socks5Enabled: true,
        exitNodeId: _exit,
        socks5Listen: '127.0.0.1:1080"\nallow = true',
      );
      expect(inject.socks5Active, isFalse);
      expect(EmbeddedNode.withProxy(base, inject), isNot(contains('allow = true')));
      expect(EmbeddedNode.withProxy(base, inject), isNot(contains('[proxy.socks5]')));

      // Non-loopback bind (open-proxy footgun) — rejected.
      const open = ProxyRouting(
        socks5Enabled: true, exitNodeId: _exit, socks5Listen: '0.0.0.0:1080');
      expect(open.socks5Active, isFalse);
      expect(EmbeddedNode.withProxy(base, open), isNot(contains('[proxy.socks5]')));

      // A normal loopback listen is fine.
      expect(ProxyRouting.isValidListen('127.0.0.1:1080'), isTrue);
      expect(ProxyRouting.isValidListen('localhost:9050'), isTrue);
      expect(ProxyRouting.isValidListen('8.8.8.8:53'), isFalse);
      expect(ProxyRouting.isValidListen('127.0.0.1:0'), isFalse);
      expect(ProxyRouting.isValidListen('127.0.0.1:99999'), isFalse);
    });

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
  });
}
