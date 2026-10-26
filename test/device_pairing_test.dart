import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/device_pairing_lan.dart';
import 'package:xveil/domain/device_pairing.dart';

BootstrapInvite _invite(int seed) => BootstrapInvite(
  publicKey: Uint8List.fromList(List.filled(32, seed)),
  nonce: Uint8List.fromList([seed, seed + 1, seed + 2]),
);

void main() {
  test(
    'a disappearing interface does not close the reachable LAN listener',
    () async {
      final seed = DevicePairingCode.fresh(
        _invite(1),
        _invite(2),
        hosts: ['127.0.0.1'],
        port: 1,
      );
      final missing = InternetAddress('192.0.2.1'); // Not assigned here.
      for (final addresses in [
        [InternetAddress.loopbackIPv4, missing],
        [missing, InternetAddress.loopbackIPv4],
      ]) {
        final server = await DevicePairingLanServer.start(
          seed.ticket,
          (request) async => 'paired',
          bindAddresses: addresses,
        );
        addTearDown(server.close);
        expect(server.boundHosts, ['127.0.0.1']);
        final code = DevicePairingCode(
          device: seed.device,
          source: seed.source,
          ticket: seed.ticket,
          expiresAt: seed.expiresAt,
          hosts: server.boundHosts,
          port: server.port,
        );
        expect(
          await DevicePairingLanClient.exchange(code, 'request'),
          'paired',
        );
      }
      await expectLater(
        DevicePairingLanServer.start(
          seed.ticket,
          (request) async => 'paired',
          bindAddresses: [missing],
        ),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test('pairing refuses wildcard listeners', () async {
    final code = DevicePairingCode.fresh(
      _invite(1),
      _invite(2),
      hosts: ['127.0.0.1'],
      port: 1,
    );
    for (final address in [InternetAddress.anyIPv4, InternetAddress.anyIPv6]) {
      await expectLater(
        DevicePairingLanServer.start(
          code.ticket,
          (request) async => request,
          bindAddresses: [address],
        ),
        throwsArgumentError,
      );
    }
  });

  test('LAN ready waits for the joined identity to boot', () async {
    final booted = Completer<bool>();
    final events = <String>[];
    final pairing = signalPairingReadyAfterRestart(
      restart: () async {
        events.add('restart');
        return booted.future;
      },
      signalReady: () async => events.add('ready'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(events, ['restart']);
    booted.complete(true);
    expect(await pairing, isTrue);
    expect(events, ['restart', 'ready']);

    events.clear();
    expect(
      await signalPairingReadyAfterRestart(
        restart: () async => false,
        signalReady: () async => events.add('ready'),
      ),
      isFalse,
    );
    expect(events, isEmpty);
    expect(
      await signalPairingReadyAfterRestart(
        restart: () async => throw StateError('node did not boot'),
        signalReady: () async => events.add('ready'),
      ),
      isFalse,
    );
    expect(events, isEmpty);
  });

  test('one QR binds device, identity, LAN endpoint and fresh ticket', () {
    final code = DevicePairingCode.fresh(
      _invite(1),
      _invite(2),
      hosts: ['192.168.1.5'],
      port: 12345,
    );
    final parsed = DevicePairingCode.parse(code.toUri());
    expect(parsed.device.nodeId, code.device.nodeId);
    expect(parsed.identity, code.identity);
    expect(parsed.ticket, code.ticket);
    expect(parsed.hosts, ['192.168.1.5']);
    expect(parsed.port, 12345);
    expect(parsed.expired, isFalse);
    expect(
      devicePairingSafetyCode(code.ticket, _invite(1).nodeId),
      hasLength(6),
    );
    expect(
      devicePairingSafetyCode(code.ticket, _invite(1).nodeId),
      isNot(devicePairingSafetyCode(code.ticket, _invite(3).nodeId)),
    );
    expect(code.toUri().length, lessThan(2953));
    expect(
      DevicePairingCode.fresh(
        _invite(1),
        _invite(2),
        hosts: ['192.168.1.5'],
        port: 12345,
      ).ticket,
      isNot(code.ticket),
    );
    expect(
      () => DevicePairingCode.parse(
        code.toUri().replaceFirst('t=${code.ticket}', 't=bad'),
      ),
      throwsFormatException,
    );
    expect(
      () => DevicePairingCode.parse(
        code.toUri().replaceFirst('192.168.1.5', '127.0.0.1'),
      ),
      throwsFormatException,
    );
  });

  test(
    'temporary encrypted LAN channel carries a large token and ready ack',
    () async {
      final seed = DevicePairingCode.fresh(
        _invite(1),
        _invite(2),
        hosts: ['127.0.0.1'],
        port: 1,
      );
      final requests = <String>[];
      final token = 'veil:token?doc=${'x' * 24000}';
      final server = await DevicePairingLanServer.start(seed.ticket, (
        request,
      ) async {
        requests.add(request);
        return request == 'ready' ? 'ack' : token;
      }, bindAddress: InternetAddress.loopbackIPv4);
      addTearDown(server.close);
      final code = DevicePairingCode(
        device: seed.device,
        source: seed.source,
        ticket: seed.ticket,
        expiresAt: seed.expiresAt,
        hosts: ['127.0.0.1'],
        port: server.port,
      );
      expect(await DevicePairingLanClient.exchange(code, 'request'), token);
      expect(await DevicePairingLanClient.exchange(code, 'ready'), 'ack');
      expect(requests, ['request', 'ready']);

      final wrong = DevicePairingCode.fresh(
        seed.device,
        seed.source,
        hosts: ['127.0.0.1'],
        port: server.port,
      );
      await expectLater(
        DevicePairingLanClient.exchange(wrong, 'request'),
        throwsStateError,
      );
      expect(requests, ['request', 'ready']);
    },
  );

  test('direct exchange reports an unreachable peer', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = listener.port;
    await listener.close();
    final code = DevicePairingCode.fresh(
      _invite(1),
      _invite(2),
      hosts: ['127.0.0.1'],
      port: port,
    );
    await expectLater(
      DevicePairingLanClient.exchange(code, 'request'),
      throwsStateError,
    );
  });

  test(
    'a stalled interface does not block another authenticated endpoint',
    () async {
      final seed = DevicePairingCode.fresh(
        _invite(1),
        _invite(2),
        hosts: ['127.0.0.1'],
        port: 1,
      );
      final server = await DevicePairingLanServer.start(
        seed.ticket,
        (request) async => 'paired',
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(server.close);
      // Two local interfaces at the same advertised port. The first accepts
      // TCP but never returns a packet, as a stale adapter/service can do.
      final stalled = await ServerSocket.bind(
        InternetAddress.loopbackIPv6,
        server.port,
        v6Only: true,
      );
      final sockets = <Socket>[];
      final closed = Completer<void>();
      final subscription = stalled.listen((socket) {
        sockets.add(socket);
        socket.listen(
          (_) {},
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
        );
      });
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await subscription.cancel();
        await stalled.close();
      });
      final code = DevicePairingCode(
        device: seed.device,
        source: seed.source,
        ticket: seed.ticket,
        expiresAt: seed.expiresAt,
        hosts: ['::1', '127.0.0.1'],
        port: server.port,
      );
      expect(
        await DevicePairingLanClient.exchange(
          code,
          'request',
        ).timeout(const Duration(seconds: 2)),
        'paired',
      );
      await closed.future.timeout(const Duration(seconds: 2));
    },
  );

  test('a faster invalid response cannot win endpoint selection', () async {
    final seed = DevicePairingCode.fresh(
      _invite(1),
      _invite(2),
      hosts: ['127.0.0.1'],
      port: 1,
    );
    final invalidSent = Completer<void>();
    final server = await DevicePairingLanServer.start(seed.ticket, (
      request,
    ) async {
      await invalidSent.future;
      return 'authenticated';
    }, bindAddress: InternetAddress.loopbackIPv4);
    addTearDown(server.close);
    final invalid = await ServerSocket.bind(
      InternetAddress.loopbackIPv6,
      server.port,
      v6Only: true,
    );
    final sockets = <Socket>[];
    final subscription = invalid.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {
        if (invalidSent.isCompleted) return;
        // Correct framing, invalid AEAD authentication.
        final packet = Uint8List(32);
        ByteData.sublistView(packet).setUint32(0, 28);
        socket.add(packet);
        invalidSent.complete();
      }, onError: (Object _) {});
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await invalid.close();
    });
    final code = DevicePairingCode(
      device: seed.device,
      source: seed.source,
      ticket: seed.ticket,
      expiresAt: seed.expiresAt,
      hosts: ['::1', '127.0.0.1'],
      port: server.port,
    );
    expect(
      await DevicePairingLanClient.exchange(
        code,
        'request',
      ).timeout(const Duration(seconds: 2)),
      'authenticated',
    );
  });

  test('endpoint racing retains a bounded, deduplicated fanout', () async {
    final seed = DevicePairingCode.fresh(
      _invite(1),
      _invite(2),
      hosts: ['127.0.0.1'],
      port: 1,
    );
    var requests = 0;
    final server = await DevicePairingLanServer.start(seed.ticket, (
      request,
    ) async {
      requests++;
      return 'paired';
    }, bindAddress: InternetAddress.loopbackIPv4);
    addTearDown(server.close);
    DevicePairingCode at(List<String> hosts) => DevicePairingCode(
      device: seed.device,
      source: seed.source,
      ticket: seed.ticket,
      expiresAt: seed.expiresAt,
      hosts: hosts,
      port: server.port,
    );
    expect(
      await DevicePairingLanClient.exchange(
        at(List.filled(6, '127.0.0.1')),
        'request',
      ),
      'paired',
    );
    expect(requests, 1);
    await expectLater(
      DevicePairingLanClient.exchange(
        at(List.generate(7, (i) => '127.0.0.${i + 1}')),
        'request',
      ),
      throwsStateError,
    );
    expect(requests, 1);
  });
}
