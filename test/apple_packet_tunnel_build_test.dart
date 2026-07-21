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

    expect(script, contains('node-embedded,packet-tunnel'));
    expect(script, contains('node-embedded,production-seeds,packet-tunnel'));
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
