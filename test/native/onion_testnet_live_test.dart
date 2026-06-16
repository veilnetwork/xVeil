import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';

/// Headless onion proof: boot an ANONYMOUS embedded node against a live network
/// (the testnet) with its obfs4 PSK + bootstrap peers, and hold it up long
/// enough for it to dial the mesh and auto-register its rendezvous ad over an
/// onion circuit. No GUI. Watch the relays' metrics
/// (veil_rendezvous_requests_received_total / veil_mesh_relay_hops_total)
/// climb while this runs — that is the circuit forming.
///
/// Env-gated (skips unless all set):
///   VEIL_FFI_DYLIB         = release libveilclient_ffi.dylib (--features
///                            node-embedded[,allow-empty-seeds])
///   XVEIL_BOOTSTRAP_PEERS  = path to the bootstrap-peers JSON (gitignored)
///   XVEIL_OBFS4_PSK        = base64 deployment-wide obfs4 PSK
///   XVEIL_ONION_HOLD_SECS  = how long to stay connected (default 60)
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final peersFile = Platform.environment['XVEIL_BOOTSTRAP_PEERS'];
  final psk = Platform.environment['XVEIL_OBFS4_PSK'];
  final holdSecs =
      int.tryParse(Platform.environment['XVEIL_ONION_HOLD_SECS'] ?? '') ?? 60;
  final skip = (dylib == null || dylib.isEmpty || peersFile == null ||
          peersFile.isEmpty || psk == null || psk.isEmpty)
      ? 'set VEIL_FFI_DYLIB + XVEIL_BOOTSTRAP_PEERS + XVEIL_OBFS4_PSK'
      : false;

  test('anonymous embedded node joins the testnet and arms onion', () async {
    final lib = DynamicLibrary.open(dylib!);
    final peers = BootstrapPeerCfg.listFromJson(
        jsonDecode(File(peersFile!).readAsStringSync()) as List);
    expect(peers, isNotEmpty, reason: 'no bootstrap peers loaded');

    final runtimeDir =
        Directory.systemTemp.createTempSync('xveil-onion-live-').path;
    final pskFile = '$runtimeDir/obfs4_psk.b64';
    File(pskFile).writeAsStringSync(psk!);
    final adminSock = '$runtimeDir/admin.sock';
    final ipcSock = '$runtimeDir/app.sock';

    // Fresh ephemeral identity (release PoW is fast). Nothing persisted.
    stderr.writeln('[onion-live] mining ephemeral identity…');
    final identityToml = EmbeddedNode.mineConfig(0, lib: lib);

    final config = EmbeddedNode.composeConfig(
      identityToml: identityToml,
      listenTransport: 'tcp://127.0.0.1:9145',
      ipcSocket: ipcSock,
      adminSocket: adminSock,
      lib: lib,
      anonymous: true, // arm onion at boot
      bootstrapPeers: peers,
      obfs4PskFile: pskFile,
    );
    stderr.writeln('[onion-live] config: has[transport]='
        '${config.contains('[transport]')} obfs4_psk_file='
        '${config.contains('obfs4_psk_file')} '
        'bootstrap_peers=${'[[bootstrap_peers]]'.allMatches(config).length}');

    final controller = EmbeddedNodeController(
      appSocketPath: ipcSock,
      starter: () {
        final node =
            EmbeddedNode.startDeferred(adminSock, anonymous: true, lib: lib);
        node.applyConfig(config);
        return node;
      },
    );

    try {
      await controller.start();
      expect(controller.current.phase, NodePhase.connected);
      stderr.writeln('[onion-live] node connected; holding ${holdSecs}s for '
          'mesh dial + rendezvous registration (watch relay metrics now)…');
      await Future<void>.delayed(Duration(seconds: holdSecs));
      stderr.writeln('[onion-live] hold complete; stopping.');
    } finally {
      await controller.stop();
    }
  }, skip: skip, timeout: Timeout(Duration(seconds: holdSecs + 90)));
}
