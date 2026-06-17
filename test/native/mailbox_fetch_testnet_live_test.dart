import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';

/// PATH B — receiver network FETCH over the REAL testnet.
///
/// Boots an anonymous embedded node against the testnet (obfs4 PSK + bootstrap),
/// lets it register its rendezvous ad over an onion circuit, then sends an
/// AUTHENTICATED-with-reply FETCH to a testnet mailbox relay (node1, which has
/// [mailbox].enabled + receive_anonymous). The relay's FETCH service verifies
/// our identity, gathers our blobs, and replies over the one-time reply path.
///
/// Receiving the reply proves the full network-FETCH path on the real
/// distributed net (request → onion → relay FETCH service → reply → us). The
/// mailbox is empty for this fresh identity, so the reply carries 0 blobs —
/// non-empty content retrieval is proven locally (mailbox_fetch_live_test, the
/// dev-mailbox-onion harness). What this adds: it works over geographically
/// distributed nodes + obfs4 + multi-hop circuits, not just a loopback mesh.
///
/// Env (skips unless all set):
///   VEIL_FFI_DYLIB        = release libveilclient_ffi.dylib (--features
///                           node-embedded[,allow-empty-seeds])
///   XVEIL_BOOTSTRAP_PEERS = bootstrap-peers JSON (gitignored)
///   XVEIL_OBFS4_PSK       = base64 deployment-wide obfs4 PSK
///   XVEIL_RELAY_NODE_ID   = 64-hex node_id of the testnet mailbox relay (node1)
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

  final mailboxAppId = Uint8List.fromList(const [
    0xd4, 0x17, 0xcf, 0x22, 0x72, 0x89, 0x07, 0x40, //
    0xe2, 0xe1, 0xb6, 0xb1, 0xb5, 0x74, 0x12, 0x95,
    0x6b, 0x3e, 0xfc, 0xc6, 0xfd, 0xd4, 0x95, 0x4f,
    0xc4, 0xd4, 0x9b, 0x1c, 0xee, 0x36, 0xf5, 0xbb,
  ]);
  const mailboxFetchEndpointId = 2;
  const replyEndpointId = 7;

  test('embedded testnet node FETCHes its mailbox from a testnet relay',
      () async {
    final lib = DynamicLibrary.open(dylib!);
    final peers = BootstrapPeerCfg.listFromJson(
        jsonDecode(File(peersFile!).readAsStringSync()) as List);
    expect(peers, isNotEmpty, reason: 'no bootstrap peers loaded');
    final relayId = _hex(relayIdHex!);

    final runtimeDir =
        Directory.systemTemp.createTempSync('xveil-mailbox-testnet-').path;
    final pskFile = '$runtimeDir/obfs4_psk.b64';
    File(pskFile).writeAsStringSync(psk!);
    final adminSock = '$runtimeDir/admin.sock';
    final ipcSock = '$runtimeDir/app.sock';

    stderr.writeln('[fetch-testnet] mining ephemeral identity…');
    final identityToml = EmbeddedNode.mineConfig(0, lib: lib);
    final config = EmbeddedNode.composeConfig(
      identityToml: identityToml,
      listenTransport: 'tcp://127.0.0.1:9146',
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
    AppHandle? app;
    try {
      await controller.start();
      expect(controller.current.phase, NodePhase.connected);
      stderr.writeln('[fetch-testnet] node connected; warming '
          'rendezvous/onion (45s) before FETCH…');
      await Future<void>.delayed(const Duration(seconds: 45));

      client = await VeilClient.connect(ipcSock);
      app = await client.bind(
          namespace: 'xveil', name: 'mailbox-fetch', endpointId: replyEndpointId);
      final reply = Completer<IncomingMessage>();
      final sub = app.messages().listen((m) {
        if (!reply.isCompleted) reply.complete(m);
      });

      var attempts = 0;
      var sendsOk = 0;
      Object? lastErr;
      while (!reply.isCompleted && attempts < 40) {
        try {
          await app.sendAnonymousAuthenticatedWithReply(
            dstNodeId: relayId,
            dstAppId: mailboxAppId,
            dstEndpointId: mailboxFetchEndpointId,
            replyEndpointId: replyEndpointId,
            data: Uint8List(0),
          );
          sendsOk++;
        } catch (e) {
          lastErr = e;
        }
        attempts++;
        await Future.any([
          reply.future,
          Future<void>.delayed(const Duration(seconds: 3)),
        ]);
      }
      stderr.writeln('[fetch-testnet] attempts=$attempts sendsOk=$sendsOk '
          'received=${reply.isCompleted} lastErr=$lastErr');
      expect(reply.isCompleted, isTrue,
          reason: 'no FETCH reply from the testnet relay over the onion; '
              'sendsOk=$sendsOk lastErr=$lastErr');
      final msg = await reply.future;
      await sub.cancel();

      // A well-formed MailboxFetchResp (count u16 BE prefix; 0 for an empty
      // mailbox). Decoding it confirms the relay's FETCH service answered us.
      expect(msg.data.length, greaterThanOrEqualTo(2),
          reason: 'reply too short to be a MailboxFetchResp');
      final count = ByteData.sublistView(msg.data).getUint16(0, Endian.big);
      stderr.writeln('[fetch-testnet] ✓ relay replied over the onion: '
          'MailboxFetchResp count=$count (${msg.data.length} bytes)');
    } finally {
      await app?.close();
      await client?.close();
      await controller.stop();
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 240)));
}

Uint8List _hex(String h) => Uint8List.fromList(
    [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
