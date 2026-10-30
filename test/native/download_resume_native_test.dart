import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

/// The holder is offline; persistence is real, and no network is contacted.
class _OfflineTransport extends LoopbackTransport {
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
}

void main() {
  test(
    'a refused destination retains its intent across a real container reopen',
    () async {
      expect(ensureHiddenVolumeLoaded(), true);
      final dir = await Directory.systemTemp.createTemp('xveil-sink-registry-');
      HiddenVolumeStorage openStorage() => HiddenVolumeStorage(
        hvSpaceOpener('${dir.path}/store.hv', argon: hv.ArgonPreset.min),
      );
      final transport = _OfflineTransport();
      var storage = openStorage();
      MessagingService? service;
      final contentId = '42' * 32;
      final peer = NodeId(Uint8List(32)..fillRange(0, 32, 0xbb));
      try {
        expect(
          await storage.open(password: 'fixture', createIfMissing: true),
          true,
        );
        await storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
        service = MessagingService(transport, storage, plainFileStream: true);
        expect(
          await service.downloadContentToFile(
            peer,
            contentId,
            '${dir.path}/saved.bin',
            write: (_, _) async {},
            close: () async {},
          ),
          ContentDownloadResult.requestedReoffer,
        );
        await service.dispose();
        await storage.close();
        storage = openStorage();
        expect(await storage.open(password: 'fixture'), true);
        final refused = Completer<void>();
        service = MessagingService(transport, storage, plainFileStream: true)
          ..downloadResumeStartDelay = Duration.zero
          ..plainFileSinkOpener = (_, {bool resume = false}) async {
            refused.complete();
            return null;
          };
        service.start();
        await refused.future.timeout(const Duration(seconds: 10));
        await Future<void>.delayed(Duration.zero);
        await service.dispose();
        await storage.close();
        storage = openStorage();
        expect(await storage.open(password: 'fixture'), true);
        service = MessagingService(transport, storage, plainFileStream: true);
        expect(await service.pendingAutoResumeContentIds(), [contentId]);
        await service.cancelContentDownload(contentId);
        await service.dispose();
        await storage.close();
        storage = openStorage();
        expect(await storage.open(password: 'fixture'), true);
        service = MessagingService(transport, storage, plainFileStream: true);
        expect(await service.pendingAutoResumeContentIds(), isEmpty);
      } finally {
        await service?.dispose();
        if (storage.isOpen) await storage.close();
        await transport.dispose();
        await dir.delete(recursive: true);
      }
    },
    skip: Platform.environment['XVEIL_NATIVE_DOWNLOAD_RESUME'] != '1',
  );

  test(
    'all requested downloads survive a real container reopen',
    () async {
      expect(ensureHiddenVolumeLoaded(), true);
      final dir = await Directory.systemTemp.createTemp(
        'xveil-download-resume-',
      );
      final transport = _OfflineTransport();
      HiddenVolumeStorage storage() => HiddenVolumeStorage(
        hvSpaceOpener('${dir.path}/store.hv', argon: hv.ArgonPreset.min),
      );
      final s = storage();
      MessagingService? service;
      HiddenVolumeStorage? reopened;
      final evidence = Platform.environment['XVEIL_DOWNLOAD_RESUME_EVIDENCE'];
      try {
        expect(await s.open(password: 'fixture', createIfMissing: true), true);
        final peer = NodeId(Uint8List(32)..fillRange(0, 32, 0xbb));
        await s.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
        service = MessagingService(transport, s, plainFileStream: true)
          ..start();
        final requested = List.generate(
          24,
          (i) => i.toRadixString(16).padLeft(64, '0'),
        );
        for (final cid in requested) {
          expect(
            await service.downloadContent(peer, cid),
            ContentDownloadResult.requestedReoffer,
          );
        }
        await service.dispose();
        service = null;
        await s.close();
        reopened = storage();
        expect(await reopened.open(password: 'fixture'), true);
        service = MessagingService(transport, reopened, plainFileStream: true);
        final recovered = await service.pendingAutoResumeContentIds();
        expect(recovered, unorderedEquals(requested));
        await service.cancelContentDownload(requested.first);
        await service.dispose();
        service = null;
        await reopened.close();
        reopened = storage();
        expect(await reopened.open(password: 'fixture'), true);
        service = MessagingService(transport, reopened, plainFileStream: true);
        final afterCancel = await service.pendingAutoResumeContentIds();
        expect(afterCancel, unorderedEquals(requested.skip(1)));
        if (evidence != null) {
          await File('$evidence/result.json').writeAsString(
            jsonEncode({
              'requested_downloads': requested.length,
              'recovered_downloads': recovered.length,
              'all_recovered': recovered.toSet().containsAll(requested),
              'cancelled_record_absent_after_another_reopen': !afterCancel
                  .contains(requested.first),
              'real_container_reopened': true,
              'network_used': false,
            }),
          );
        }
      } finally {
        await service?.dispose();
        await reopened?.close();
        if (s.isOpen) await s.close();
        await transport.dispose();
        await dir.delete(recursive: true);
      }
    },
    skip: Platform.environment['XVEIL_NATIVE_DOWNLOAD_RESUME'] != '1',
  );
}
