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

  group('the shared seed nodes, for a node with no app profile', () {
    // A daemon has no SharedPreferences and no onboarding screen, so the file
    // it composes its node from is where it states this — and the key has to
    // have THREE states, because "false" (a refusal) and "absent" (ask the
    // identity's own space) are different instructions. A two-state flag with a
    // default would silently answer for every operator who never wrote the key.
    late Map<String, Object?> base;
    setUp(() {
      base = <String, Object?>{
        'store': '${temp.path}/store.hv',
        'runtime_dir': '${temp.path}/runtime',
        'blob_dir': '${temp.path}/blobs',
        'bootstrap_peers': <Object>[],
      };
    });

    Future<HeadlessConfig> load(
      Map<String, Object?> value, {
      Map<String, String> environment = const {},
    }) async {
      final file = File('${temp.path}/headless.json');
      await file.writeAsString(jsonEncode(value));
      return HeadlessConfig.load(file.path, environment: environment);
    }

    test('a file that does not mention it says NOTHING, not yes', () async {
      final config = await load(base);
      expect(
        config.useBundledSeeds,
        isNull,
        reason: 'null is what hands the question to the identity\'s own space; '
            'a default here would compose every daemon the same way and call '
            'it the operator\'s choice',
      );
    });

    test('a stated answer is carried, either way', () async {
      expect(
        (await load({...base, 'use_bundled_seeds': false})).useBundledSeeds,
        isFalse,
      );
      expect(
        (await load({...base, 'use_bundled_seeds': true})).useBundledSeeds,
        isTrue,
      );
    });

    test('the environment states it too, and an EMPTY variable is unset', () async {
      expect(
        (await load(
          base,
          environment: {'XVEIL_USE_BUNDLED_SEEDS': 'no'},
        )).useBundledSeeds,
        isFalse,
      );
      expect(
        (await load(
          {...base, 'use_bundled_seeds': false},
          environment: {'XVEIL_USE_BUNDLED_SEEDS': 'yes'},
        )).useBundledSeeds,
        isTrue,
        reason: 'the environment wins over the file, as it does for every other '
            'key here',
      );
      expect(
        (await load(
          {...base, 'use_bundled_seeds': true},
          environment: {'XVEIL_USE_BUNDLED_SEEDS': ''},
        )).useBundledSeeds,
        isTrue,
        reason: 'an exported-but-empty variable is unset — it must not read as '
            '"off" and take a working daemon off the network',
      );
    });

    test('a value that is not a boolean is refused, not guessed at', () async {
      await expectLater(
        load({...base, 'use_bundled_seeds': 'sometimes'}),
        throwsFormatException,
      );
    });

    test('the example config states it, so it can be found', () async {
      expect(HeadlessConfig.example.containsKey('use_bundled_seeds'), isTrue);
    });
  });
}
