import 'dart:io';

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
    expect(script, contains('target/xveil-packet-tunnel-macos-'));
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
}
