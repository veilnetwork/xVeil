import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/vpn/socks5_transport_preflight.dart';

void main() {
  test('requires a successful CONNECT reply through the exit', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final handled = server.first.then((socket) async {
      final iterator = StreamIterator<List<int>>(socket);
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.take(3), orderedEquals([0x05, 0x01, 0x00]));
      socket.add([0x05, 0x00]);
      await socket.flush();
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.take(4), orderedEquals([0x05, 0x01, 0x00, 0x01]));
      socket.add([0x05, 0x00]);
      await socket.flush();
      await socket.close();
      await iterator.cancel();
    });

    await Socks5TransportPreflight.verify('127.0.0.1:${server.port}');
    await handled;
  });

  test('rejects a listener whose exit cannot connect', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final handled = server.first.then((socket) async {
      final iterator = StreamIterator<List<int>>(socket);
      await iterator.moveNext();
      socket.add([0x05, 0x00]);
      await socket.flush();
      await iterator.moveNext();
      socket.add([0x05, 0x04]);
      await socket.flush();
      await socket.close();
      await iterator.cancel();
    });

    await expectLater(
      Socks5TransportPreflight.verify('127.0.0.1:${server.port}'),
      throwsA(isA<Socks5TransportException>()),
    );
    await handled;
  });
}
