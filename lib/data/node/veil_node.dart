import 'dart:io';

import 'process_launcher.dart';
import 'subprocess_node_controller.dart';

/// Args to run a veil node in the foreground against [configPath].
List<String> veilNodeRunArgs(String configPath) => [
      '-c',
      configPath,
      'node',
      'run',
      '--foreground',
    ];

/// Readiness probe: the app IPC unix socket exists and accepts a connection.
Future<bool> Function() veilSocketProbe(String appSocketPath) {
  return () async {
    if (!await File(appSocketPath).exists()) return false;
    try {
      final s = await Socket.connect(
        InternetAddress(appSocketPath, type: InternetAddressType.unix),
        0,
      ).timeout(const Duration(seconds: 1));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  };
}

/// SubprocessNodeController that runs `veil-cli node run` against an existing
/// (already initialised, ipc-enabled) config, reporting connected once the app
/// socket answers.
SubprocessNodeController veilSubprocessController({
  required String veilCliPath,
  required String configPath,
  required String appSocketPath,
  ProcessLauncher launcher = const IoProcessLauncher(),
}) {
  return SubprocessNodeController(
    executable: veilCliPath,
    args: veilNodeRunArgs(configPath),
    readinessProbe: veilSocketProbe(appSocketPath),
    launcher: launcher,
  );
}

/// Ensures a runnable veil config exists at [configPath] and that its app IPC
/// socket is enabled; returns the app socket path. On first run this MINES a
/// fresh identity (>=24-bit PoW — can take minutes), so call it from the
/// identity-creation flow, not on every launch. Idempotent thereafter.
Future<String> ensureVeilConfig({
  required String veilCliPath,
  required String configPath,
  String? appSocketPath,
}) async {
  final socket =
      appSocketPath ?? '${File(configPath).parent.path}/app.sock';
  if (!await File(configPath).exists()) {
    final init =
        await Process.run(veilCliPath, ['config', 'init', configPath]);
    if (init.exitCode != 0) {
      throw StateError('veil config init failed: ${init.stderr}');
    }
  }
  // Enable the separate app IPC socket (admin socket is admin-only).
  await Process.run(
      veilCliPath, ['-c', configPath, 'config', 'set', 'ipc.enabled', 'true']);
  await Process.run(veilCliPath,
      ['-c', configPath, 'config', 'set', 'ipc.socket_uri', 'unix://$socket']);
  return socket;
}
