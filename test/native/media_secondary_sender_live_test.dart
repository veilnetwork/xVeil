import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';

// Run with VEIL_MEDIA_IPC_LIVE=1 and VEIL_FFI_DYLIB pointing at a library
// built with node-embedded. Uses only a private local node and fixture identity.
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final enabled =
      Platform.environment['VEIL_MEDIA_IPC_LIVE'] == '1' &&
      dylib != null &&
      dylib.isNotEmpty;
  test(
    'real IPC media bindings install a matching secondary sender and reject another app',
    () async {
      final temp = await Directory.systemTemp.createTemp('xveil-media-ipc-');
      final socket = '${temp.path}/app.sock';
      final datagram = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = datagram.port;
      datagram.close();
      final lib = DynamicLibrary.open(dylib!);
      final config = EmbeddedNode.composeConfig(
        identityToml: await File(
          'test/native/fixtures/public_discovery_identity_1.toml',
        ).readAsString(),
        listenTransport: 'quic://127.0.0.1:$port',
        ipcSocket: socket,
        adminSocket: '${temp.path}/admin.sock',
        useBundledSeeds: false,
        meetingPoints: const [],
        logFile: '${temp.path}/node.log',
        lib: lib,
      );
      final configFile = File('${temp.path}/config.toml');
      await configFile.writeAsString(config);
      final controller = EmbeddedNodeController(
        configPath: configFile.path,
        appSocketPath: socket,
        lib: lib,
      );
      VeilFlutterTransport? transport;
      final clients = <VeilClient>[];
      final apps = <AppHandle>[];
      int? chan;
      try {
        await controller.start();
        expect(
          controller.current.phase,
          NodePhase.connected,
          reason: controller.current.message,
        );
        transport = await VeilFlutterTransport.connect(socket);
        final destination = (await transport.nodeId()).bytes;
        final txKey = Uint8List.fromList(List.filled(32, 1));
        final rxKey = Uint8List.fromList(List.filled(32, 2));
        // Exercises the product's second connection and native setter before
        // exposing its channel to WebRTC, without depending on an external peer.
        chan = await transport.openMediaChannel(
          destination,
          txKey: txKey,
          rxKey: rxKey,
          relay: true,
        );
        expect(chan, greaterThan(0));
        expect(transport.mediaChannelStats(chan), isNotNull);
        transport.closeMediaChannel(chan);
        expect(transport.mediaChannelStats(chan), isNull);
        chan = null;

        Future<AppHandle> bind(String name, int endpoint) async {
          final client = await VeilClient.connect(socket);
          clients.add(client);
          final app = await client.bindNamed(
            namespace: 'media-ipc-test',
            name: name,
            endpointId: endpoint,
          );
          apps.add(app);
          return app;
        }

        final primary = await bind('same-app', 21);
        final secondary = await bind('same-app', 22);
        final wrong = await bind('other-app', 23);
        expect(primary.appId, secondary.appId);
        expect(primary.appId, isNot(wrong.appId));
        chan = await primary.openRelayMediaChannel(
          dstNodeId: destination,
          dstAppId: primary.appId,
          dstEndpointId: 21,
          txKey: txKey,
          rxKey: rxKey,
          secondarySender: secondary,
        );
        expect(primary.mediaChannelStats(chan), isNotNull);
        transport.closeMediaChannel(chan);
        chan = null;
        await expectLater(
          primary.openRelayMediaChannel(
            dstNodeId: destination,
            dstAppId: primary.appId,
            dstEndpointId: 21,
            txKey: txKey,
            rxKey: rxKey,
            secondarySender: wrong,
          ),
          throwsA(
            isA<VeilException>().having(
              (error) => error.toString(),
              'message',
              contains('same app identity'),
            ),
          ),
        );
      } finally {
        if (chan != null) transport?.closeMediaChannel(chan);
        for (final app in apps.reversed) {
          await app.close();
        }
        for (final client in clients.reversed) {
          await client.close();
        }
        await transport?.dispose();
        await controller.dispose();
        expect(
          controller.lastStopWasAbandoned,
          isFalse,
          reason: 'test must stop its node',
        );
        await temp.delete(recursive: true);
      }
    },
    skip: enabled ? false : 'set VEIL_MEDIA_IPC_LIVE=1 + VEIL_FFI_DYLIB',
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
