import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';

/// CHUNK 4 — CROSS-NODE relay-key resolve over the REAL testnet.
///
/// Boots a fresh anonymous embedded node against the testnet, then resolves a
/// DIFFERENT testnet node's relay X25519 KEM key by its node_id alone
/// (`lookupRelayX25519`). Unlike the local self-resolve, this requires the
/// target's signed RelayKeyRecord to be discoverable cross-node over the real
/// DHT — the missing piece that lets a receiver advertise an always-on relay as
/// its mailbox host on the live network.
///
/// Env (skips unless all set):
///   VEIL_FFI_DYLIB        = release libveilclient_ffi.dylib (node-embedded)
///   XVEIL_BOOTSTRAP_PEERS = bootstrap-peers JSON (gitignored)
///   XVEIL_OBFS4_PSK       = base64 deployment-wide obfs4 PSK
///   XVEIL_RELAY_NODE_ID   = 64-hex node_id of a relay-capable testnet node
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final peersFile = Platform.environment['XVEIL_BOOTSTRAP_PEERS'];
  final psk = Platform.environment['XVEIL_OBFS4_PSK'];
  final relayIdHex = Platform.environment['XVEIL_RELAY_NODE_ID'];
  final skip = (dylib == null || dylib.isEmpty || peersFile == null ||
          peersFile.isEmpty || psk == null || psk.isEmpty ||
          relayIdHex == null || relayIdHex.length != 64)
      ? 'set VEIL_FFI_DYLIB + XVEIL_BOOTSTRAP_PEERS + XVEIL_OBFS4_PSK + XVEIL_RELAY_NODE_ID(64hex)'
      : false;

  test('embedded testnet node resolves a peer relay X25519 by node_id',
      () async {
    final lib = DynamicLibrary.open(dylib!);
    final peers = BootstrapPeerCfg.listFromJson(
        jsonDecode(File(peersFile!).readAsStringSync()) as List);
    expect(peers, isNotEmpty, reason: 'no bootstrap peers loaded');
    final relayId = _hex(relayIdHex!);

    final runtimeDir =
        Directory.systemTemp.createTempSync('xveil-relaykey-testnet-').path;
    final pskFile = '$runtimeDir/obfs4_psk.b64';
    File(pskFile).writeAsStringSync(psk!);
    final adminSock = '$runtimeDir/admin.sock';
    final ipcSock = '$runtimeDir/app.sock';

    stderr.writeln('[relaykey-testnet] mining ephemeral identity…');
    final identityToml = EmbeddedNode.mineConfig(0, lib: lib);
    final config = EmbeddedNode.composeConfig(
      identityToml: identityToml,
      listenTransport: 'tcp://127.0.0.1:9147',
      ipcSocket: ipcSock,
      adminSocket: adminSock,
      lib: lib,
      anonymous: true,
      bootstrapPeers: peers,
      obfs4PskFile: pskFile,
    );

    final controller = EmbeddedNodeController(
      appSocketPath: ipcSock,
      starter: () {
        final node =
            EmbeddedNode.startDeferred(adminSock, anonymous: true, lib: lib);
        node.applyConfig(config);
        return node;
      },
    );

    VeilClient? client;
    try {
      await controller.start();
      expect(controller.current.phase, NodePhase.connected);
      stderr.writeln('[relaykey-testnet] connected; warming DHT (60s)…');
      await Future<void>.delayed(const Duration(seconds: 60));

      client = await VeilClient.connect(ipcSock);
      Uint8List? resolved;
      var attempts = 0;
      while (resolved == null && attempts < 18) {
        attempts++;
        try {
          final r = await client.lookupRelayX25519(relayId);
          stderr.writeln('[relaykey-testnet] attempt $attempts: '
              '${r == null ? "null (DHT miss/unresolved)" : "${r.length}B"}');
          resolved = r;
        } catch (e) {
          stderr.writeln('[relaykey-testnet] attempt $attempts err: $e');
        }
        if (resolved == null) {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
      stderr.writeln('[relaykey-testnet] resolved after $attempts attempt(s): '
          '${resolved == null ? "NULL (not discoverable cross-node yet)" : "${resolved.length}B"}');
      expect(resolved, isNotNull,
          reason: 'could not resolve the peer relay X25519 cross-node over the '
              'testnet DHT (RelayKeyRecord may not be replicated yet)');
      expect(resolved!.length, 32);
      stderr.writeln('[relaykey-testnet] ✓ cross-node relay X25519 resolved over the testnet');
    } finally {
      await client?.close();
      await controller.stop();
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 360)));
}

Uint8List _hex(String h) => Uint8List.fromList(
    [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
