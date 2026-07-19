import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/headless/headless_config.dart';

void main() {
  late Directory temp;

  setUp(() async => temp = await Directory.systemTemp.createTemp('xvh-cfg-'));
  tearDown(() async => temp.delete(recursive: true));

  test('loads public config and environment overrides', () async {
    final file = File('${temp.path}/headless.json');
    await file.writeAsString(
      jsonEncode({
        'store': '${temp.path}/store.hv',
        'runtime_dir': '${temp.path}/runtime',
        'blob_dir': '${temp.path}/blobs',
        'listen_port': 9000,
        'api_port': 8787,
        'anonymous': true,
        'udp_reflectors': ['127.0.0.1:39999'],
        'bootstrap_peers': [
          {
            'transport': 'tcp://127.0.0.1:1',
            'public_key': 'AQID',
            'nonce': 'BAUG',
          },
        ],
      }),
    );
    final config = await HeadlessConfig.load(
      file.path,
      environment: {'XVEIL_API_PORT': '18787', 'XVEIL_ANONYMOUS': 'false'},
    );
    expect(config.apiPort, 18787);
    expect(config.listenPort, 9000);
    expect(config.anonymous, isFalse);
    expect(config.bootstrapPeers.single.algo, 'ed25519');
    expect(config.udpReflectors, ['127.0.0.1:39999']);
    expect(config.storePath, File('${temp.path}/store.hv').absolute.path);
  });

  test('rejects secrets in JSON and invalid public fields', () async {
    Future<void> write(Map<String, Object?> value) =>
        File('${temp.path}/headless.json').writeAsString(jsonEncode(value));
    final base = <String, Object?>{
      'store': '${temp.path}/store.hv',
      'runtime_dir': '${temp.path}/runtime',
      'blob_dir': '${temp.path}/blobs',
      'bootstrap_peers': <Object>[],
    };
    for (final key in ['password', 'identity_phrase', 'api_token']) {
      await write({...base, key: 'must-not-live-here'});
      await expectLater(
        HeadlessConfig.load(
          '${temp.path}/headless.json',
          environment: const {},
        ),
        throwsFormatException,
      );
    }
    await write({...base, 'api_port': 70000});
    await expectLater(
      HeadlessConfig.load('${temp.path}/headless.json', environment: const {}),
      throwsFormatException,
    );
    await write({
      ...base,
      'udp_reflectors': ['reflector.example:39999'],
    });
    await expectLater(
      HeadlessConfig.load('${temp.path}/headless.json', environment: const {}),
      throwsFormatException,
    );
  });
}
