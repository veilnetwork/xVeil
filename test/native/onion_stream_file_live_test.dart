import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

/// Live pinned-circuit file transfer over a local onion mesh.
///
/// This is deliberately stronger than the normal synthetic stream tests:
///
///   * two real veil nodes act as app endpoints;
///   * both endpoints are anonymous receivers, because the file path is pull
///     based: B receives the offer, then opens an anonymous stream back to A;
///   * `VEIL_ONION_STREAM_CIRCUIT=published` is required so the test exercises
///     the pinned published-rendezvous circuit backend, not the fallback path;
///   * the app-level MessagingService/storage pipeline is used, matching the UI
///     path while staying headless.
///
/// Bring the mesh up with:
///
///   scripts/onion-stream-local-live.sh
///
/// Or manually:
///
///   VEIL_FFI_DYLIB=.../libveilclient_ffi.dylib \
///   VEIL_ONION_STREAM_CIRCUIT=published \
///   XVEIL_TEST_SOCK_A=.dev-onion-stream/a/app.sock \
///   XVEIL_TEST_SOCK_B=.dev-onion-stream/b/app.sock \
///   flutter test test/native/onion_stream_file_live_test.dart

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Uint8List _payload(int size) {
  final out = Uint8List(size);
  var x = 0x5eed1234;
  for (var i = 0; i < size; i++) {
    // Deterministic, cheap, and non-repeating enough to catch ordering/holes.
    x = (1664525 * x + 1013904223) & 0xffffffff;
    out[i] = (x >> 16) & 0xff;
  }
  return out;
}

Future<bool> _until(
  FutureOr<bool> Function() cond, {
  Duration timeout = const Duration(seconds: 90),
  Duration step = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return true;
    await Future<void>.delayed(step);
  }
  return await cond();
}

bool _publishedCircuitEnabled(String? value) {
  switch (value?.trim().toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'on':
    case 'published':
    case 'prod':
    case 'production':
      return true;
  }
  return false;
}

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final sockA = Platform.environment['XVEIL_TEST_SOCK_A'];
  final sockB = Platform.environment['XVEIL_TEST_SOCK_B'];
  final circuitMode = Platform.environment['VEIL_ONION_STREAM_CIRCUIT'];
  final size =
      int.tryParse(Platform.environment['XVEIL_TEST_FILE_SIZE'] ?? '') ??
      4 * 1024 * 1024;
  final minMiBPerSec = double.tryParse(
    Platform.environment['XVEIL_TEST_MIN_MIB_PER_SEC'] ?? '',
  );
  final skip =
      (dylib == null ||
          dylib.isEmpty ||
          sockA == null ||
          sockA.isEmpty ||
          sockB == null ||
          sockB.isEmpty)
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_A + XVEIL_TEST_SOCK_B'
      : (!_publishedCircuitEnabled(circuitMode)
            ? 'set VEIL_ONION_STREAM_CIRCUIT=published to test the pinned circuit'
            : false);

  test(
    'A -> B file completes intact over published pinned onion streams',
    () async {
      DynamicLibrary.open(dylib!); // preload native symbols for veil_flutter.
      expect(size, greaterThan(0));

      final tA = await VeilFlutterTransport.connect(sockA!);
      final tB = await VeilFlutterTransport.connect(sockB!);
      final sA = HiddenVolumeStorage(_memOpener());
      final sB = HiddenVolumeStorage(_memOpener());
      await sA.open(password: 'a', createIfMissing: true);
      await sB.open(password: 'b', createIfMissing: true);
      final streamRangeParallelism = xveilConfiguredStreamRangeParallelism();
      final streamRangeTargetBytes = xveilConfiguredStreamRangeTargetBytes();
      stderr.writeln(
        '[onion-file-live] streamRangeParallelism='
        '${streamRangeParallelism ?? 'default'} '
        'streamRangeTargetBytes=${streamRangeTargetBytes ?? 'default'}',
      );

      final mA = MessagingService(
        tA,
        sA,
        anonymous: true,
        contentPacing: Duration.zero,
        streamRangeParallelism: streamRangeParallelism,
        streamRangeTargetBytes: streamRangeTargetBytes,
      );
      final mB = MessagingService(
        tB,
        sB,
        anonymous: true,
        contentPacing: Duration.zero,
        streamRangeParallelism: streamRangeParallelism,
        streamRangeTargetBytes: streamRangeTargetBytes,
      );
      StreamSubscription<({String contentId, int done, int total})>?
      progressSub;

      addTearDown(() async {
        await progressSub?.cancel();
        await mA.dispose();
        await mB.dispose();
        await tA.dispose();
        await tB.dispose();
      });

      final aId = await tA.nodeId();
      final bId = await tB.nodeId();
      await sA.upsertContact(
        Contact(nodeId: bId, status: ContactStatus.accepted),
      );
      await sB.upsertContact(
        Contact(nodeId: aId, status: ContactStatus.accepted),
      );
      await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );
      mA.start();
      mB.start();

      final data = _payload(size);
      final cid = await mA.sendFileStreaming(
        bId,
        'onion-live-$size.bin',
        data.length,
        (offset, length) async {
          final end = min(offset + length, data.length);
          return Uint8List.sublistView(data, offset, end);
        },
        close: () async {},
      );
      expect(cid, isNotNull, reason: 'A should accept B as a file recipient');
      final contentId = cid!;

      expect(
        await _until(() async {
          final messages = await sB.loadMessages(aId.hex);
          return messages.any(
            (m) => m.fileContentId == contentId || m.fileId == contentId,
          );
        }),
        isTrue,
        reason: 'B should receive the file offer over the anonymous path',
      );

      var lastDone = 0;
      var progressEvents = 0;
      progressSub = mB.contentProgress
          .where((e) => e.contentId == contentId)
          .listen((e) {
            progressEvents++;
            lastDone = e.done;
            stderr.writeln(
              '[onion-file-live] progress ${e.done}/${e.total} '
              '(${(100 * e.done / e.total).toStringAsFixed(1)}%)',
            );
          });

      final completed = mB.contentReceived.firstWhere(
        (e) => e.contentId == contentId,
      );
      final sw = Stopwatch()..start();
      final result = await mB.downloadContent(aId, contentId);
      expect(result, ContentDownloadResult.started);
      await completed.timeout(const Duration(minutes: 5));
      sw.stop();

      final got = await sB.loadFile(contentId);
      expect(got, isNotNull);
      expect(got, data);

      final seconds = max(sw.elapsedMicroseconds / 1000000.0, 0.001);
      final mibPerSec = data.length / seconds / 1024 / 1024;
      stderr.writeln(
        '[onion-file-live] completed ${data.length}B in '
        '${seconds.toStringAsFixed(3)}s = '
        '${mibPerSec.toStringAsFixed(3)} MiB/s '
        '(progressEvents=$progressEvents lastDone=$lastDone)',
      );
      if (minMiBPerSec != null) {
        expect(
          mibPerSec,
          greaterThanOrEqualTo(minMiBPerSec),
          reason: 'published pinned-circuit transfer below configured floor',
        );
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
