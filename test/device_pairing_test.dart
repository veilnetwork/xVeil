import 'dart:io';
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
}
