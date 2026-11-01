import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/state/messaging.dart';

class _Observed extends MessagingService {
  _Observed(super.transport, super.storage);
  Future<int>? automaticTrim;
  @override
  Future<int> dropReplicationBacklogFor(NodeId peer) =>
      automaticTrim = super.dropReplicationBacklogFor(peer);
}

void main() {
  test(
    'fresh capped replication survives a real worker close and reopen',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final dir = await Directory.systemTemp.createTemp(
        'xveil-replication-cap-',
      );
      final open = workerSpaceOpener('${dir.path}/fixture.hv');
      final password = Uint8List.fromList(utf8.encode('cap-fixture'));
      final storage = HiddenVolumeStorage.fromAsyncStore(
        (await open(password: password, create: true))!,
      );
      final me = NodeId(Uint8List(32)..fillRange(0, 32, 1));
      final peer = NodeId(Uint8List(32)..fillRange(0, 32, 2));
      final link = LoopbackTransport(localNodeId: me);
      final messaging = _Observed(link, storage);
      final expected = <String, Uint8List>{
        for (var i = 0; i < 256; i++)
          'grp:copy-$i': WireEnvelope.groupEntry('copy-$i').encode(),
        'user-event': Uint8List.fromList([1, 2, 3]),
      };
      try {
        await Future.wait([
          for (final entry in expected.entries)
            storage.enqueueOutboxFrame(entry.key, peer.hex, entry.value),
        ]);
        await messaging.sendGroupSnapshot(peer, 'ab' * 32, 'refused-new-copy');
        if (messaging.automaticTrim != null) await messaging.automaticTrim;
        // All simple-frame retirements issued by the old background purge are
        // ahead of this authoritative read in the real storage lane.
        final warm = await storage.pendingOutboxFrames();
        await messaging.dispose();
        await storage.close();
        final reopened = HiddenVolumeStorage.fromAsyncStore(
          (await open(password: password, create: false))!,
        );
        try {
          final durable = await reopened.pendingOutboxFrames();
          final evidence = Platform.environment['REPLICATION_CAP_EVIDENCE'];
          if (evidence != null) {
            await File(evidence).writeAsString(
              jsonEncode({
                'schema': 'xveil-replication-cap-retention/1',
                'expectedFrames': expected.length,
                'warmFrames': warm.length,
                'reopenedFrames': durable.length,
                'automaticPurgeStarted': messaging.automaticTrim != null,
              }),
            );
          }
          expect(durable.map((f) => f.frameId), unorderedEquals(expected.keys));
          expect(warm.map((f) => f.frameId), unorderedEquals(expected.keys));
          for (final frame in durable) {
            expect(frame.peerHex, peer.hex);
            expect(frame.wire, expected[frame.frameId]);
          }
          expect(messaging.automaticTrim, isNull);
        } finally {
          await reopened.close();
        }
        final evidence = Platform.environment['REPLICATION_CAP_EVIDENCE'];
        if (evidence != null) {
          await File(evidence).writeAsString(
            jsonEncode({
              'schema': 'xveil-replication-cap-retention/1',
              'replicationFrames': 256,
              'eventFrames': 1,
              'warmAndReopenedIdsPeersBytesMatch': true,
              'automaticPurgeStarted': false,
            }),
          );
        }
      } finally {
        if (messaging.automaticTrim != null) await messaging.automaticTrim;
        await messaging.dispose();
        await storage.close();
        await link.dispose();
        await dir.delete(recursive: true);
      }
    },
    skip: Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty == true
        ? false
        : 'set verified native library',
  );
}
