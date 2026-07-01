import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

/// Live published-circuit swarm test over a local onion mesh.
///
/// This is the "no human babysitting" regression for the flaky file path:
///
///   A sends a file offer to B;
///   B downloads and verifies the blob into app storage;
///   B's messaging layer is restarted, dropping live in-memory serve state;
///   C downloads the same contentId from B over a fresh anonymous stream.
///
/// Passing this proves that a completed receiver persists enough manifest/state
/// to become a durable seeder without relying on the original sender, live UI
/// state, or a phone unlock cycle.
///
/// Run via:
///
///   ONION_STREAM_LIVE_TEST=swarm \
///   ONION_STREAM_LIVE_NODE_MODE=embedded-endpoints \
///   scripts/onion-stream-local-live.sh

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Future<HiddenVolumeStorage> _openTestStorage(
  String name,
  List<Directory> blobDirs,
) async {
  final storage = HiddenVolumeStorage(_memOpener());
  final dir = await Directory.systemTemp.createTemp('xveil-onion-swarm-$name-');
  blobDirs.add(dir);
  // Keep the metadata/event log in the in-memory fake, but route blob pieces to
  // the production encrypted on-disk tier. Large live tests should measure the
  // onion stream and seeding behaviour, not FakeKvLogStore heap pressure.
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

Uint8List _payloadRange(int offset, int length, {required int seed}) {
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
  required int seed,
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

bool _envBool(String name, {required bool fallback}) {
  final raw = Platform.environment[name]?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) return fallback;
  switch (raw) {
    case '1':
    case 'true':
    case 'yes':
    case 'on':
      return true;
    case '0':
    case 'false':
    case 'no':
    case 'off':
      return false;
  }
  return fallback;
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
      stderr.writeln('[onion-swarm-live] $name active peers: $lastActive');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException('$name active peers $lastActive/$minActive', timeout);
}

Future<void> _warmupMessagePath({
  required String label,
  required MessagingService from,
  required NodeId fromId,
  required NodeId toId,
  required HiddenVolumeStorage recipientStorage,
  required Duration timeout,
}) async {
  final text =
      'warmup-$label-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
  stderr.writeln('[onion-swarm-live] warmup $label');
  await from.sendText(toId, text);
  final ok = await _until(() async {
    final messages = await recipientStorage.loadMessages(fromId.hex);
    return messages.any((m) => m.body == text);
  }, timeout: timeout);
  if (!ok) {
    throw TimeoutException('warmup $label did not arrive', timeout);
  }
}

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final cfgA = Platform.environment['XVEIL_EMBED_CONFIG_A'];
  final cfgB = Platform.environment['XVEIL_EMBED_CONFIG_B'];
  final cfgC = Platform.environment['XVEIL_EMBED_CONFIG_C'];
  final sockA = Platform.environment['XVEIL_TEST_SOCK_A'];
  final sockB = Platform.environment['XVEIL_TEST_SOCK_B'];
  final sockC = Platform.environment['XVEIL_TEST_SOCK_C'];
  final circuitMode = Platform.environment['VEIL_ONION_STREAM_CIRCUIT'];
  final finalPuller = (Platform.environment['XVEIL_SWARM_FINAL_PULLER'] ?? 'C')
      .trim()
      .toUpperCase();
  final finalPullerIsA = finalPuller == 'A';
  final finalPullerIsC = finalPuller == 'C';
  final useThirdPeer = finalPullerIsC;
  final size =
      int.tryParse(Platform.environment['XVEIL_TEST_FILE_SIZE'] ?? '') ??
      8 * 1024 * 1024;
  final rounds = max(1, _envInt('XVEIL_TEST_FILE_ROUNDS', 1));
  final minMiBPerSec = double.tryParse(
    Platform.environment['XVEIL_TEST_MIN_MIB_PER_SEC'] ?? '',
  );
  final restartSeeder = _envBool('XVEIL_SWARM_RESTART_SEEDER', fallback: true);
  final warmupSeconds = _envInt('XVEIL_EMBED_WARMUP_SECONDS', 12).clamp(0, 300);
  final minActivePeers = _envInt('XVEIL_EMBED_MIN_ACTIVE_PEERS', 2);
  final stageTimeout = Duration(
    seconds: _envInt('XVEIL_TEST_STAGE_TIMEOUT_SECONDS', 90).clamp(10, 600),
  );
  final skip =
      (dylib == null ||
          dylib.isEmpty ||
          sockA == null ||
          sockA.isEmpty ||
          sockB == null ||
          sockB.isEmpty ||
          (useThirdPeer && (sockC == null || sockC.isEmpty)))
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_A/B'
            '${useThirdPeer ? '/C' : ''}'
      : (!finalPullerIsA && !finalPullerIsC)
      ? 'XVEIL_SWARM_FINAL_PULLER must be A or C'
      : (!_publishedCircuitEnabled(circuitMode)
            ? 'set VEIL_ONION_STREAM_CIRCUIT=published to test the pinned circuit'
            : false);

  test(
    'A -> B -> restarted B -> $finalPuller completes intact over published onion streams',
    () async {
      final lib = DynamicLibrary.open(dylib!);
      expect(size, greaterThan(0));

      final embedA = cfgA != null && cfgA.isNotEmpty;
      final embedB = cfgB != null && cfgB.isNotEmpty;
      final embedC = useThirdPeer && cfgC != null && cfgC.isNotEmpty;
      final hasEmbeddedEndpoint = embedA || embedB || embedC;
      EmbeddedNodeController? controllerA;
      EmbeddedNodeController? controllerB;
      EmbeddedNodeController? controllerC;
      if (hasEmbeddedEndpoint) {
        if (embedA) {
          controllerA = EmbeddedNodeController(
            configPath: cfgA,
            appSocketPath: sockA!,
            lib: lib,
            readinessTimeout: const Duration(seconds: 60),
          );
        }
        if (embedB) {
          controllerB = EmbeddedNodeController(
            configPath: cfgB,
            appSocketPath: sockB!,
            lib: lib,
            readinessTimeout: const Duration(seconds: 60),
          );
        }
        if (embedC) {
          controllerC = EmbeddedNodeController(
            configPath: cfgC,
            appSocketPath: sockC!,
            lib: lib,
            readinessTimeout: const Duration(seconds: 60),
          );
        }
        addTearDown(() async {
          stderr.writeln('[onion-swarm-live] teardown: embedded controllers');
          await controllerA?.dispose();
          await controllerB?.dispose();
          await controllerC?.dispose();
        });
        stderr.writeln(
          '[onion-swarm-live] starting embedded endpoints '
          'cfgA=$cfgA cfgB=$cfgB cfgC=$cfgC',
        );
        // Start embedded runtimes sequentially. The macOS Flutter tester is
        // fragile while several in-process native runtimes are booting and
        // writing startup diagnostics at the same time; serialising startup
        // keeps this live test focused on onion-stream behaviour instead of the
        // test protocol's stdout/event-sink edge cases.
        for (final endpoint in [
          if (controllerA != null) (name: 'A', controller: controllerA),
          if (controllerB != null) (name: 'B', controller: controllerB),
          if (controllerC != null) (name: 'C', controller: controllerC),
        ]) {
          await _startEmbeddedEndpoint(
            endpoint.name,
            endpoint.controller,
          ).timeout(const Duration(seconds: 60));
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        if (warmupSeconds > 0) {
          stderr.writeln(
            '[onion-swarm-live] endpoints connected; '
            'warming rendezvous for ${warmupSeconds}s',
          );
          await Future<void>.delayed(Duration(seconds: warmupSeconds));
        }
      }

      final tA = await VeilFlutterTransport.connect(sockA!);
      final tB = await VeilFlutterTransport.connect(sockB!);
      final tC = useThirdPeer
          ? await VeilFlutterTransport.connect(sockC!)
          : null;
      if (hasEmbeddedEndpoint) {
        await Future.wait([
          _waitForActivePeers('A', tA, minActive: minActivePeers),
          _waitForActivePeers('B', tB, minActive: minActivePeers),
          if (tC != null)
            _waitForActivePeers('C', tC, minActive: minActivePeers),
        ]).timeout(const Duration(seconds: 90));
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
      final sC = useThirdPeer ? await _openTestStorage('c', blobDirs) : null;
      final streamRangeParallelism = xveilConfiguredStreamRangeParallelism();
      final streamRangeTargetBytes = xveilConfiguredStreamRangeTargetBytes();
      stderr.writeln(
        '[onion-swarm-live] streamRangeParallelism='
        '${streamRangeParallelism ?? 'default'} '
        'streamRangeTargetBytes=${streamRangeTargetBytes ?? 'default'} '
        'rounds=$rounds restartSeeder=$restartSeeder '
        'stageTimeout=${stageTimeout.inSeconds}s',
      );

      MessagingService makeService(
        VeilFlutterTransport transport,
        HiddenVolumeStorage storage,
      ) => MessagingService(
        transport,
        storage,
        anonymous: true,
        contentPacing: Duration.zero,
        streamRangeParallelism: streamRangeParallelism,
        streamRangeTargetBytes: streamRangeTargetBytes,
      );

      final mA = makeService(tA, sA);
      var mB = makeService(tB, sB);
      final mC = tC == null || sC == null ? null : makeService(tC, sC);
      final progressSubs =
          <StreamSubscription<({String contentId, int done, int total})>>[];

      addTearDown(() async {
        for (final sub in progressSubs) {
          await sub.cancel();
        }
        await mA.dispose();
        await mB.dispose();
        await mC?.dispose();
        await tA.dispose();
        await tB.dispose();
        await tC?.dispose();
        await sA.close();
        await sB.close();
        await sC?.close();
      });

      final aId = await tA.nodeId();
      final bId = await tB.nodeId();
      final cId = tC == null ? null : await tC.nodeId();
      await sA.upsertContact(
        Contact(nodeId: bId, status: ContactStatus.accepted),
      );
      await sB.upsertContact(
        Contact(nodeId: aId, status: ContactStatus.accepted),
      );
      if (cId != null && sC != null) {
        await sB.upsertContact(
          Contact(nodeId: cId, status: ContactStatus.accepted),
        );
        await sC.upsertContact(
          Contact(nodeId: bId, status: ContactStatus.accepted),
        );
      }
      await mB.setFileDownloadPolicy(
        mB.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );
      await mC?.setFileDownloadPolicy(
        mC.fileDownloadPolicy.copyWith(autoMaxBytes: 0),
      );
      mA.start();
      mB.start();
      mC?.start();

      await _warmupMessagePath(
        label: 'A-to-B',
        from: mA,
        fromId: aId,
        toId: bId,
        recipientStorage: sB,
        timeout: stageTimeout,
      );

      var totalBytes = 0;
      var totalMicros = 0;
      for (var round = 0; round < rounds; round++) {
        final seed = round + 1;
        final name = 'onion-swarm-$round-$size.bin';
        final cid = await mA.sendFileStreaming(bId, name, size, (
          offset,
          length,
        ) async {
          final end = min(offset + length, size);
          return _payloadRange(offset, end - offset, seed: seed);
        }, close: () async {});
        expect(cid, isNotNull, reason: 'A should accept B as a file recipient');
        final contentId = cid!;
        stderr.writeln(
          '[onion-swarm-live] round ${round + 1}/$rounds '
          'content=${contentId.substring(0, 12)} size=${size}B',
        );

        expect(
          await _until(() async {
            final messages = await sB.loadMessages(aId.hex);
            return messages.any(
              (m) => m.fileContentId == contentId || m.fileId == contentId,
            );
          }, timeout: stageTimeout),
          isTrue,
          reason: 'B should receive the file offer over the anonymous path',
        );

        var bProgressEvents = 0;
        progressSubs.add(
          mB.contentProgress.where((e) => e.contentId == contentId).listen((e) {
            bProgressEvents++;
            stderr.writeln(
              '[onion-swarm-live] A->B progress ${e.done}/${e.total} '
              '(${(100 * e.done / e.total).toStringAsFixed(1)}%)',
            );
          }),
        );
        final completedB = mB.contentReceived.firstWhere(
          (e) => e.contentId == contentId,
        );
        final swAB = Stopwatch()..start();
        expect(
          await mB.downloadContent(aId, contentId),
          ContentDownloadResult.started,
        );
        await completedB.timeout(
          stageTimeout,
          onTimeout: () => throw TimeoutException(
            'B did not complete A->B content=$contentId',
            stageTimeout,
          ),
        );
        swAB.stop();

        await _expectStoredPayload(sB, contentId, size, seed: seed);
        stderr.writeln(
          '[onion-swarm-live] A->B complete '
          '${(size / max(swAB.elapsedMicroseconds, 1) * 1000000 / 1024 / 1024).toStringAsFixed(3)} MiB/s '
          '(progressEvents=$bProgressEvents)',
        );

        if (restartSeeder) {
          if (finalPullerIsA) {
            stderr.writeln(
              '[onion-swarm-live] dropping B live serving state before A pull',
            );
            await mB.dropLiveServingStateForTest();
          } else {
            stderr.writeln(
              '[onion-swarm-live] restarting B messaging layer before '
              '$finalPuller pull',
            );
            await mB.dispose();
            // The old accept loop can be parked in acceptStream(timeout: 2s).
            // In a real process restart it disappears immediately; inside this
            // single test process, let that pending accept drain before the new
            // MessagingService starts competing for inbound streams.
            await Future<void>.delayed(const Duration(milliseconds: 2500));
            mB = makeService(tB, sB);
            mB.start();
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }

        if (useThirdPeer) {
          final puller = mC!;
          final pullerStorage = sC!;
          await _warmupMessagePath(
            label: 'B-to-C',
            from: mB,
            fromId: bId,
            toId: cId!,
            recipientStorage: pullerStorage,
            timeout: stageTimeout,
          );

          var cProgressEvents = 0;
          progressSubs.add(
            puller.contentProgress
                .where((e) => e.contentId == contentId)
                .listen((e) {
                  cProgressEvents++;
                  stderr.writeln(
                    '[onion-swarm-live] B->C progress ${e.done}/${e.total} '
                    '(${(100 * e.done / e.total).toStringAsFixed(1)}%)',
                  );
                }),
          );
          final completedC = puller.contentReceived.firstWhere(
            (e) => e.contentId == contentId,
          );
          final swBC = Stopwatch()..start();
          expect(
            await puller.downloadContent(bId, contentId),
            ContentDownloadResult.started,
          );
          await completedC.timeout(
            stageTimeout,
            onTimeout: () => throw TimeoutException(
              'C did not complete B->C content=$contentId',
              stageTimeout,
            ),
          );
          swBC.stop();

          await _expectStoredPayload(
            pullerStorage,
            contentId,
            size,
            seed: seed,
          );
          stderr.writeln(
            '[onion-swarm-live] B->C complete '
            '${(size / max(swBC.elapsedMicroseconds, 1) * 1000000 / 1024 / 1024).toStringAsFixed(3)} MiB/s '
            '(progressEvents=$cProgressEvents)',
          );

          totalBytes += size * 2;
          totalMicros += swAB.elapsedMicroseconds + swBC.elapsedMicroseconds;
        } else {
          await _warmupMessagePath(
            label: 'B-to-A',
            from: mB,
            fromId: bId,
            toId: aId,
            recipientStorage: sA,
            timeout: stageTimeout,
          );
          expect(
            await sA.hasFile(contentId),
            isFalse,
            reason: 'A must pull the blob from restarted B, not short-circuit',
          );

          var aProgressEvents = 0;
          progressSubs.add(
            mA.contentProgress.where((e) => e.contentId == contentId).listen((
              e,
            ) {
              aProgressEvents++;
              stderr.writeln(
                '[onion-swarm-live] B->A progress ${e.done}/${e.total} '
                '(${(100 * e.done / e.total).toStringAsFixed(1)}%)',
              );
            }),
          );
          final completedA = mA.contentReceived.firstWhere(
            (e) => e.contentId == contentId,
          );
          final swBA = Stopwatch()..start();
          expect(
            await mA.downloadContent(bId, contentId),
            ContentDownloadResult.started,
          );
          await completedA.timeout(
            stageTimeout,
            onTimeout: () => throw TimeoutException(
              'A did not complete B->A content=$contentId',
              stageTimeout,
            ),
          );
          swBA.stop();

          await _expectStoredPayload(sA, contentId, size, seed: seed);
          stderr.writeln(
            '[onion-swarm-live] B->A complete '
            '${(size / max(swBA.elapsedMicroseconds, 1) * 1000000 / 1024 / 1024).toStringAsFixed(3)} MiB/s '
            '(progressEvents=$aProgressEvents)',
          );

          totalBytes += size * 2;
          totalMicros += swAB.elapsedMicroseconds + swBA.elapsedMicroseconds;
        }
      }

      final seconds = max(totalMicros / 1000000.0, 0.001);
      final mibPerSec = totalBytes / seconds / 1024 / 1024;
      stderr.writeln(
        '[onion-swarm-live] completed swarm ${totalBytes}B transferred in '
        '${seconds.toStringAsFixed(3)}s = '
        '${mibPerSec.toStringAsFixed(3)} MiB/s',
      );
      if (minMiBPerSec != null) {
        expect(
          mibPerSec,
          greaterThanOrEqualTo(minMiBPerSec),
          reason:
              'published pinned-circuit swarm transfer below configured floor',
        );
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
