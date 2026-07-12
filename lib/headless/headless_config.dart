import 'dart:convert';
import 'dart:io';

import '../data/node/embedded_node.dart' show BootstrapPeerCfg;

/// Public, non-secret daemon configuration. Passwords, recovery phrases and
/// bearer tokens deliberately do not belong here: they are supplied through a
/// protected file/stdin and persisted only in the deniable store.
class HeadlessConfig {
  const HeadlessConfig({
    required this.storePath,
    required this.runtimeDir,
    required this.blobDir,
    required this.listenPort,
    required this.apiPort,
    required this.anonymous,
    required this.bootstrapPeers,
    this.obfs4PskFile,
  });

  final String storePath;
  final String runtimeDir;
  final String blobDir;
  final int listenPort;
  final int apiPort;
  final bool anonymous;
  final List<BootstrapPeerCfg> bootstrapPeers;
  final String? obfs4PskFile;

  static Future<HeadlessConfig> load(
    String path, {
    Map<String, String>? environment,
  }) async {
    final env = environment ?? Platform.environment;
    final decoded = jsonDecode(await File(path).readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('headless config must be a JSON object');
    }
    for (final secret in const ['password', 'identity_phrase', 'api_token']) {
      if (decoded.containsKey(secret)) {
        throw FormatException(
          '$secret is secret and must be supplied through a protected file',
        );
      }
    }

    String text(String envKey, String jsonKey, {String? fallback}) {
      final fromEnv = env[envKey];
      final value = fromEnv != null && fromEnv.isNotEmpty
          ? fromEnv
          : decoded[jsonKey] ?? fallback;
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$jsonKey is required');
      }
      return value.trim();
    }

    int number(String envKey, String jsonKey, int fallback) {
      final raw = env[envKey] ?? decoded[jsonKey] ?? fallback;
      final value = raw is int ? raw : int.tryParse('$raw');
      if (value == null || value < 1 || value > 65535) {
        throw FormatException('$jsonKey must be a TCP port (1..65535)');
      }
      return value;
    }

    bool flag(String envKey, String jsonKey, bool fallback) {
      final raw = env[envKey] ?? decoded[jsonKey] ?? fallback;
      if (raw is bool) return raw;
      return switch ('$raw'.toLowerCase()) {
        '1' || 'true' || 'yes' || 'on' => true,
        '0' || 'false' || 'no' || 'off' => false,
        _ => throw FormatException('$jsonKey must be boolean'),
      };
    }

    final peersRaw = decoded['bootstrap_peers'] ?? const <dynamic>[];
    if (peersRaw is! List) {
      throw const FormatException('bootstrap_peers must be an array');
    }
    final psk = env['XVEIL_OBFS4_PSK_FILE'] ?? decoded['obfs4_psk_file'];
    if (psk != null && psk is! String) {
      throw const FormatException('obfs4_psk_file must be a path');
    }
    return HeadlessConfig(
      storePath: File(text('XVEIL_STORE', 'store')).absolute.path,
      runtimeDir: Directory(
        text('XVEIL_RUNTIME_DIR', 'runtime_dir'),
      ).absolute.path,
      blobDir: Directory(text('XVEIL_BLOB_DIR', 'blob_dir')).absolute.path,
      listenPort: number('XVEIL_LISTEN_PORT', 'listen_port', 9000),
      apiPort: number('XVEIL_API_PORT', 'api_port', 8787),
      anonymous: flag('XVEIL_ANONYMOUS', 'anonymous', true),
      bootstrapPeers: BootstrapPeerCfg.listFromJson(peersRaw),
      obfs4PskFile: psk is String && psk.trim().isNotEmpty
          ? File(psk.trim()).absolute.path
          : null,
    );
  }

  static const example = <String, Object>{
    'store': '/var/lib/xveil/xveil.hv',
    'runtime_dir': '/run/xveil',
    'blob_dir': '/var/lib/xveil/blobs',
    'listen_port': 9000,
    'api_port': 8787,
    'anonymous': true,
    'obfs4_psk_file': '/etc/xveil/obfs4_psk.b64',
    'bootstrap_peers': <Object>[],
  };
}
