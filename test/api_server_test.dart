import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/api_server.dart';

// The automation API's auth + routing (pure ApiHandler — no socket).

void main() {
  ApiHandler make({String token = 'secret-token'}) => ApiHandler(
        token: token,
        status: () => {'ok': true, 'nodeId': 'abcd'},
        contacts: () async => [
          {'nodeId': 'beef', 'short': 'beef'},
        ],
      );

  test('every endpoint rejects a missing / wrong / malformed bearer', () async {
    final h = make();
    for (final auth in <String?>[
      null,
      'secret-token', // no "Bearer " prefix
      'Bearer wrong',
      'Bearer secret-toke', // shorter
      'Basic secret-token',
    ]) {
      expect((await h.handle('GET', '/v1/health', auth)).status, 401,
          reason: 'auth=$auth must be rejected');
    }
  });

  test('an empty token rejects everything (API not provisioned)', () async {
    final h = make(token: '');
    expect((await h.handle('GET', '/v1/health', 'Bearer ')).status, 401);
    expect((await h.handle('GET', '/v1/health', null)).status, 401);
  });

  test('GET /v1/health returns node status with a valid token', () async {
    final res = await make().handle('GET', '/v1/health', 'Bearer secret-token');
    expect(res.status, 200);
    expect((res.body as Map)['ok'], true);
    expect((res.body as Map)['nodeId'], 'abcd');
  });

  test('GET /v1/contacts returns accepted contacts', () async {
    final res =
        await make().handle('GET', '/v1/contacts', 'Bearer secret-token');
    expect(res.status, 200);
    final list = (res.body as Map)['contacts'] as List;
    expect(list.single['nodeId'], 'beef');
  });

  test('an authenticated unknown route is 404, not 401', () async {
    final res = await make().handle('GET', '/v1/nope', 'Bearer secret-token');
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
