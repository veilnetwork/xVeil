import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import '../data/transport/bootstrap_invite.dart';

/// Six digits the person compares on both screens before the source signs a
/// device key. A substituted phone key changes this code.
String devicePairingSafetyCode(String ticket, NodeId device) {
  final digest = crypto.sha256
      .convert(utf8.encode('$ticket:${device.hex}'))
      .bytes;
  final number = ((digest[0] << 16) | (digest[1] << 8) | digest[2]) % 1000000;
  return number.toString().padLeft(6, '0');
}

/// One QR from the existing device. Recovery material and identity snapshots
/// never enter the QR; its random key encrypts a short-lived LAN exchange.
class DevicePairingCode {
  DevicePairingCode({
    required this.device,
    required this.source,
    required this.ticket,
    required this.expiresAt,
    required this.hosts,
    required this.port,
  });

  static const scheme = 'veil:pair?';
  final BootstrapInvite device;
  final BootstrapInvite source;
  NodeId get identity => source.nodeId;
  final String ticket;
  final int expiresAt;
  final List<String> hosts;
  final int port;

  factory DevicePairingCode.fresh(
    BootstrapInvite device,
    BootstrapInvite source, {
    required List<String> hosts,
    required int port,
  }) {
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List.generate(32, (_) => random.nextInt(256)),
    );
    return DevicePairingCode(
      device: device,
      source: source,
      ticket: bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      expiresAt: DateTime.now()
          .add(const Duration(minutes: 10))
          .millisecondsSinceEpoch,
      hosts: List.unmodifiable(hosts),
      port: port,
    );
  }

  bool get expired => DateTime.now().millisecondsSinceEpoch >= expiresAt;

  String toUri() =>
      '$scheme'
      'd=${base64Url.encode(utf8.encode(device.toUri()))}&'
      's=${base64Url.encode(utf8.encode(source.toUri()))}&'
      't=$ticket&e=$expiresAt&p=$port&h=${hosts.join(',')}';

  static DevicePairingCode parse(String text) {
    if (text.length > 2953 || !text.startsWith(scheme)) {
      throw const FormatException('not a device pairing code');
    }
    final params = Uri.parse(text).queryParameters;
    final ticket = params['t'] ?? '';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(ticket)) {
      throw const FormatException('invalid pairing ticket');
    }
    final expiry = int.tryParse(params['e'] ?? '');
    if (expiry == null ||
        expiry < 0 ||
        expiry >
            DateTime.now()
                .add(const Duration(minutes: 11))
                .millisecondsSinceEpoch) {
      throw const FormatException('invalid pairing expiry');
    }
    final port = int.tryParse(params['p'] ?? '');
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('invalid pairing port');
    }
    final hosts = (params['h'] ?? '').split(',');
    if (hosts.isEmpty ||
        hosts.length > 6 ||
        hosts.any((host) => !_privateIpv4(host))) {
      throw const FormatException('invalid pairing hosts');
    }
    final device = BootstrapInvite.parse(
      utf8.decode(base64Url.decode(base64Url.normalize(params['d'] ?? ''))),
    );
    final source = BootstrapInvite.parse(
      utf8.decode(base64Url.decode(base64Url.normalize(params['s'] ?? ''))),
    );
    return DevicePairingCode(
      device: device,
      source: source,
      ticket: ticket,
      expiresAt: expiry,
      hosts: List.unmodifiable(hosts),
      port: port,
    );
  }

  static bool _privateIpv4(String host) {
    if (InternetAddress.tryParse(host)?.type != InternetAddressType.IPv4) {
      return false;
    }
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final a = parts[0]!, b = parts[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }
}
