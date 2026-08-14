import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import '../data/transport/bootstrap_invite.dart';

/// Do two identifiers name THE SAME DEVICE?
///
/// Asked at both points of the device-link ceremony -- the invite check and the
/// adoption guard -- and answered here so the two cannot drift.
///
/// The identifiers are DEVICE node ids: the hash of a device's own transport
/// key, which differs between two devices of one identity where the identity
/// address cannot. Comparing identity addresses is what made a sibling read as
/// self, refusing linking first as "self device" and then as "admission
/// rejected".
///
/// A null on either side means the other end is on a build that did not carry
/// its device id. The fallback compares what is there, which for two devices of
/// one identity means "self" and a refusal: conservative on purpose, since the
/// alternative is admitting a device on an identifier that cannot tell it from
/// this one.
bool isSameDevice({
  required NodeId? theirDevice,
  required NodeId? myDevice,
  required NodeId theirIdentity,
  required NodeId myIdentity,
}) => (theirDevice != null && myDevice != null)
    ? theirDevice == myDevice
    : theirIdentity == myIdentity;

NodeId? _optionalNodeId(String? hex) =>
    (hex == null || hex.isEmpty) ? null : NodeId.fromHex(hex);

/// Short, public QR token that authorizes one explicit device-group adoption.
/// The encrypted sovereign bundle itself is NOT in the QR: it travels in the
/// durable group snapshot and is pinned by [manifestHash].
class DeviceLinkToken {
  DeviceLinkToken({
    required this.groupId,
    required this.source,
    required this.manifestHash,
    required this.sourceInvite,
    required this.expiresAtMs,
    this.sourceDevice,
  });

  final NodeId groupId;
  final NodeId source;
  final Uint8List manifestHash;
  final BootstrapInvite sourceInvite;
  final int expiresAtMs;

  /// Which DEVICE of the source identity issued this -- its own transport node
  /// id. Null from a build that predates the field; [isSameDevice] falls back
  /// to identity ids then.
  final NodeId? sourceDevice;

  static const _scheme = 'veil';
  static const _path = 'xveil-device';
  static const _maxChars = 8 * 1024;

  bool isExpired(int nowMs) => expiresAtMs <= nowMs;

  String toUri() => Uri(
    scheme: _scheme,
    path: _path,
    queryParameters: {
      'v': '1',
      'gid': groupId.hex,
      'src': source.hex,
      'mh': base64Url.encode(manifestHash).replaceAll('=', ''),
      'exp': '$expiresAtMs',
      'invite': sourceInvite.toUri(),
      'sd': ?sourceDevice?.hex,
    },
  ).toString();

  Map<String, dynamic> toJson() => {
    'v': 1,
    'gid': groupId.hex,
    'src': source.hex,
    'mh': base64.encode(manifestHash),
    'exp': expiresAtMs,
    'invite': sourceInvite.toUri(),
    'sd': ?sourceDevice?.hex,
  };

  static DeviceLinkToken? fromJson(Object? value) {
    if (value is! Map) return null;
    try {
      if (value['v'] != 1 ||
          value['gid'] is! String ||
          value['src'] is! String ||
          value['mh'] is! String ||
          value['exp'] is! int ||
          value['invite'] is! String) {
        return null;
      }
      return _validated(
        groupId: NodeId.fromHex(value['gid'] as String),
        source: NodeId.fromHex(value['src'] as String),
        manifestHash: Uint8List.fromList(base64.decode(value['mh'] as String)),
        sourceInvite: BootstrapInvite.parse(value['invite'] as String),
        expiresAtMs: value['exp'] as int,
        sourceDevice: value['sd'] is String
            ? NodeId.fromHex(value['sd'] as String)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  static DeviceLinkToken parse(String raw) {
    final text = raw.trim();
    if (text.length > _maxChars) {
      throw const FormatException('device-link token too large');
    }
    final uri = Uri.parse(text);
    if (uri.scheme != _scheme ||
        uri.path != _path ||
        uri.queryParameters['v'] != '1') {
      throw const FormatException('not an xVeil device-link token');
    }
    try {
      final gid = uri.queryParameters['gid'];
      final src = uri.queryParameters['src'];
      final mh = uri.queryParameters['mh'];
      final exp = int.tryParse(uri.queryParameters['exp'] ?? '');
      final invite = uri.queryParameters['invite'];
      if (gid == null ||
          src == null ||
          mh == null ||
          exp == null ||
          invite == null) {
        throw const FormatException('device-link token missing fields');
      }
      final padded = mh.padRight((mh.length + 3) ~/ 4 * 4, '=');
      return _validated(
        groupId: NodeId.fromHex(gid),
        source: NodeId.fromHex(src),
        manifestHash: Uint8List.fromList(base64Url.decode(padded)),
        sourceInvite: BootstrapInvite.parse(invite),
        expiresAtMs: exp,
        sourceDevice: _optionalNodeId(uri.queryParameters['sd']),
      );
    } catch (e) {
      if (e is FormatException) rethrow;
      throw const FormatException('invalid xVeil device-link token');
    }
  }

  static DeviceLinkToken _validated({
    required NodeId groupId,
    required NodeId source,
    required Uint8List manifestHash,
    required BootstrapInvite sourceInvite,
    required int expiresAtMs,
    NodeId? sourceDevice,
  }) {
    if (manifestHash.length != 32 ||
        sourceInvite.nodeId != source ||
        expiresAtMs <= 0) {
      throw const FormatException('invalid xVeil device-link binding');
    }
    return DeviceLinkToken(
      groupId: groupId,
      source: source,
      manifestHash: manifestHash,
      sourceInvite: sourceInvite,
      expiresAtMs: expiresAtMs,
      sourceDevice: sourceDevice,
    );
  }
}
