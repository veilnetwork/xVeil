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
}
