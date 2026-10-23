/// An OS process per device, with the application's authenticated debug API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xveil/data/node/embedded_node.dart';

import 'e2e_env.dart';
import 'relay_cluster.dart';

class ProcessDevice {
  ProcessDevice({required this.label, required this.dir, required this.peers});
  final String label;
  final Directory dir;
  final List<BootstrapPeerCfg> peers;
  Process? _process;
  Future<int>? _exit;
  IOSink? _log;
  Future<void>? _stdoutDone, _stderrDone;
  late int port;
  String? _key;
  final ownedPids = <int>[];
  String get logPath => '${dir.path}/worker.log';

  /// Drive the existing native admin socket of this owned worker. This stays
  /// in the fixture: partition tests need no extra application debug endpoint.
  Future<String> admin(String cli, List<String> command) async {
    final sockets = await Directory('${dir.path}/runtime')
        .list(recursive: true, followLinks: false)
        .where((entry) => entry.path.endsWith('/admin.sock'))
        .toList();
    if (sockets.length != 1) {
      throw StateError('$label must have exactly one live admin socket');
    }
    // The CLI loads a config to locate the socket, but never starts this
    // config. Use a public test identity, not material from the container.
    final fixture = await File(
      'test/e2e/fixtures/device_identity_x_master.toml',
    ).readAsString();
    final identity = RegExp(
      r'\[Identity\][\s\S]*?(?=\n\[|$)',
    ).firstMatch(fixture)!.group(0)!;
    final config = File('${dir.path}/admin-client.toml');
    await config.writeAsString(
      '[global]\nbuiltin_seed_policy = "never"\n'
      'admin_socket = ${jsonEncode('unix://${sockets.single.path}')}\n$identity\n',
    );
    final result = await Process.run(cli, ['-c', config.path, ...command]);
    if (result.exitCode != 0) {
      throw StateError('$label admin failed: ${result.stderr}');
    }
    return result.stdout as String;
  }

  Future<void> start() async {
    await dir.create(recursive: true);
    final stopMarker = File('${dir.path}/stop-worker');
    if (await stopMarker.exists()) await stopMarker.delete();
    final keyFile = File('${dir.path}/runtime/soak.key');
    if (await keyFile.exists()) await keyFile.delete();
    _key = null;
    port = await freePort();
    _log = File(logPath).openWrite(mode: FileMode.append);
    final process = await Process.start(
      'python3',
      [
        '-c',
        'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
        'flutter',
        'test',
        '--no-pub',
        '--dart-define=XVEIL_DEBUG_HOOK=true',
        '--dart-define=XVEIL_DEBUG_HOOK_PORT=$port',
        'test/e2e/device_process_worker_test.dart',
        '--reporter',
        'expanded',
      ],
      environment: {
        'TMPDIR': Platform.isMacOS
            ? '/private/tmp/'
            : Directory.systemTemp.path,
        'XVEIL_LOG_STDOUT': '1',
        'XVEIL_E2E_WORKER_LABEL': label,
        'XVEIL_E2E_WORKER_DIR': dir.path,
        'XVEIL_E2E_WORKER_PEERS': jsonEncode([
          for (final p in peers)
            {
              'transport': p.transport,
              'publicKey': p.publicKey,
              'nonce': p.nonce,
              'algo': p.algo,
            },
        ]),
      },
    );
    _process = process;
    ownedPids.add(process.pid);
    _exit = process.exitCode;
    _stdoutDone = process.stdout.transform(utf8.decoder).forEach(_log!.write);
    _stderrDone = process.stderr.transform(utf8.decoder).forEach(_log!.write);
    E2eLog.line('process $label started pid=${process.pid} api=$port');
    try {
      await waitUntil(
        () async {
          if (!await keyFile.exists()) return false;
          _key = (await keyFile.readAsString()).trim();
          return (await call('/health'))['ok'] == true;
        },
        what: 'process $label debug API to answer',
        describe: tail,
        timeout: const Duration(minutes: 2),
      );
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> call(
    String path, {
    Map<String, String> query = const {},
    String? body,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      return await (() async {
        final request = await client.postUrl(
          Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: port,
            path: path,
            queryParameters: query.isEmpty ? null : query,
          ),
        );
        request.headers.set('X-Soak-Key', _key ?? '');
        if (body != null) request.write(body);
        final response = await request.close();
        final value = jsonDecode(await response.transform(utf8.decoder).join());
        if (value is! Map<String, dynamic>) {
          throw StateError('$label $path returned non-object JSON');
        }
        return value;
      })().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> checked(
    String path, {
    Map<String, String> query = const {},
    String? body,
  }) async {
    final result = await call(path, query: query, body: body);
    if (result['ok'] != true) throw StateError('$label $path refused: $result');
    return result;
  }

  Future<String> tail() async {
    await _log?.flush();
    final text = await File(logPath).readAsString();
    return text.length > 5000 ? text.substring(text.length - 5000) : text;
  }

  Future<void> _killGroup(int signal) async {
    final process = _process;
    if (process == null) return;
    await Process.run('python3', [
      '-c',
      'import os,sys; p=int(sys.argv[1]); '
          'os.getpgid(p)==p and os.killpg(p,int(sys.argv[2]))',
      '${process.pid}',
      '$signal',
    ]);
  }

  Future<void> stop({bool crash = false}) async {
    if (_process == null) return;
    if (crash) {
      await _killGroup(ProcessSignal.sigkill.signalNumber);
    } else {
      await File('${dir.path}/stop-worker').writeAsString('stop');
    }
    try {
      await _exit!.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      await _killGroup(ProcessSignal.sigterm.signalNumber);
      try {
        await _exit!.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        await _killGroup(ProcessSignal.sigkill.signalNumber);
        await _exit;
      }
    }
    await Future.wait([_stdoutDone!, _stderrDone!]);
    await _log?.close();
    _log = null;
    _process = null;
    _key = null;
    E2eLog.line('process $label exited');
  }

  Future<void> restart() async {
    await stop();
    await start();
  }
}

class ProcessFleet {
  ProcessFleet._(this.root, this.cluster, this.devices);
  final Directory root;
  final RelayCluster cluster;
  final Map<String, ProcessDevice> devices;
  ProcessDevice get a => devices['A']!;
  ProcessDevice get b => devices['B']!;
  ProcessDevice get c => devices['C']!;

  static Future<ProcessFleet> start(E2eGate gate) async {
    final root = await e2eTempRoot('xveil-process-');
    final cluster = await RelayCluster.start(
      veilCliPath: gate.veilCli!,
      root: Directory('${root.path}/relays'),
    );
    final devices = <String, ProcessDevice>{};
    final fleet = ProcessFleet._(root, cluster, devices);
    try {
      for (final label in ['A', 'B', 'C']) {
        final d = ProcessDevice(
          label: label,
          dir: Directory('${root.path}/$label'),
          peers: cluster.bootstrapPeers,
        );
        devices[label] = d;
        await d.start();
      }
      return fleet;
    } catch (_) {
      await fleet.dispose();
      rethrow;
    }
  }

  Future<void> dispose() async {
    await teardownLegs('process fleet', [
      for (final d in devices.values) ('stop process ${d.label}', d.stop),
      ('stop relays', () => cluster.dispose(removeFiles: false)),
    ]);
    // Keep worker diagnostics out of git and preserve them before removing the
    // containers (which hold test keys). A unique destination per fleet.
    final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
    if (evidence != null) {
      final dest = Directory(
        '$evidence/${root.uri.pathSegments.where((p) => p.isNotEmpty).last}',
      );
      await dest.create(recursive: true);
      for (final d in devices.values) {
        final file = File(d.logPath);
        if (await file.exists()) await file.copy('${dest.path}/${d.label}.log');
      }
      await File('${dest.path}/owned-pids.json').writeAsString(
        jsonEncode({for (final d in devices.values) d.label: d.ownedPids}),
      );
    }
    if (await root.exists()) await root.delete(recursive: true);
  }
}
