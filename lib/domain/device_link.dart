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
    this.document,
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

  /// The source's signed identity document, by then naming BOTH devices.
  ///
  /// The counterpart to the document the device-link invite carries, and the
  /// half that was missing. The invite moves the target's document to the
  /// source, so the source learns the device it is about to admit; nothing
  /// moved the other way, so the target finished the ceremony still holding a
  /// document that named only itself. A device that does not know its sibling
  /// publishes a registry of one and can seal nothing to it — the link worked
  /// in one direction and looked complete.
  ///
  /// Carried HERE for the same reason: the ceremony is the one out-of-band
  /// channel a person operates by hand, at the one moment both devices are
  /// trusted, and it is the only way out of the deadlock where the merge that
  /// would let the two reach each other is itself a message between them.
  final Uint8List? document;

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
      'doc': ?_encodedDocument,
    },
  ).toString();

  /// base64url with the padding stripped, matching the device-link invite: both
  /// travel inside strings split on '&' and '=', which standard base64 would be
  /// cut apart by.
  String? get _encodedDocument {
    final doc = document;
    if (doc == null || doc.isEmpty) return null;
    return base64Url.encode(doc).replaceAll('=', '');
  }

  static Uint8List? _decodeDocument(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      return Uint8List.fromList(
        base64Url.decode(raw.padRight((raw.length + 3) ~/ 4 * 4, '=')),
      );
    } on FormatException {
      // A document we cannot read is not a reason to refuse the link: the
      // membership half of the token still stands on its own.
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'gid': groupId.hex,
    'src': source.hex,
    'mh': base64.encode(manifestHash),
    'exp': expiresAtMs,
    'invite': sourceInvite.toUri(),
    'sd': ?sourceDevice?.hex,
    'doc': ?_encodedDocument,
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
        document: _decodeDocument(value['doc']),
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
        document: _decodeDocument(uri.queryParameters['doc']),
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
    Uint8List? document,
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
      document: document,
    );
  }
}
