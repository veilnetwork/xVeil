// A LIVE check of the one link no unit test can reach: that a node told to
// listen on the LAN actually binds beyond loopback, and one told not to does
// not. The all-online boot dropped `lanListen` for seven weeks (0.13.45), and
// every green suite in this repository stayed green throughout — because they
// all stop at the Dart boundary. This one asks the operating system.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/veil_stack.dart';

import 'e2e_env.dart';

/// The two dylibs this needs. No `veil-cli`: nothing here dials anybody, so a
/// relay island would only add a build to the gate.
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
        : 'live bind check is gated: set ${missing.join(' + ')} to the debug '
              'dylibs (see test/e2e/README.md)',
  );
}

/// What the OS says is bound on [port], as `lsof` address strings. Empty when
/// nothing holds it. Asks about THIS process only: the suite may share the
/// machine with the developer's own node.
Future<List<String>> boundAddresses(int port) async {
  // `-a` is load-bearing: without it lsof ORs `-p` with `-i` and answers with
  // every file the process holds, which reads as a pile of addresses that are
  // not addresses at all.
  final r = await Process.run('lsof', [
    '-nP',
    '-a',
    '-p',
    '$pid',
    '-i',
    ':$port',
  ]);
  final out = <String>[];
  for (final line in (r.stdout as String).split('\n').skip(1)) {
    if (line.trim().isEmpty) continue;
    final parts = line.split(RegExp(r'\s+'));
    // NAME is the last column: `*:9101` or `127.0.0.1:9101`.
    out.add(parts.last);
  }
  return out;
}

void main() {
  final gate = _gate();

  Future<RealVeilStack> boot(String dir, int port, {required bool lan}) async {
    await Directory('$dir/runtime').create(recursive: true);
    final storage = HiddenVolumeStorage.async(workerSpaceOpener('$dir/store.hv'));
    expect(
      await storage.open(password: 'live-bind-probe', createIfMissing: true),
      isTrue,
      reason: 'the probe could not create its own container',
    );
    return RealVeilStack.startDeniable(
      storage: storage,
      runtimeDirBase: '$dir/runtime',
      lib: DynamicLibrary.open(gate.veil!),
      listenPort: port,
      debugMetricsPort: await freePort(),
      lanListen: lan,
      // Never the shared seeds from a test.
      useBundledSeeds: false,
    );
  }

  test(
    'lanListen decides whether the node can be reached from another machine',
    () async {
      final root = await Directory.systemTemp.createTemp('xveil-bind-');
      addTearDown(() => root.delete(recursive: true).catchError((_) => root));

      final openPort = await freePort();
      final open = await boot('${root.path}/open', openPort, lan: true);
      addTearDown(open.dispose);
      final openBound = await boundAddresses(openPort);
      printOnFailure('lanListen: true  -> $openBound');
      // ignore: avoid_print
      print('LIVE lanListen=true  port=$openPort bound=$openBound');
      expect(
        openBound,
        isNotEmpty,
        reason: 'the node reported it was up but holds no socket on $openPort',
      );
      expect(
        openBound.every((a) => a.startsWith('*:')),
        isTrue,
        reason:
            'the node was told to listen on the LAN and bound $openBound — a '
            'contact on another machine cannot reach that',
      );

      // The CONTROL, and the reason this test can fail: the same probe on a
      // node told to stay home must see loopback. Without it, an `lsof` that
      // silently reported nothing would pass the assertion above by vacuity.
      final homePort = await freePort();
      final home = await boot('${root.path}/home', homePort, lan: false);
      addTearDown(home.dispose);
      final homeBound = await boundAddresses(homePort);
      printOnFailure('lanListen: false -> $homeBound');
      // ignore: avoid_print
      print('LIVE lanListen=false port=$homePort bound=$homeBound');
      expect(
        homeBound,
        isNotEmpty,
        reason: 'the probe sees no socket at all, so it proves nothing above',
      );
      expect(
        homeBound.every((a) => a.startsWith('127.0.0.1:')),
        isTrue,
        reason: 'a node told to stay on loopback bound $homeBound',
      );
    },
    // Each boot mines this probe's own identity — about two minutes on an
    // M-series laptop, and there are two of them.
    timeout: const Timeout(Duration(minutes: 15)),
    skip: gate.skip,
  );
}
