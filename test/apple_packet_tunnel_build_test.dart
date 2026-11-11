import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS PacketTunnel links an isolated feature-pinned Rust archive', () async {
    const scriptPath = 'scripts/build-packet-tunnel-macos.sh';
    final script = await File(scriptPath).readAsString();
    final project = await File(
      'macos/Runner.xcodeproj/project.pbxproj',
    ).readAsString();
    final provider = await File(
      'third_party/veil/flutter/veil_flutter/apple/PacketTunnelProvider.swift',
    ).readAsString();
    final iosPlugin = await File(
      'third_party/veil/flutter/veil_flutter/ios/Classes/VeilFlutterPlugin.swift',
    ).readAsString();
    final macosPlugin = await File(
      'third_party/veil/flutter/veil_flutter/macos/Classes/VeilFlutterPlugin.swift',
    ).readAsString();

    // The feature list is COMPOSED, not spelled out: the seed feature comes
    // from scripts/veil-network.sh, which is the single rule deciding which
    // network a build talks to. Asserting the literal `production-seeds` here
    // is what this test used to do, and it put two gates in direct
    // contradiction — seed_feature_single_rule_test forbids a cargo
    // invocation that names a seed feature of its own, which is exactly what
    // satisfying this literal would require. What still matters is that the
    // tunnel is built with the embedded node and the tunnel feature, and that
    // the network half is read from the rule rather than chosen here.
    expect(script, contains('source "\$ROOT/scripts/veil-network.sh"'));
    expect(script, contains('node-embedded,\$SEED_FEATURE,packet-tunnel'));
    expect(script, contains('xveil-packet-tunnel-macos-\$arch'));
    expect(project, contains('Build PacketTunnel Rust FFI'));
    expect(
      project,
      contains(
        r'build/apple-packet-tunnel/$(CONFIGURATION)/libveilclient_ffi.a',
      ),
    );
    expect(
      project,
      isNot(contains('third_party/veil/target/debug/libveilclient_ffi.a')),
    );
    expect(
      project,
      isNot(contains('third_party/veil/target/release/libveilclient_ffi.a')),
    );
    expect(provider, contains('let exitNodeIds: [String]'));
    expect(provider, contains('exitNodeIds.joined(separator: ",")'));
    expect(iosPlugin, contains('providerConfiguration["exitNodeIds"]'));
    expect(macosPlugin, contains('providerConfiguration["exitNodeIds"]'));

    final syntax = await Process.run('bash', ['-n', scriptPath]);
    expect(syntax.exitCode, 0, reason: '${syntax.stdout}${syntax.stderr}');
  });
  test('Xcode tunnel build honors an isolated cache override', () async {
    final root = await Directory.systemTemp.createTemp('xveil-tunnel-build-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/scripts').create();
    for (final name in ['build-packet-tunnel-macos.sh', 'veil-network.sh']) {
      await File('scripts/$name').copy('${root.path}/scripts/$name');
    }
    final bin = await Directory('${root.path}/bin').create();
    final cargo = File('${bin.path}/cargo');
    await cargo.writeAsString(r'''#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
args=sys.argv[1:]
triple=args[args.index('--target')+1]
dest=Path(os.environ['CARGO_TARGET_DIR'])/triple/'release'/'libveilclient_ffi.a'
dest.parent.mkdir(parents=True,exist_ok=True)
dest.write_text(json.dumps({'target':os.environ['CARGO_TARGET_DIR'],
                           'features':args[args.index('--features')+1]}))
''');
    expect((await Process.run('chmod', ['+x', cargo.path])).exitCode, 0);
    final isolated = '${root.path}/isolated cache';
    final result = await Process.run(
      'bash',
      ['${root.path}/scripts/build-packet-tunnel-macos.sh', 'Release', 'arm64'],
      environment: {
        'PATH': '${bin.path}:${Platform.environment['PATH']}',
        'CARGO_TARGET_DIR': '${root.path}/ordinary-ffi',
        'XVEIL_PACKET_TUNNEL_TARGET_BASE': isolated,
        'XVEIL_NETWORK': 'prod',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final accepted =
        jsonDecode(
              await File(
                '${root.path}/build/apple-packet-tunnel/Release/libveilclient_ffi.a',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(accepted['target'], '$isolated/xveil-packet-tunnel-macos-arm64');
    expect(
      accepted['features'],
      'node-embedded,production-seeds,packet-tunnel',
    );
    expect(Directory('${root.path}/ordinary-ffi').existsSync(), isFalse);
    expect(
      Directory('${root.path}/third_party/veil/target').existsSync(),
      isFalse,
    );
  });
}
