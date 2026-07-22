import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/space_join_request.dart';

NodeId _id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

void main() {
  final ticket = SpaceJoinTicket(
    ticketId: 'ab' * 32,
    spaceId: _id(1),
    approver: _id(2),
    spaceName: 'Public laboratory',
    createdAtMs: 1000,
    expiresAtMs: 1000 + kSpaceJoinTicketLifetime.inMilliseconds,
  );

  test('strict Space join link round-trips public routing hints', () {
    final link = SpaceJoinCode.encode(ticket);
    expect(link, startsWith('xveil://space/v1#'));
    expect(link, isNot(contains(ticket.spaceName)));
    final parsed = SpaceJoinCode.parse(link);
    expect(parsed.toJson(), ticket.toJson());
  });

  test('Space join link rejects tamper, truncation and hostile names', () {
    final link = SpaceJoinCode.encode(ticket);
    final uri = Uri.parse(link);
    final raw = Uint8List.fromList(
      base64Url.decode(base64Url.normalize(uri.fragment)),
    );
    raw[0] ^= 1;
    final tampered =
        'xveil://space/v1#${base64Url.encode(raw).replaceAll('=', '')}';
    expect(() => SpaceJoinCode.parse(tampered), throwsFormatException);
    expect(
      () => SpaceJoinCode.parse('xveil://space/v1#AAAA'),
      throwsFormatException,
    );
    expect(
      () => SpaceJoinCode.parse('https://space/v1#${uri.fragment}'),
      throwsFormatException,
    );

    final oversized = SpaceJoinTicket(
      ticketId: ticket.ticketId,
      spaceId: ticket.spaceId,
      approver: ticket.approver,
      spaceName: 'x' * 161,
      createdAtMs: ticket.createdAtMs,
      expiresAtMs: ticket.expiresAtMs,
    );
    expect(() => SpaceJoinCode.encode(oversized), throwsFormatException);
  });

  test('request, decision and durable inbox/outbox rows are strict', () {
    final request = SpaceJoinRequest(
      requestId: 'cd' * 32,
      ticketId: ticket.ticketId,
      ticketHash: spaceJoinTicketHash(ticket),
      spaceId: ticket.spaceId,
      requester: _id(3),
      approver: ticket.approver,
      createdAtMs: 2000,
    );
    final decision = SpaceJoinDecision(
      requestId: request.requestId,
      spaceId: request.spaceId,
      accepted: true,
      decidedAtMs: 3000,
    );
    final inbox = SpaceJoinInboxEntry(
      request: request,
      receivedAtMs: 2100,
      decision: decision,
    );
    final outbox = SpaceJoinOutboxEntry(
      ticket: ticket,
      request: request,
      decision: decision,
    );
    expect(
      SpaceJoinRequest.fromJson(request.toJson())?.toJson(),
      request.toJson(),
    );
    expect(
      SpaceJoinDecision.fromJson(decision.toJson())?.toJson(),
      decision.toJson(),
    );
    expect(
      SpaceJoinInboxEntry.fromJson(inbox.toJson())?.isStructurallyValid,
      isTrue,
    );
    expect(SpaceJoinOutboxEntry.fromJson(outbox.toJson())?.approved, isTrue);

    final wrong = Map<String, dynamic>.from(request.toJson())
      ..['approver'] = request.requester.hex;
    expect(SpaceJoinRequest.fromJson(wrong), isNull);
    final mismatched = Map<String, dynamic>.from(outbox.toJson())
      ..['decision'] = {...decision.toJson(), 'space': _id(9).hex};
    expect(SpaceJoinOutboxEntry.fromJson(mismatched), isNull);
  });
}
