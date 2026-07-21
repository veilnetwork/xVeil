import 'dart:async';
import 'dart:io';

/// Verifies that the local veil SOCKS listener can reach the clearnet through
/// the configured exit before a system-wide default route is installed.
///
/// A listener-only probe is insufficient: veil can bind SOCKS successfully
/// while its configured exit is offline. The CONNECT request deliberately
/// opens no HTTP/TLS session and sends no application payload.
final class Socks5TransportPreflight {
  static const _targetAddress = <int>[1, 1, 1, 1];
  static const _targetPort = 443;
  static const _timeout = Duration(seconds: 8);

  static Future<void> verify(String listen) async {
    final separator = listen.lastIndexOf(':');
    if (separator <= 0 || separator == listen.length - 1) {
      throw const Socks5TransportException('invalid local SOCKS5 address');
    }
    var host = listen.substring(0, separator);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    final port = int.tryParse(listen.substring(separator + 1));
    if (port == null || port < 1 || port > 65535) {
      throw const Socks5TransportException('invalid local SOCKS5 port');
    }

    Socket? socket;
    StreamIterator<List<int>>? input;
    try {
      socket = await Socket.connect(host, port, timeout: _timeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      input = StreamIterator<List<int>>(socket);

      socket.add(const [0x05, 0x01, 0x00]);
      await socket.flush();
      final greeting = await _readAtLeast(input, 2);
      if (greeting[0] != 0x05 || greeting[1] != 0x00) {
        throw const Socks5TransportException(
          'local SOCKS5 listener rejected unauthenticated access',
        );
      }

      socket.add(const [
        0x05, // SOCKS5
        0x01, // CONNECT
        0x00, // reserved
        0x01, // IPv4 target
        ..._targetAddress,
        _targetPort >> 8,
        _targetPort & 0xff,
      ]);
      await socket.flush();
      final response = await _readAtLeast(input, 2);
      if (response[0] != 0x05 || response[1] != 0x00) {
        throw Socks5TransportException(
          'configured exit rejected the connectivity check '
          '(SOCKS5 reply ${response[1]})',
        );
      }
    } on Socks5TransportException {
      rethrow;
    } on TimeoutException {
      throw const Socks5TransportException(
        'timed out reaching the configured exit',
      );
    } on SocketException catch (error) {
      throw Socks5TransportException(
        'could not reach the configured exit: ${error.message}',
      );
    } finally {
      await input?.cancel();
      await socket?.close();
    }
  }

  static Future<List<int>> _readAtLeast(
    StreamIterator<List<int>> input,
    int count,
  ) async {
    final bytes = <int>[];
    while (bytes.length < count) {
      final available = await input.moveNext().timeout(_timeout);
      if (!available) {
        throw const Socks5TransportException(
          'local SOCKS5 listener closed the connectivity check',
        );
      }
      bytes.addAll(input.current);
    }
    return bytes;
  }
}

final class Socks5TransportException implements Exception {
  const Socks5TransportException(this.message);

  final String message;

  @override
  String toString() => message;
}
