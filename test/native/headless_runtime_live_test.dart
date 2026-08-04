import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/headless/headless_config.dart';
import 'package:xveil/headless/headless_runtime.dart';

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<Map<String, dynamic>> _health(int port, String token) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/v1/health'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close();
    expect(response.statusCode, 200);
    return jsonDecode(await utf8.decoder.bind(response).join())
        as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _post(
  int port,
  String token,
  String path,
  Map<String, dynamic> body,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final decoded =
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw StateError('$path failed ${response.statusCode}: $decoded');
    }
    return decoded;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _get(int port, String token, String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close();
    final decoded =
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw StateError('$path failed ${response.statusCode}: $decoded');
    }
    return decoded;
  } finally {
    client.close(force: true);
  }
}

Future<void> _waitUntil(Future<bool> Function() predicate) async {
  final until = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(until)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw TimeoutException('headless pair did not converge');
}

void main() {
  final enabled = Platform.environment['HEADLESS_LIVE'] == '1';

  test(
    'real Flutter-free runtime persists identity and cleans runtime sockets',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'xveil-headless-live-',
      );
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final config = HeadlessConfig(
        storePath: '${temp.path}/store.hv',
        runtimeDir: '${temp.path}/runtime',
        blobDir: '${temp.path}/blobs',
        listenPort: await _freePort(),
        apiPort: 0,
        anonymous: false,
        bootstrapPeers: const [],
      );
      const token = 'headless-live-token-0123456789abcdef0123456789';
      HeadlessRuntime? first;
      HeadlessRuntime? second;
      HeadlessRuntime? peer;
      try {
        first = await HeadlessRuntime.start(
          config: config,
          password: 'headless-live-password',
          createIfMissing: true,
          apiToken: token,
        );
        final initial = await _health(first.api.port!, token);
        expect(initial['host'], 'headless');
        expect(initial['ok'], isTrue);
        final nodeId = initial['nodeId'];
        final created = await _post(first.api.port!, token, '/v1/groups', {
          'name': 'headless-persisted-group',
        });
        final groupId = NodeId.fromHex(created['groupId'] as String);
        await _post(first.api.port!, token, '/v1/groups/messages', {
          'group': groupId.hex,
          'body': 'headless-persisted-message',
        });
        await first.close();
        first = null;
        // `runtime_dir` is the BASE the daemon creates its own directory under
        // (audit C-02), so shutdown empties it rather than removing it: what
        // must be gone is everything the run put there.
        expect(
          Directory(config.runtimeDir).listSync(),
          isEmpty,
          reason: 'the leased runtime directory outlived the daemon',
        );

        second = await HeadlessRuntime.start(
          config: config,
          password: 'headless-live-password',
        );
        final reopened = await _health(second.api.port!, token);
        expect(reopened['nodeId'], nodeId);
        expect(reopened['ok'], isTrue);
        final reopenedGroups = await _get(
          second.api.port!,
          token,
          '/v1/groups',
        );
        expect(
          (reopenedGroups['groups'] as List).whereType<Map>().any(
            (group) => group['groupId'] == groupId.hex,
          ),
          isTrue,
        );
        final reopenedMessages = await _get(
          second.api.port!,
          token,
          '/v1/groups/messages?group=${groupId.hex}',
        );
        expect(
          (reopenedMessages['messages'] as List).whereType<Map>().any(
            (message) => message['body'] == 'headless-persisted-message',
          ),
          isTrue,
        );

        final peerConfig = HeadlessConfig(
          storePath: '${temp.path}/peer.hv',
          runtimeDir: '${temp.path}/peer-runtime',
          blobDir: '${temp.path}/peer-blobs',
          listenPort: await _freePort(),
          apiPort: 0,
          anonymous: false,
          bootstrapPeers: const [],
        );
        const peerToken = 'headless-peer-token-0123456789abcdef0123456789';
        peer = await HeadlessRuntime.start(
          config: peerConfig,
          password: 'headless-peer-password',
          createIfMissing: true,
          apiToken: peerToken,
        );
        final sourceTransport = second.stack.transport as VeilFlutterTransport;
        final peerTransport = peer.stack.transport as VeilFlutterTransport;
        final sourceInvite = await sourceTransport.createInvite();
        final peerInvite = await peerTransport.createInvite();
        await peerTransport.joinInvite(sourceInvite);

        await _post(second.api.port!, token, '/v1/contacts', {
          'target': peerInvite,
          'greeting': 'headless-pair-request',
        });
        final sourceId = NodeId.fromHex(reopened['nodeId'] as String);
        final peerHealth = await _health(peer.api.port!, peerToken);
        final peerId = NodeId.fromHex(peerHealth['nodeId'] as String);
        await _waitUntil(
          () async =>
              (await peer!.storage.getContact(sourceId))?.status ==
              ContactStatus.pendingIncoming,
        );
        await _post(peer.api.port!, peerToken, '/v1/contacts/accept', {
          'peer': sourceId.hex,
        });
        await _waitUntil(
          () async =>
              (await second!.storage.getContact(peerId))?.status ==
              ContactStatus.accepted,
        );
        await _post(second.api.port!, token, '/v1/messages', {
          'to': peerId.hex,
          'body': 'headless-pair-message',
        });
        await _waitUntil(
          () async => (await peer!.storage.loadMessages(
            sourceId.hex,
          )).any((message) => message.body == 'headless-pair-message'),
        );
      } finally {
        await peer?.close();
        await second?.close();
        await first?.close();
      }
    },
    skip: enabled ? false : 'set HEADLESS_LIVE=1 with both native dylibs',
    timeout: const Timeout(Duration(minutes: 7)),
  );
}
