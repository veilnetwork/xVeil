import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
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

Future<HiddenVolumeStorage> _openTestStorage(
  String name,
  List<Directory> blobDirs,
) async {
  final storage = HiddenVolumeStorage(_memOpener());
  final dir = await Directory.systemTemp.createTemp('xveil-onion-file-$name-');
  blobDirs.add(dir);
  // The live synthetic can use 128 MiB+ payloads. Keep FakeKvLogStore for the
  // small metadata/event log, but route blob pieces to the production encrypted
  // on-disk tier so the test measures the network, not harness heap size.
  storage.useOnDiskTier(dir, minBytes: 0);
  await storage.open(password: name, createIfMissing: true);
  return storage;
}

int _payloadByte(int offset, int seed) {
  // Deterministic random-access byte: cheap, non-repeating enough for ordering
  // checks, and computable for any range without materialising the whole file.
  var x = (offset ^ (0x5eed1234 + seed * 0x9e3779b9)) & 0xffffffff;
  x ^= x >> 16;
  x = (x * 0x7feb352d) & 0xffffffff;
  x ^= x >> 15;
  x = (x * 0x846ca68b) & 0xffffffff;
  x ^= x >> 16;
  return x & 0xff;
}

Uint8List _payloadRange(int offset, int length, {int seed = 1}) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _payloadByte(offset + i, seed);
  }
  return out;
}

Future<void> _expectStoredPayload(
  HiddenVolumeStorage storage,
  String contentId,
  int size, {
  int seed = 1,
}) async {
  expect(await storage.hasFile(contentId), isTrue);
  const step = 1024 * 1024;
  for (var offset = 0; offset < size; offset += step) {
    final length = min(step, size - offset);
    final got = await storage.readFileRange(contentId, offset, length);
    expect(got, isNotNull, reason: 'stored range @$offset+$length exists');
    expect(
      got,
      _payloadRange(offset, length, seed: seed),
      reason: 'stored range @$offset+$length matches source',
    );
  }
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

int _envInt(String name, int fallback) {
  final raw = Platform.environment[name];
  if (raw == null || raw.isEmpty) return fallback;
  final parsed = int.tryParse(raw);
  return parsed == null || parsed < 0 ? fallback : parsed;
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

Future<void> _startEmbeddedEndpoint(
  String name,
  EmbeddedNodeController controller,
) async {
  await controller.start();
  final status = controller.current;
  if (status.phase != NodePhase.connected) {
    throw StateError(
      '$name embedded node failed to start: '
      '${status.phase.name}${status.message == null ? '' : ' ${status.message}'}',
    );
  }
}

Future<void> _waitForActivePeers(
  String name,
  VeilFlutterTransport transport, {
  required int minActive,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  var lastActive = 0;
  while (DateTime.now().isBefore(deadline)) {
    final peers = await transport.peers();
    lastActive = peers.where((p) => p.isActive).length;
    if (lastActive >= minActive) {
      stderr.writeln('[onion-file-live] $name active peers: $lastActive');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException('$name active peers $lastActive/$minActive', timeout);
}

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final cfgA = Platform.environment['XVEIL_EMBED_CONFIG_A'];
  final cfgB = Platform.environment['XVEIL_EMBED_CONFIG_B'];
  final sockA = Platform.environment['XVEIL_TEST_SOCK_A'];
  final sockB = Platform.environment['XVEIL_TEST_SOCK_B'];
  final circuitMode = Platform.environment['VEIL_ONION_STREAM_CIRCUIT'];
  final size =
      int.tryParse(Platform.environment['XVEIL_TEST_FILE_SIZE'] ?? '') ??
      4 * 1024 * 1024;
  final minMiBPerSec = double.tryParse(
    Platform.environment['XVEIL_TEST_MIN_MIB_PER_SEC'] ?? '',
  );
  final warmupSeconds = _envInt('XVEIL_EMBED_WARMUP_SECONDS', 12).clamp(0, 300);
  final minActivePeers = _envInt('XVEIL_EMBED_MIN_ACTIVE_PEERS', 2);
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
      final lib = DynamicLibrary.open(
        dylib!,
      ); // preload native symbols for veil_flutter.
      expect(size, greaterThan(0));

      final embedded =
          cfgA != null && cfgA.isNotEmpty && cfgB != null && cfgB.isNotEmpty;
      EmbeddedNodeController? controllerA;
      EmbeddedNodeController? controllerB;
      if (embedded) {
        controllerA = EmbeddedNodeController(
          configPath: cfgA,
          appSocketPath: sockA!,
          lib: lib,
          readinessTimeout: const Duration(seconds: 60),
        );
        controllerB = EmbeddedNodeController(
          configPath: cfgB,
          appSocketPath: sockB!,
          lib: lib,
          readinessTimeout: const Duration(seconds: 60),
        );
        addTearDown(() async {
          stderr.writeln('[onion-file-live] teardown: embedded controllers');
          await controllerA?.dispose();
          await controllerB?.dispose();
        });
        stderr.writeln(
          '[onion-file-live] starting embedded endpoints '
          'cfgA=$cfgA cfgB=$cfgB',
        );
        await Future.wait([
          _startEmbeddedEndpoint('A', controllerA),
          _startEmbeddedEndpoint('B', controllerB),
        ]).timeout(const Duration(seconds: 75));
        if (warmupSeconds > 0) {
          stderr.writeln(
            '[onion-file-live] endpoints connected; '
            'warming rendezvous for ${warmupSeconds}s',
          );
          await Future<void>.delayed(Duration(seconds: warmupSeconds));
        }
      }

      final tA = await VeilFlutterTransport.connect(sockA!);
      final tB = await VeilFlutterTransport.connect(sockB!);
      if (embedded) {
        await Future.wait([
          _waitForActivePeers('A', tA, minActive: minActivePeers),
          _waitForActivePeers('B', tB, minActive: minActivePeers),
        ]).timeout(const Duration(seconds: 75));
      }
      final blobDirs = <Directory>[];
      addTearDown(() async {
        for (final dir in blobDirs.reversed) {
          if (await dir.exists()) {
            await dir.delete(recursive: true);
          }
        }
      });
      final sA = await _openTestStorage('a', blobDirs);
      final sB = await _openTestStorage('b', blobDirs);
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

      final cid = await mA.sendFileStreaming(
        bId,
        'onion-live-$size.bin',
        size,
        (offset, length) async {
          final end = min(offset + length, size);
          return _payloadRange(offset, end - offset);
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

      await _expectStoredPayload(sB, contentId, size);

      final seconds = max(sw.elapsedMicroseconds / 1000000.0, 0.001);
      final mibPerSec = size / seconds / 1024 / 1024;
      stderr.writeln(
        '[onion-file-live] completed ${size}B in '
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
