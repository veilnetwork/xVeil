import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/ids.dart';
import '../../domain/device_pairing.dart';

const _maxPacketBytes = 40 * 1024;
final _cipher = Chacha20.poly1305Aead();
final _aad = utf8.encode('xveil.device-pair.lan.v1');

Future<List<String>> localPairingAddresses() async {
  final interfaces = await NetworkInterface.list(
    includeLinkLocal: false,
    type: InternetAddressType.IPv4,
  );
  final addresses = <String>{};
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      final parts = address.address.split('.').map(int.tryParse).toList();
      if (parts.length != 4 || parts.any((part) => part == null)) continue;
      final a = parts[0]!, b = parts[1]!;
      if (a == 10 ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168)) {
        addresses.add(address.address);
      }
    }
  }
  return addresses.take(6).toList();
}

Future<Uint8List> _seal(String ticket, String plain) async {
  final random = Random.secure();
  final nonce = List<int>.generate(12, (_) => random.nextInt(256));
  final box = await _cipher.encrypt(
    utf8.encode(plain),
    secretKey: SecretKey(NodeId.fromHex(ticket).bytes),
    nonce: nonce,
    aad: _aad,
  );
  return Uint8List.fromList([...nonce, ...box.mac.bytes, ...box.cipherText]);
}

Future<String> _open(String ticket, Uint8List packet) async {
  if (packet.length < 28 || packet.length > _maxPacketBytes) {
    throw const FormatException('invalid pairing packet');
  }
  try {
    final clear = await _cipher.decrypt(
      SecretBox(
        packet.sublist(28),
        nonce: packet.sublist(0, 12),
        mac: Mac(packet.sublist(12, 28)),
      ),
      secretKey: SecretKey(NodeId.fromHex(ticket).bytes),
      aad: _aad,
    );
    return utf8.decode(clear);
  } on SecretBoxAuthenticationError {
    throw const FormatException('pairing authentication failed');
  }
}

Future<Uint8List> _readPacket(Socket socket) async {
  final complete = Completer<Uint8List>();
  final bytes = BytesBuilder(copy: false);
  late final StreamSubscription<Uint8List> subscription;
  subscription = socket.listen(
    (chunk) {
      if (complete.isCompleted) return;
      bytes.add(chunk);
      if (bytes.length < 4) return;
      final data = bytes.toBytes();
      final size = ByteData.sublistView(data, 0, 4).getUint32(0);
      if (size < 28 || size > _maxPacketBytes || data.length > size + 4) {
        complete.completeError(const FormatException('invalid pairing packet'));
        return;
      }
      if (data.length == size + 4) {
        complete.complete(Uint8List.sublistView(data, 4));
      }
    },
    onError: complete.completeError,
    onDone: () {
      if (!complete.isCompleted) {
        complete.completeError(
          const FormatException('pairing packet truncated'),
        );
      }
    },
  );
  try {
    return await complete.future;
  } finally {
    await subscription.cancel();
  }
}

Future<void> _writePacket(Socket socket, Uint8List packet) async {
  if (packet.length > _maxPacketBytes) {
    throw const FormatException('pairing packet too large');
  }
  final header = ByteData(4)..setUint32(0, packet.length);
  socket.add(header.buffer.asUint8List());
  socket.add(packet);
  await socket.flush();
}

/// A temporary encrypted local socket. It exists only while the desktop's
/// pairing sheet is open. Each connection carries one request and one reply.
class DevicePairingLanServer {
  DevicePairingLanServer._(this._server, this._ticket, this._onRequest);

  final ServerSocket _server;
  final String _ticket;
  final Future<String> Function(String) _onRequest;
  final _sockets = <Socket>{};
  late final StreamSubscription<Socket> _subscription;
  int get port => _server.port;

  static Future<DevicePairingLanServer> start(
    String ticket,
    Future<String> Function(String) onRequest, {
    InternetAddress? bindAddress,
  }) async {
    final server = await ServerSocket.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      0,
    );
    final session = DevicePairingLanServer._(server, ticket, onRequest);
    session._subscription = server.listen(session._handle);
    return session;
  }

  void _handle(Socket socket) {
    if (_sockets.length >= 4) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
    unawaited(() async {
      try {
        final packet = await _readPacket(
          socket,
        ).timeout(const Duration(seconds: 10));
        final request = await _open(_ticket, packet);
        final response = await _onRequest(request);
        await _writePacket(socket, await _seal(_ticket, response));
      } catch (_) {
        // A wrong key, malformed or stalled connection learns nothing.
      } finally {
        _sockets.remove(socket);
        try {
          await socket.close();
        } catch (_) {
          socket.destroy();
        }
      }
    }());
  }

  Future<void> close() async {
    await _subscription.cancel();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
    await _server.close();
  }
}

class DevicePairingLanClient {
  static Future<String> exchange(DevicePairingCode code, String request) async {
    Object? lastError;
    final packet = await _seal(code.ticket, request);
    for (final host in code.hosts) {
      Socket? socket;
      try {
        socket = await Socket.connect(
          host,
          code.port,
          timeout: const Duration(seconds: 3),
        );
        await _writePacket(socket, packet);
        final response = await _readPacket(
          socket,
        ).timeout(const Duration(seconds: 12));
        return await _open(code.ticket, response);
      } catch (error) {
        lastError = error;
      } finally {
        socket?.destroy();
      }
    }
    throw StateError('pairing peer unreachable: $lastError');
  }
}
