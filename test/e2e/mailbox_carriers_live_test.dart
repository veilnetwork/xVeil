// The claim this proves: a node with NO configured seeds — every stock
// production install — still ends up with mailbox carriers, because it finds
// peers by itself and those peers are now offered as candidates.
//
// It has to be live. The whole defect was that one half of the app (the node)
// was connected while the other half (the candidate list) was empty, and no
// unit test can see that: it needs a real node doing real discovery. This one
// starts one, waits for it to find anybody, and then asks the same function
// the app asks.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/state/messaging.dart';

import 'e2e_env.dart';

({String? veil, String? hv, Object skip}) _gate() {
  String? present(String key) {
    final raw = Platform.environment[key]?.trim();
    if (raw == null || raw.isEmpty || !raw.startsWith('/')) return null;
    return File(raw).existsSync() ? raw : null;
  }

  final veil = present('VEIL_FFI_DYLIB');
  final hv = present('HIDDEN_VOLUME_FFI_DYLIB');
  final missing = <String>[
    if (veil == null) 'VEIL_FFI_DYLIB',
    if (hv == null) 'HIDDEN_VOLUME_FFI_DYLIB',
  ];
  return (
    veil: veil,
    hv: hv,
    skip: missing.isEmpty
        ? false
        : 'live carrier check is gated: set ${missing.join(' + ')} to the '
              'debug dylibs (see test/e2e/README.md)',
  );
}

void main() {
  final gate = _gate();

  test(
    'a node with nothing configured still finds someone to carry for it',
    () async {
      final root = await Directory.systemTemp.createTemp('xveil-carriers-');
      addTearDown(() => root.delete(recursive: true).catchError((_) => root));
      await Directory('${root.path}/runtime').create(recursive: true);

      final storage = HiddenVolumeStorage.async(
        workerSpaceOpener('${root.path}/store.hv'),
      );
      expect(
        await storage.open(password: 'live-carrier-probe', createIfMissing: true),
        isTrue,
      );

      // EXACTLY the stock production shape: no bootstrap peers, no bundled
      // seeds. Everything this node knows it has to find for itself.
      final stack = await RealVeilStack.startDeniable(
        storage: storage,
        runtimeDirBase: '${root.path}/runtime',
        lib: DynamicLibrary.open(gate.veil!),
        listenPort: await freePort(),
        debugMetricsPort: await freePort(),
        lanListen: true,
        useBundledSeeds: false,
        // Named rather than defaulted: WHERE a node looks for its first peer
        // is a separate choice from whether it may dial the compiled-in seeds,
        // and this probe is about the first one.
        meetingPoints: EmbeddedNode.meetingPoints,
        // The deployment PSK, without which every discovered peer is
        // unreachable: they all advertise `obfs4-tcp://`, and the transport
        // refuses to dial one with no key. The first run of this probe left it
        // out and read the result as "discovery found nobody" — it had found
        // three records in four seconds and could not dial any of them.
        obfs4Psk: File('assets/prod/obfs4_psk.b64').readAsStringSync().trim(),
      );
      addTearDown(stack.dispose);
      final transport = stack.transport;

      // Before anything is found, the answer is honestly empty — the CONTROL
      // for the assertion below, and the state the shipped app was stuck in.
      expect(
        await liveMailboxRelayCandidates(
          peers: () async => const <PeerInfo>[],
          configured: const <NodeId>[],
        ),
        isEmpty,
        reason: 'a node that has found nobody has nobody to be carried by',
      );

      // Discovery is not instant and this is a real network, so wait for it
      // rather than sampling once.
      var peers = const <PeerInfo>[];
      final deadline = DateTime.now().add(const Duration(minutes: 6));
      while (DateTime.now().isBefore(deadline)) {
        peers = await transport.peers();
        if (peers.any((p) => p.isActive)) break;
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      // ignore: avoid_print
      print('LIVE discovered ${peers.where((p) => p.isActive).length} '
          'active peer(s) with nothing configured');
      expect(
        peers.where((p) => p.isActive),
        isNotEmpty,
        reason: 'this machine reached no peers at all in six minutes — the '
            'check cannot say anything about carriers without a network',
      );

      final carriers = await liveMailboxRelayCandidates(
        peers: transport.peers,
        configured: const <NodeId>[],
      );
      // ignore: avoid_print
      print('LIVE carriers=${carriers.length} (configured=0)');
      expect(
        carriers,
        isNotEmpty,
        reason: 'the node is connected and still has no candidate, which is '
            'the state in which no mailbox is built and a contact request '
            'cannot be delivered',
      );
    },
    timeout: const Timeout(Duration(minutes: 12)),
    skip: gate.skip,
  );
}
