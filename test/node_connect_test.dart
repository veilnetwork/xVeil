import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/data/node/node_connect.dart';
import 'package:xveil/state/node_connect.dart';

import 'support/fake_setting_storage.dart';

void main() {
  final now = DateTime.utc(2026, 11, 11);
  final token = base64UrlEncode(List.filled(32, 17)).replaceAll('=', '');
  final pin = List.filled(64, 'a').join();
  String invite({Map<String, String> fields = const {}}) => Uri(
    scheme: 'xveil',
    path: 'node',
    queryParameters: {
      'v': '1',
      'endpoint': 'https://node.example:8443',
      'pin': pin,
      'token': token,
      'expires':
          '${now.add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000}',
      ...fields,
    },
  ).toString();

  test('strict invite, endpoint and redacted representation', () {
    final parsed = NodeConnectInvite.parse(invite(), now: now);
    expect(parsed.endpoint.host, 'node.example');
    expect(parsed.endpoint.port, 8443);
    expect(parsed.pin, pin);
    expect(parsed.token, token);
    expect('$parsed', isNot(contains(token)));
    final ipv6 = NodeConnectInvite.parse(
      invite(fields: {'endpoint': 'https://[2001:db8::1]:8443'}),
      now: now,
    );
    expect(ipv6.endpoint.port, 8443);
  });

  for (final endpoint in [
    'http://node.example',
    'https://user:secret@node.example',
    'https://node.example/path',
    'https://node.example?other=1',
    'https://node.example#fragment',
    'https://node.example:0',
    'https://node.example:65536',
    'https://node.example\\@elsewhere',
    'https://node.example\n',
  ]) {
    test('rejects unsafe endpoint ${jsonEncode(endpoint)}', () {
      expect(
        () => NodeConnectInvite.parse(
          invite(fields: {'endpoint': endpoint}),
          now: now,
        ),
        throwsA(isA<NodeConnectException>()),
      );
    });
  }
  test(
    'rejects unknown/duplicate fields, invalid token, version and far future',
    () {
      for (final value in [
        '${invite()}&token=$token',
        '${invite()}&extra=1',
        invite(fields: {'token': List.filled(43, 'a').join()}),
        invite(fields: {'v': '2'}),
        invite(fields: {'pin': pin.toUpperCase()}),
        invite(
          fields: {
            'expires':
                '${now.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000}',
          },
        ),
        invite().replaceFirst('xveil:node', 'veil:node'),
        invite().replaceFirst('xveil:node', 'xveil://node'),
      ]) {
        expect(
          () => NodeConnectInvite.parse(value, now: now),
          throwsA(isA<NodeConnectException>()),
        );
      }
    },
  );
  test('expired invite reports only safe category', () {
    expect(
      () => NodeConnectInvite.parse(
        invite(fields: {'expires': '${now.millisecondsSinceEpoch ~/ 1000}'}),
        now: now,
      ),
      throwsA(
        isA<NodeConnectException>().having(
          (error) => error.failure,
          'failure',
          NodeConnectFailure.expired,
        ),
      ),
    );
    expect(
      '${const NodeConnectException(NodeConnectFailure.expired)}',
      'NodeConnectException(expired)',
    );
  });
  test('secrets live separately in the owning encrypted store', () async {
    final a = FakeSettingStorage(), b = FakeSettingStorage();
    final session = NodeConnectSession(
      endpoint: Uri.parse('https://node.example:8443'),
      pin: pin,
      token: token,
      expires: now,
    );
    final ar = NodeConnectRepository(a), br = NodeConnectRepository(b);
    await ar.save('one', session);
    expect((await ar.load('one'))!.encode(), session.encode());
    expect(await br.load('one'), isNull);
    final node = ManagedNode(
      id: 'one',
      label: 'server',
      connectEndpoint: session.endpoint.toString(),
    );
    expect(node.hasManagement, isTrue);
    expect(
      ManagedNode.decodeList(
        ManagedNode.encodeList([node]),
      ).single.connectEndpoint,
      session.endpoint.toString(),
    );
    expect(ManagedNode.encodeList([node]), isNot(contains(token)));
    expect('$session', isNot(contains(token)));
    expect(
      node.copyWith(label: 'renamed').connectEndpoint,
      node.connectEndpoint,
    );
    await ar.clear('one');
    expect(await ar.load('one'), isNull);
  });
  test('inactive identity refuses to begin network work', () async {
    final client = NodeConnectClient(
      endpoint: Uri.parse('https://node.example'),
      pin: pin,
      isCurrent: () => false,
    );
    addTearDown(client.close);
    await expectLater(
      client.claim(NodeConnectInvite.parse(invite(), now: now)),
      throwsA(
        isA<NodeConnectException>().having(
          (error) => error.failure,
          'failure',
          NodeConnectFailure.identityChanged,
        ),
      ),
    );
  });
}
