import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';

const Duration kSpaceJoinTicketLifetime = Duration(days: 7);
const Duration kSpaceJoinTicketMaxLifetime = Duration(days: 30);
const Duration kSpaceJoinRequestRetryDelay = Duration(hours: 24);

final RegExp _joinIdPattern = RegExp(r'^[0-9a-f]{64}$');

/// A locally issued bearer ticket embedded in an `xveil://space/v1` link.
///
/// The link grants only the right to ask [approver] for membership. The
/// approver keeps the authoritative ticket row and compares every field, so a
/// modified or revoked link cannot create membership or reveal Space data.
class SpaceJoinTicket {
  const SpaceJoinTicket({
    required this.ticketId,
    required this.spaceId,
    required this.approver,
    required this.spaceName,
    required this.createdAtMs,
    required this.expiresAtMs,
  });

  final String ticketId;
  final NodeId spaceId;
  final NodeId approver;
  final String spaceName;
  final int createdAtMs;
  final int expiresAtMs;

  bool get isStructurallyValid =>
      _joinIdPattern.hasMatch(ticketId) &&
      spaceName == spaceName.trim() &&
      spaceName.isNotEmpty &&
      spaceName.length <= 160 &&
      utf8.encode(spaceName).length <= 512 &&
      createdAtMs >= 0 &&
      expiresAtMs > createdAtMs &&
      expiresAtMs - createdAtMs <= kSpaceJoinTicketMaxLifetime.inMilliseconds;

  bool isExpiredAt(int nowMs) => nowMs >= expiresAtMs;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'id': ticketId,
    'space': spaceId.hex,
    'approver': approver.hex,
    'name': spaceName,
    'createdAt': createdAtMs,
    'expiresAt': expiresAtMs,
  };

  static SpaceJoinTicket? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final id = value['id'];
    final space = value['space'];
    final approver = value['approver'];
    final name = value['name'];
    final createdAt = value['createdAt'];
    final expiresAt = value['expiresAt'];
    if (id is! String ||
        space is! String ||
        approver is! String ||
        name is! String ||
        createdAt is! int ||
        expiresAt is! int) {
      return null;
    }
    try {
      final ticket = SpaceJoinTicket(
        ticketId: id,
        spaceId: NodeId.fromHex(space),
        approver: NodeId.fromHex(approver),
        spaceName: name,
        createdAtMs: createdAt,
        expiresAtMs: expiresAt,
      );
      return ticket.isStructurallyValid ? ticket : null;
    } catch (_) {
      return null;
    }
  }
}

/// Strict fixed-width link codec. The random ticket id is a capability, while
/// the remaining public fields are display/routing hints checked against the
/// issuer's local ticket before a request is accepted.
class SpaceJoinCode {
  static const scheme = 'xveil';
  static const host = 'space';
  static const _path = '/v1';
  static const _fixedBytes = 4 + 32 + 32 + 32 + 8 + 8 + 2;
  static final Uint8List _magic = Uint8List.fromList(const [
    0x58,
    0x56,
    0x4a,
    0x01,
  ]);

  static String encode(SpaceJoinTicket ticket) {
    if (!ticket.isStructurallyValid) {
      throw const FormatException('invalid Space join ticket');
    }
    final name = Uint8List.fromList(utf8.encode(ticket.spaceName));
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..add(_hex32(ticket.ticketId))
      ..add(ticket.spaceId.bytes)
      ..add(ticket.approver.bytes)
      ..add(_u64(ticket.createdAtMs))
      ..add(_u64(ticket.expiresAtMs))
      ..add(_u16(name.length))
      ..add(name);
    final fragment = base64Url.encode(out.toBytes()).replaceAll('=', '');
    return '$scheme://$host$_path#$fragment';
  }

  static SpaceJoinTicket parse(String value) {
    if (value.length > 2048) {
      throw const FormatException('Space join link is too long');
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != scheme ||
        uri.host != host ||
        uri.path != _path ||
        uri.query.isNotEmpty ||
        uri.fragment.isEmpty ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(uri.fragment)) {
      throw const FormatException('invalid Space join link');
    }
    final Uint8List raw;
    try {
      raw = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(uri.fragment)),
      );
    } catch (_) {
      throw const FormatException('invalid Space join link encoding');
    }
    if (raw.length < _fixedBytes ||
        !_sameBytes(Uint8List.sublistView(raw, 0, 4), _magic)) {
      throw const FormatException('invalid Space join link header');
    }
    var offset = 4;
    Uint8List take(int length) {
      if (length < 0 || offset + length > raw.length) {
        throw const FormatException('truncated Space join link');
      }
      final result = Uint8List.fromList(raw.sublist(offset, offset + length));
      offset += length;
      return result;
    }

    final ticketId = _toHex(take(32));
    final spaceId = NodeId(take(32));
    final approver = NodeId(take(32));
    final createdAt = _readU64(take(8));
    final expiresAt = _readU64(take(8));
    final nameLength = ByteData.sublistView(take(2)).getUint16(0, Endian.big);
    if (nameLength > 512 || offset + nameLength != raw.length) {
      throw const FormatException('invalid Space join link length');
    }
    final String name;
    try {
      name = utf8.decode(take(nameLength), allowMalformed: false);
    } catch (_) {
      throw const FormatException('invalid Space join link name');
    }
    final ticket = SpaceJoinTicket(
      ticketId: ticketId,
      spaceId: spaceId,
      approver: approver,
      spaceName: name,
      createdAtMs: createdAt,
      expiresAtMs: expiresAt,
    );
    if (!ticket.isStructurallyValid) {
      throw const FormatException('invalid Space join ticket');
    }
    return ticket;
  }
}

/// Authenticated requester intent. It carries no Space snapshot or metadata
/// beyond the exact ticket routing fields.
class SpaceJoinRequest {
  const SpaceJoinRequest({
    required this.requestId,
    required this.ticketId,
    required this.ticketHash,
    required this.spaceId,
    required this.requester,
    required this.approver,
    required this.createdAtMs,
  });

  final String requestId;
  final String ticketId;
  final String ticketHash;
  final NodeId spaceId;
  final NodeId requester;
  final NodeId approver;
  final int createdAtMs;

  bool get isStructurallyValid =>
      _joinIdPattern.hasMatch(requestId) &&
      _joinIdPattern.hasMatch(ticketId) &&
      _joinIdPattern.hasMatch(ticketHash) &&
      requester != approver &&
      createdAtMs >= 0;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'id': requestId,
    'ticket': ticketId,
    'ticketHash': ticketHash,
    'space': spaceId.hex,
    'requester': requester.hex,
    'approver': approver.hex,
    'createdAt': createdAtMs,
  };

  static SpaceJoinRequest? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final id = value['id'];
    final ticket = value['ticket'];
    final ticketHash = value['ticketHash'];
    final space = value['space'];
    final requester = value['requester'];
    final approver = value['approver'];
    final createdAt = value['createdAt'];
    if (id is! String ||
        ticket is! String ||
        ticketHash is! String ||
        space is! String ||
        requester is! String ||
        approver is! String ||
        createdAt is! int) {
      return null;
    }
    try {
      final request = SpaceJoinRequest(
        requestId: id,
        ticketId: ticket,
        ticketHash: ticketHash,
        spaceId: NodeId.fromHex(space),
        requester: NodeId.fromHex(requester),
        approver: NodeId.fromHex(approver),
        createdAtMs: createdAt,
      );
      return request.isStructurallyValid ? request : null;
    } catch (_) {
      return null;
    }
  }
}

/// The approver's response. Acceptance remains non-authoritative: only a
/// verified signed `addMember` row in the subsequent snapshot grants access.
class SpaceJoinDecision {
  const SpaceJoinDecision({
    required this.requestId,
    required this.spaceId,
    required this.accepted,
    required this.decidedAtMs,
  });

  final String requestId;
  final NodeId spaceId;
  final bool accepted;
  final int decidedAtMs;

  bool get isStructurallyValid =>
      _joinIdPattern.hasMatch(requestId) && decidedAtMs >= 0;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'id': requestId,
    'space': spaceId.hex,
    'accepted': accepted,
    'decidedAt': decidedAtMs,
  };

  static SpaceJoinDecision? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final id = value['id'];
    final space = value['space'];
    final accepted = value['accepted'];
    final decidedAt = value['decidedAt'];
    if (id is! String ||
        space is! String ||
        accepted is! bool ||
        decidedAt is! int) {
      return null;
    }
    try {
      final decision = SpaceJoinDecision(
        requestId: id,
        spaceId: NodeId.fromHex(space),
        accepted: accepted,
        decidedAtMs: decidedAt,
      );
      return decision.isStructurallyValid ? decision : null;
    } catch (_) {
      return null;
    }
  }
}

class SpaceJoinInboxEntry {
  const SpaceJoinInboxEntry({
    required this.request,
    required this.receivedAtMs,
    this.decision,
  });

  final SpaceJoinRequest request;
  final int receivedAtMs;
  final SpaceJoinDecision? decision;

  bool get pending => decision == null;

  bool get isStructurallyValid =>
      request.isStructurallyValid &&
      receivedAtMs >= request.createdAtMs &&
      (decision == null ||
          (decision!.isStructurallyValid &&
              decision!.requestId == request.requestId &&
              decision!.spaceId == request.spaceId &&
              decision!.decidedAtMs >= receivedAtMs));

  Map<String, dynamic> toJson() => {
    'request': request.toJson(),
    'receivedAt': receivedAtMs,
    if (decision != null) 'decision': decision!.toJson(),
  };

  static SpaceJoinInboxEntry? fromJson(Object? value) {
    if (value is! Map || value['receivedAt'] is! int) return null;
    final request = SpaceJoinRequest.fromJson(value['request']);
    final decision = value['decision'] == null
        ? null
        : SpaceJoinDecision.fromJson(value['decision']);
    if (request == null || (value['decision'] != null && decision == null)) {
      return null;
    }
    final entry = SpaceJoinInboxEntry(
      request: request,
      receivedAtMs: value['receivedAt'] as int,
      decision: decision,
    );
    return entry.isStructurallyValid ? entry : null;
  }
}

class SpaceJoinOutboxEntry {
  const SpaceJoinOutboxEntry({
    required this.ticket,
    required this.request,
    this.decision,
  });

  final SpaceJoinTicket ticket;
  final SpaceJoinRequest request;
  final SpaceJoinDecision? decision;

  bool get approved => decision?.accepted == true;
  bool get declined => decision?.accepted == false;

  bool get isStructurallyValid =>
      ticket.isStructurallyValid &&
      request.isStructurallyValid &&
      request.ticketId == ticket.ticketId &&
      request.ticketHash == spaceJoinTicketHash(ticket) &&
      request.spaceId == ticket.spaceId &&
      request.approver == ticket.approver &&
      request.createdAtMs >= ticket.createdAtMs &&
      request.createdAtMs < ticket.expiresAtMs &&
      (decision == null ||
          (decision!.isStructurallyValid &&
              decision!.requestId == request.requestId &&
              decision!.spaceId == request.spaceId &&
              decision!.decidedAtMs >= request.createdAtMs));

  Map<String, dynamic> toJson() => {
    'ticket': ticket.toJson(),
    'request': request.toJson(),
    if (decision != null) 'decision': decision!.toJson(),
  };

  static SpaceJoinOutboxEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final ticket = SpaceJoinTicket.fromJson(value['ticket']);
    final request = SpaceJoinRequest.fromJson(value['request']);
    final decision = value['decision'] == null
        ? null
        : SpaceJoinDecision.fromJson(value['decision']);
    if (ticket == null ||
        request == null ||
        (value['decision'] != null && decision == null)) {
      return null;
    }
    final entry = SpaceJoinOutboxEntry(
      ticket: ticket,
      request: request,
      decision: decision,
    );
    return entry.isStructurallyValid ? entry : null;
  }
}

String spaceJoinTicketHash(SpaceJoinTicket ticket) =>
    crypto.sha256.convert(utf8.encode(SpaceJoinCode.encode(ticket))).toString();

Uint8List _hex32(String value) {
  if (!_joinIdPattern.hasMatch(value)) {
    throw const FormatException('invalid 32-byte hex value');
  }
  return Uint8List.fromList([
    for (var i = 0; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ]);
}

String _toHex(List<int> value) =>
    value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List _u16(int value) {
  final out = Uint8List(2);
  ByteData.sublistView(out).setUint16(0, value, Endian.big);
  return out;
}

Uint8List _u64(int value) {
  if (value < 0) throw const FormatException('negative timestamp');
  final out = Uint8List(8);
  ByteData.sublistView(out).setUint64(0, value, Endian.big);
  return out;
}

int _readU64(Uint8List value) {
  final decoded = ByteData.sublistView(value).getUint64(0, Endian.big);
  if (decoded > 0x7fffffffffffffff) {
    throw const FormatException('timestamp overflow');
  }
  return decoded;
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var diff = 0;
  for (var i = 0; i < left.length; i++) {
    diff |= left[i] ^ right[i];
  }
  return diff == 0;
}
