import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/api_server.dart';

// The automation API's auth + routing (pure ApiHandler — no socket).

void main() {
  final sent = <(String, String)>[];
  final groupPosts = <(String, String, String?)>[];
  Map<String, dynamic>? _call;
  ApiHandler make({
    String token = 'secret-token',
    bool readOnly = false,
    bool callsAvailable = true,
  }) {
    sent.clear();
    groupPosts.clear();
    return ApiHandler(
      tokens: token.isEmpty
          ? const []
          : [
              ApiToken(
                id: 't1',
                name: 'test',
                token: token,
                readOnly: readOnly,
              ),
            ],
      status: () => {'ok': true, 'nodeId': 'abcd'},
      contacts: () async => [
        {'nodeId': 'beef', 'short': 'beef'},
      ],
      requestContact: (target, greeting) async {
        if (target == 'bad') return 'invalid target';
        sent.add((target, greeting));
        return null;
      },
      contactAction: (peer, action) async {
        if (peer == 'bad') return 'invalid peer';
        sent.add((peer, action));
        return null;
      },
      send: (to, body) async {
        if (to == 'bad') return 'invalid peer';
        sent.add((to, body));
        return null;
      },
      messages: (peer, limit) async => [
        {'id': 'm1', 'body': 'hi', 'direction': 'incoming'},
      ],
      sendFile: (to, path, name) async => to == 'bad' ? 'invalid peer' : null,
      loadFile: (fileId) async => fileId == 'known' ? [1, 2, 3] : null,
      placeCall: (to, media) async => to == 'bad' ? 'invalid peer' : null,
      callState: () => _call,
      callAction: (action) async => _call = null,
      callsAvailable: callsAvailable,
      groups: () async => [
        {
          'groupId': 'aa',
          'name': 'Family',
          'unread': 2,
          'muted': false,
          'preview': 'hello',
          'lastTs': 123,
        },
      ],
      createGroup: (name) async => name == 'bad' ? null : 'new-group',
      groupMessages: (group, limit) async => group == 'missing'
          ? null
          : [
              {
                'id': '${'ab' * 32}:1',
                'author': 'author',
                'body': 'group hi',
                'sentAt': 123,
              },
            ],
      sendGroupMessage: (group, body, replyTo) async {
        if (group == 'bad') return 'invalid group';
        groupPosts.add((group, body, replyTo));
        return null;
      },
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
      expect(
        (await h.handle('GET', u('/v1/health'), auth)).status,
        401,
        reason: 'auth=$auth must be rejected',
      );
    }
  });

  test(
    'multiple tokens: each authenticates, per-token scope applies',
    () async {
      final h = ApiHandler(
        tokens: const [
          ApiToken(id: 'a', name: 'full', token: 'tok-full', readOnly: false),
          ApiToken(id: 'b', name: 'mon', token: 'tok-ro', readOnly: true),
        ],
        status: () => {'ok': true},
        contacts: () async => const [],
        send: (to, body) async => null,
        messages: (peer, limit) async => const [],
        sendFile: (to, path, name) async => null,
        loadFile: (fileId) async => null,
        placeCall: (to, media) async => null,
        callState: () => null,
        callAction: (action) async {},
        groups: () async => const [],
        createGroup: (_) async => 'gid',
        groupMessages: (_, _) async => const [],
        sendGroupMessage: (_, _, _) async => null,
      );
      // An unknown token → 401.
      expect(
        (await h.handle('GET', u('/v1/health'), 'Bearer nope')).status,
        401,
      );
      // The full token can write.
      expect(
        (await h.handle(
          'POST',
          u('/v1/messages'),
          'Bearer tok-full',
          body: {'to': 'p', 'body': 'x'},
        )).status,
        200,
      );
      // The read-only token reads but its POST is 403.
      expect(
        (await h.handle('GET', u('/v1/health'), 'Bearer tok-ro')).status,
        200,
      );
      expect(
        (await h.handle(
          'POST',
          u('/v1/messages'),
          'Bearer tok-ro',
          body: {'to': 'p', 'body': 'x'},
        )).status,
        403,
      );
    },
  );

  test(
    'a read-only token allows reads but refuses every write with 403',
    () async {
      final h = make(readOnly: true);
      // Reads still work.
      expect(
        (await h.handle('GET', u('/v1/health'), 'Bearer secret-token')).status,
        200,
      );
      // Every write is 403 (not 200, not 401 — the token is valid but scoped).
      for (final w in <(String, Map<String, dynamic>)>[
        ('/v1/messages', {'to': 'p', 'body': 'x'}),
        ('/v1/files', {'to': 'p', 'path': '/x'}),
        ('/v1/calls', {'to': 'p'}),
        ('/v1/calls/hangup', {}),
        ('/v1/groups', {'name': 'G'}),
        ('/v1/groups/messages', {'group': 'g', 'body': 'x'}),
      ]) {
        final res = await h.handle(
          'POST',
          u(w.$1),
          'Bearer secret-token',
          body: w.$2,
        );
        expect(res.status, 403, reason: '${w.$1} must be read-only-refused');
      }
    },
  );

  test('an empty token rejects everything (API not provisioned)', () async {
    final h = make(token: '');
    expect((await h.handle('GET', u('/v1/health'), 'Bearer ')).status, 401);
    expect((await h.handle('GET', u('/v1/health'), null)).status, 401);
  });

  test('GET /v1/health returns node status with a valid token', () async {
    final res = await make().handle(
      'GET',
      u('/v1/health'),
      'Bearer secret-token',
    );
    expect(res.status, 200);
    expect((res.body as Map)['ok'], true);
    expect((res.body as Map)['nodeId'], 'abcd');
  });

  test('GET /v1/contacts returns accepted contacts', () async {
    final res = await make().handle(
      'GET',
      u('/v1/contacts'),
      'Bearer secret-token',
    );
    expect(res.status, 200);
    final list = (res.body as Map)['contacts'] as List;
    expect(list.single['nodeId'], 'beef');
  });

  test('contact request/accept/block routes validate and dispatch', () async {
    final h = make();
    expect(
      (await h.handle(
        'POST',
        u('/v1/contacts'),
        'Bearer secret-token',
        body: {'greeting': 'hi'},
      )).status,
      400,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/contacts'),
        'Bearer secret-token',
        body: {'target': 'peer', 'greeting': 'hi'},
      )).status,
      200,
    );
    expect(sent.single, ('peer', 'hi'));
    expect(
      (await h.handle(
        'POST',
        u('/v1/contacts/accept'),
        'Bearer secret-token',
        body: {'peer': 'peer'},
      )).status,
      200,
    );
    expect(sent.last, ('peer', 'accept'));
    expect(
      (await h.handle(
        'POST',
        u('/v1/contacts/block'),
        'Bearer secret-token',
        body: {'peer': 'peer'},
      )).status,
      200,
    );
    expect(sent.last, ('peer', 'block'));
  });

  test(
    'POST /v1/messages sends; validates to+body; reports send errors',
    () async {
      final h = make();
      // Missing fields → 400.
      expect(
        (await h.handle(
          'POST',
          u('/v1/messages'),
          'Bearer secret-token',
          body: {'to': 'peer'},
        )).status,
        400,
      );
      // Valid → 200 and the send fn saw it.
      final ok = await h.handle(
        'POST',
        u('/v1/messages'),
        'Bearer secret-token',
        body: {'to': 'peer', 'body': 'hello'},
      );
      expect(ok.status, 200);
      expect(sent.single, ('peer', 'hello'));
      // Send-layer error → 400 with the message.
      final err = await h.handle(
        'POST',
        u('/v1/messages'),
        'Bearer secret-token',
        body: {'to': 'bad', 'body': 'x'},
      );
      expect(err.status, 400);
      expect((err.body as Map)['error'], 'invalid peer');
      // Unauthenticated POST is 401, never sends.
      expect(
        (await h.handle(
          'POST',
          u('/v1/messages'),
          null,
          body: {'to': 'peer', 'body': 'z'},
        )).status,
        401,
      );
      expect(sent.length, 1, reason: 'the 401 POST must not have sent');
    },
  );

  test('GET /v1/messages requires a peer and returns the log', () async {
    final h = make();
    expect(
      (await h.handle('GET', u('/v1/messages'), 'Bearer secret-token')).status,
      400,
    );
    final res = await h.handle(
      'GET',
      u('/v1/messages?peer=beef&limit=10'),
      'Bearer secret-token',
    );
    expect(res.status, 200);
    expect(((res.body as Map)['messages'] as List).single['id'], 'm1');
  });

  test('groups: list/create/read/post validate and dispatch', () async {
    final h = make();
    final listed = await h.handle(
      'GET',
      u('/v1/groups'),
      'Bearer secret-token',
    );
    expect(listed.status, 200);
    expect(((listed.body as Map)['groups'] as List).single['name'], 'Family');

    for (final name in ['', '   ', 'x' * 65]) {
      expect(
        (await h.handle(
          'POST',
          u('/v1/groups'),
          'Bearer secret-token',
          body: {'name': name},
        )).status,
        400,
      );
    }
    final created = await h.handle(
      'POST',
      u('/v1/groups'),
      'Bearer secret-token',
      body: {'name': '  Bots  '},
    );
    expect(created.status, 200);
    expect((created.body as Map)['groupId'], 'new-group');
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups'),
        'Bearer secret-token',
        body: {'name': 'bad'},
      )).status,
      400,
    );

    expect(
      (await h.handle(
        'GET',
        u('/v1/groups/messages'),
        'Bearer secret-token',
      )).status,
      400,
    );
    final messages = await h.handle(
      'GET',
      u('/v1/groups/messages?group=aa&limit=10'),
      'Bearer secret-token',
    );
    expect(messages.status, 200);
    expect(
      ((messages.body as Map)['messages'] as List).single['id'],
      '${'ab' * 32}:1',
    );
    expect(
      (await h.handle(
        'GET',
        u('/v1/groups/messages?group=missing'),
        'Bearer secret-token',
      )).status,
      404,
    );

    expect(
      (await h.handle(
        'POST',
        u('/v1/groups/messages'),
        'Bearer secret-token',
        body: {'group': 'aa'},
      )).status,
      400,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups/messages'),
        'Bearer secret-token',
        body: {'group': 'aa', 'body': 'я' * (300 * 1024)},
      )).status,
      413,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups/messages'),
        'Bearer secret-token',
        body: {'group': 'aa', 'body': 'x', 'replyTo': 'not-a-ref'},
      )).status,
      400,
    );
    final posted = await h.handle(
      'POST',
      u('/v1/groups/messages'),
      'Bearer secret-token',
      body: {'group': 'aa', 'body': 'hello bot', 'replyTo': '${'ab' * 32}:1'},
    );
    expect(posted.status, 200);
    expect(groupPosts.single, ('aa', 'hello bot', '${'ab' * 32}:1'));
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups/messages'),
        'Bearer secret-token',
        body: {'group': 'bad', 'body': 'x'},
      )).status,
      400,
    );
  });

  test('a host without group core reports every group route as 501', () async {
    final base = make();
    final h = ApiHandler(
      tokens: base.tokens,
      status: base.status,
      contacts: base.contacts,
      send: base.send,
      messages: base.messages,
      sendFile: base.sendFile,
      loadFile: base.loadFile,
      placeCall: base.placeCall,
      callState: base.callState,
      callAction: base.callAction,
      groups: base.groups,
      createGroup: base.createGroup,
      groupMessages: base.groupMessages,
      sendGroupMessage: base.sendGroupMessage,
      groupsAvailable: false,
    );
    expect(
      (await h.handle('GET', u('/v1/groups'), 'Bearer secret-token')).status,
      501,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/groups/messages'),
        'Bearer secret-token',
        body: {'group': 'g', 'body': 'x'},
      )).status,
      501,
    );
  });

  test('POST /v1/files validates to+path; reports send errors', () async {
    final h = make();
    expect(
      (await h.handle(
        'POST',
        u('/v1/files'),
        'Bearer secret-token',
        body: {'to': 'peer'},
      )).status,
      400,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/files'),
        'Bearer secret-token',
        body: {'to': 'peer', 'path': '/tmp/x'},
      )).status,
      200,
    );
    final err = await h.handle(
      'POST',
      u('/v1/files'),
      'Bearer secret-token',
      body: {'to': 'bad', 'path': '/tmp/x'},
    );
    expect(err.status, 400);
    expect((err.body as Map)['error'], 'invalid peer');
    expect(
      (await h.handle(
        'POST',
        u('/v1/files'),
        null,
        body: {'to': 'peer', 'path': '/tmp/x'},
      )).status,
      401,
    );
  });

  test(
    'GET /v1/files/download returns bytes for a known id, 404 otherwise',
    () async {
      final h = make();
      expect(
        (await h.handle(
          'GET',
          u('/v1/files/download'),
          'Bearer secret-token',
        )).status,
        400,
      ); // no fileId
      final miss = await h.handle(
        'GET',
        u('/v1/files/download?fileId=nope'),
        'Bearer secret-token',
      );
      expect(miss.status, 404);
      final hit = await h.handle(
        'GET',
        u('/v1/files/download?fileId=known'),
        'Bearer secret-token',
      );
      expect(hit.status, 200);
      expect(hit.bytes, [1, 2, 3]);
      expect(hit.contentType, 'application/octet-stream');
    },
  );

  test(
    'calls: place validates to; GET reflects state; actions clear it',
    () async {
      _call = null;
      final h = make();
      // POST place requires `to`.
      expect(
        (await h.handle(
          'POST',
          u('/v1/calls'),
          'Bearer secret-token',
          body: <String, dynamic>{},
        )).status,
        400,
      );
      // A bad peer surfaces the placeCall error.
      final bad = await h.handle(
        'POST',
        u('/v1/calls'),
        'Bearer secret-token',
        body: {'to': 'bad'},
      );
      expect(bad.status, 400);
      // Place ok → 200 with the (test) call state.
      _call = {'callId': 'c1', 'status': 'ringing'};
      final placed = await h.handle(
        'POST',
        u('/v1/calls'),
        'Bearer secret-token',
        body: {'to': 'peer', 'media': 'audio'},
      );
      expect(placed.status, 200);
      expect(((placed.body as Map)['call'] as Map)['callId'], 'c1');
      // GET reflects the current call.
      expect(
        ((await h.handle('GET', u('/v1/calls'), 'Bearer secret-token')).body
            as Map)['call'],
        isNotNull,
      );
      // Hangup clears it (the fake action nulls _call).
      final hung = await h.handle(
        'POST',
        u('/v1/calls/hangup'),
        'Bearer secret-token',
      );
      expect(hung.status, 200);
      expect((hung.body as Map)['call'], isNull);
      // Auth still enforced.
      expect((await h.handle('GET', u('/v1/calls'), null)).status, 401);
    },
  );

  test('a host without a media engine reports call routes as 501', () async {
    final h = make(callsAvailable: false);
    expect(
      (await h.handle('GET', u('/v1/calls'), 'Bearer secret-token')).status,
      501,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/calls'),
        'Bearer secret-token',
        body: {'to': 'peer'},
      )).status,
      501,
    );
    expect(
      (await h.handle(
        'POST',
        u('/v1/calls/hangup'),
        'Bearer secret-token',
      )).status,
      501,
    );
  });

  test(
    'GET /v1/openapi.json returns a valid OpenAPI 3 doc with every path',
    () async {
      final res = await make().handle(
        'GET',
        u('/v1/openapi.json'),
        'Bearer secret-token',
      );
      expect(res.status, 200);
      final spec = res.body as Map<String, dynamic>;
      expect(spec['openapi'], startsWith('3.'));
      expect((spec['info'] as Map)['title'], isNotEmpty);
      final paths = (spec['paths'] as Map).keys.toSet();
      // Every implemented endpoint is documented (WS /events lives in the info).
      expect(
        paths,
        containsAll(<String>[
          '/health',
          '/contacts',
          '/contacts/accept',
          '/contacts/block',
          '/messages',
          '/groups',
          '/groups/messages',
          '/files',
          '/files/download',
          '/calls',
          '/calls/hangup',
        ]),
      );
      // The security scheme is declared so generated clients wire the token.
      expect(
        ((spec['components'] as Map)['securitySchemes'] as Map)['bearerAuth'],
        isNotNull,
      );
      // The spec itself is behind auth like every other route.
      expect(
        (await make().handle('GET', u('/v1/openapi.json'), null)).status,
        401,
      );
    },
  );

  test('an authenticated unknown route is 404, not 401', () async {
    final res = await make().handle(
      'GET',
      u('/v1/nope'),
      'Bearer secret-token',
    );
    expect(res.status, 404);
  });

  test('tokenOk (WS query-token auth) accepts only the exact token', () {
    final h = make();
    expect(h.tokenOk('secret-token'), isTrue);
    expect(h.tokenOk('secret-toke'), isFalse); // shorter
    expect(h.tokenOk('wrong-token!'), isFalse);
    expect(h.tokenOk(null), isFalse);
    expect(h.tokenOk(''), isFalse);
    expect(make(token: '').tokenOk(''), isFalse, reason: 'empty token rejects');
  });

  test('ApiConfig.copyWith + empty defaults; ApiToken JSON round-trip', () {
    expect(ApiConfig.empty.enabled, false);
    expect(ApiConfig.empty.tokens, isEmpty);
    final t = const ApiToken(id: 'i', name: 'n', token: 's', readOnly: true);
    final c = ApiConfig.empty.copyWith(enabled: true, tokens: [t]);
    expect(c.enabled, true);
    expect(c.tokens.single.token, 's');
    final rt = ApiToken.fromJson(t.toJson())!;
    expect(rt.id, 'i');
    expect(rt.readOnly, true);
    // copyWith keeps the webhook; withWebhook sets AND clears it.
    final w = c.withWebhook('http://127.0.0.1:9911/hook');
    expect(w.copyWith(enabled: false).webhookUrl, 'http://127.0.0.1:9911/hook');
    expect(w.withWebhook(null).webhookUrl, isNull);
  });

  test('webhookUrlError enforces loopback-only http(s)', () {
    expect(webhookUrlError('http://127.0.0.1:9911/hook'), isNull);
    expect(webhookUrlError('http://localhost:8080/x'), isNull);
    expect(webhookUrlError('https://127.0.0.1/x'), isNull);
    // Cleartext must not leave the machine (privacy canon).
    expect(webhookUrlError('http://192.168.1.10/x'), isNotNull);
    expect(webhookUrlError('http://example.com/x'), isNotNull);
    expect(webhookUrlError('ftp://127.0.0.1/x'), isNotNull);
    expect(webhookUrlError('not a url'), isNotNull);
  });

  test(
    'webhook routes: get/set/clear, validation, read-only refuses writes',
    () async {
      String? hook;
      ApiHandler withHook({bool readOnly = false}) => ApiHandler(
        tokens: [
          ApiToken(id: 't', name: 't', token: 'tok', readOnly: readOnly),
        ],
        status: () => const {'ok': true},
        contacts: () async => const [],
        send: (to, body) async => null,
        messages: (peer, limit) async => const [],
        sendFile: (to, path, name) async => null,
        loadFile: (fileId) async => null,
        placeCall: (to, media) async => null,
        callState: () => null,
        callAction: (action) async {},
        groups: () async => const [],
        createGroup: (_) async => 'gid',
        groupMessages: (_, _) async => const [],
        sendGroupMessage: (_, _, _) async => null,
        webhook: () => hook,
        setWebhook: (url) async => hook = url,
      );
      final h = withHook();
      // Unset → null; set a loopback URL → stored; get reflects it.
      expect((await h.handle('GET', u('/v1/webhook'), 'Bearer tok')).body, {
        'url': null,
      });
      final set = await h.handle(
        'POST',
        u('/v1/webhook'),
        'Bearer tok',
        body: {'url': 'http://127.0.0.1:9911/hook'},
      );
      expect(set.status, 200);
      expect(hook, 'http://127.0.0.1:9911/hook');
      expect((await h.handle('GET', u('/v1/webhook'), 'Bearer tok')).body, {
        'url': 'http://127.0.0.1:9911/hook',
      });
      // A non-loopback target is refused and does not overwrite.
      final bad = await h.handle(
        'POST',
        u('/v1/webhook'),
        'Bearer tok',
        body: {'url': 'http://evil.example.com/x'},
      );
      expect(bad.status, 400);
      expect(hook, 'http://127.0.0.1:9911/hook');
      // DELETE clears.
      expect(
        (await h.handle('DELETE', u('/v1/webhook'), 'Bearer tok')).status,
        200,
      );
      expect(hook, isNull);
      // A read-only token can GET but neither POST nor DELETE (non-GET = write).
      hook = 'http://127.0.0.1:1/x';
      final ro = withHook(readOnly: true);
      expect(
        (await ro.handle('GET', u('/v1/webhook'), 'Bearer tok')).status,
        200,
      );
      expect(
        (await ro.handle(
          'POST',
          u('/v1/webhook'),
          'Bearer tok',
          body: {'url': 'http://127.0.0.1:2/y'},
        )).status,
        403,
      );
      expect(
        (await ro.handle('DELETE', u('/v1/webhook'), 'Bearer tok')).status,
        403,
      );
      expect(hook, 'http://127.0.0.1:1/x');
      // A host without the webhook wired (default fixture) 404s the route.
      expect(
        (await make().handle(
          'GET',
          u('/v1/webhook'),
          'Bearer secret-token',
        )).status,
        404,
      );
    },
  );

  test(
    'pushWebhookEvent POSTs the event JSON to a real loopback server',
    () async {
      final received = <(String?, String)>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        received.add((
          req.headers.value('X-XVeil-Event'),
          await utf8.decoder.bind(req).join(),
        ));
        req.response.statusCode = 200;
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));
      final url = 'http://127.0.0.1:${server.port}/hook';
      final ok = await pushWebhookEvent(url, {
        'type': 'message',
        'from': 'aabb',
        'preview': 'hi',
        'isFile': false,
      });
      expect(ok, isTrue);
      expect(received, hasLength(1));
      expect(received.single.$1, 'message');
      expect(jsonDecode(received.single.$2), {
        'type': 'message',
        'from': 'aabb',
        'preview': 'hi',
        'isFile': false,
      });
      // An unreachable target reports failure (the caller's retry kicks in).
      await server.close(force: true);
      expect(
        await pushWebhookEvent(url, const {
          'type': 'message',
        }, timeout: const Duration(milliseconds: 500)),
        isFalse,
      );
    },
  );
}
