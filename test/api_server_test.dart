import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/api_server.dart';

// The automation API's auth + routing (pure ApiHandler — no socket).

void main() {
  final sent = <(String, String)>[];
  ApiHandler make({String token = 'secret-token'}) {
    sent.clear();
    return ApiHandler(
      token: token,
      status: () => {'ok': true, 'nodeId': 'abcd'},
      contacts: () async => [
        {'nodeId': 'beef', 'short': 'beef'},
      ],
      send: (to, body) async {
        if (to == 'bad') return 'invalid peer';
        sent.add((to, body));
        return null;
      },
      messages: (peer, limit) async => [
        {'id': 'm1', 'body': 'hi', 'direction': 'incoming'},
      ],
    );
  }

  Uri u(String p) => Uri.parse(p);

  test('every endpoint rejects a missing / wrong / malformed bearer', () async {
    final h = make();
    for (final auth in <String?>[
      null,
      'secret-token', // no "Bearer " prefix
      'Bearer wrong',
      'Bearer secret-toke', // shorter
      'Basic secret-token',
    ]) {
      expect((await h.handle('GET', u('/v1/health'), auth)).status, 401,
          reason: 'auth=$auth must be rejected');
    }
  });

  test('an empty token rejects everything (API not provisioned)', () async {
    final h = make(token: '');
    expect((await h.handle('GET', u('/v1/health'), 'Bearer ')).status, 401);
    expect((await h.handle('GET', u('/v1/health'), null)).status, 401);
  });

  test('GET /v1/health returns node status with a valid token', () async {
    final res =
        await make().handle('GET', u('/v1/health'), 'Bearer secret-token');
    expect(res.status, 200);
    expect((res.body as Map)['ok'], true);
    expect((res.body as Map)['nodeId'], 'abcd');
  });

  test('GET /v1/contacts returns accepted contacts', () async {
    final res =
        await make().handle('GET', u('/v1/contacts'), 'Bearer secret-token');
    expect(res.status, 200);
    final list = (res.body as Map)['contacts'] as List;
    expect(list.single['nodeId'], 'beef');
  });

  test('POST /v1/messages sends; validates to+body; reports send errors',
      () async {
    final h = make();
    // Missing fields → 400.
    expect(
        (await h.handle('POST', u('/v1/messages'), 'Bearer secret-token',
                body: {'to': 'peer'}))
            .status,
        400);
    // Valid → 200 and the send fn saw it.
    final ok = await h.handle('POST', u('/v1/messages'), 'Bearer secret-token',
        body: {'to': 'peer', 'body': 'hello'});
    expect(ok.status, 200);
    expect(sent.single, ('peer', 'hello'));
    // Send-layer error → 400 with the message.
    final err = await h.handle('POST', u('/v1/messages'), 'Bearer secret-token',
        body: {'to': 'bad', 'body': 'x'});
    expect(err.status, 400);
    expect((err.body as Map)['error'], 'invalid peer');
    // Unauthenticated POST is 401, never sends.
    expect((await h.handle('POST', u('/v1/messages'), null,
                body: {'to': 'peer', 'body': 'z'}))
            .status,
        401);
    expect(sent.length, 1, reason: 'the 401 POST must not have sent');
  });

  test('GET /v1/messages requires a peer and returns the log', () async {
    final h = make();
    expect((await h.handle('GET', u('/v1/messages'), 'Bearer secret-token'))
            .status,
        400);
    final res = await h.handle(
        'GET', u('/v1/messages?peer=beef&limit=10'), 'Bearer secret-token');
    expect(res.status, 200);
    expect(((res.body as Map)['messages'] as List).single['id'], 'm1');
  });

  test('an authenticated unknown route is 404, not 401', () async {
    final res =
        await make().handle('GET', u('/v1/nope'), 'Bearer secret-token');
    expect(res.status, 404);
  });

  test('ApiConfig.copyWith + empty defaults', () {
    expect(ApiConfig.empty.enabled, false);
    expect(ApiConfig.empty.token, '');
    final c = ApiConfig.empty.copyWith(enabled: true, token: 't');
    expect(c.enabled, true);
    expect(c.token, 't');
  });
}
