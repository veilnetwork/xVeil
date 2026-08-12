import 'dart:convert';
import 'dart:io';

import '../data/node/embedded_node.dart' show BootstrapPeerCfg, EmbeddedNode;

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
    this.udpReflectors = const [],
    this.obfs4PskFile,
    this.useBundledSeeds,
  });

  final String storePath;
  final String runtimeDir;
  final String blobDir;
  final int listenPort;
  final int apiPort;
  final bool anonymous;
  final List<BootstrapPeerCfg> bootstrapPeers;
  final List<String> udpReflectors;
  final String? obfs4PskFile;

  /// Whether this daemon may reach the network through the SHARED seed nodes —
  /// and NULL when the config file did not say, which is not the same as "no"
  /// and not the same as "yes".
  ///
  /// Three states because a daemon has three honest sources, in this order:
  ///
  ///   * this key, when it is present. A daemon composes its node from a file;
  ///     that file is where its operator states things, and a stated value that
  ///     the process quietly ignored would be worse than no key at all;
  ///   * the identity's own space, when the key is absent. A container that was
  ///     onboarded in the app carries the answer the person actually gave
  ///     (`network.bundled_seeds.v1`), and a daemon opening it must not undo a
  ///     refusal just by starting up;
  ///   * `kBundledSeedsDefault` when neither says anything — the same
  ///     historical yes the app falls back to, so a fresh daemon store finds
  ///     the network with nothing configured.
  ///
  /// There is deliberately NO fourth source. The app's per-profile preference
  /// (`bundled_seeds_prefs.dart`) is a `package:shared_preferences` file that
  /// belongs to an app profile the daemon does not have, cannot create, and
  /// could not read without dragging `dart:ui` into an AOT binary — which is
  /// exactly what stopped this daemon building at all in 709f3b9. "No answer
  /// here" is the truth for a headless node, not a gap to be papered over.
  final bool? useBundledSeeds;

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

    bool parseFlag(Object raw, String jsonKey) {
      if (raw is bool) return raw;
      return switch ('$raw'.toLowerCase()) {
        '1' || 'true' || 'yes' || 'on' => true,
        '0' || 'false' || 'no' || 'off' => false,
        _ => throw FormatException('$jsonKey must be boolean'),
      };
    }

    bool flag(String envKey, String jsonKey, bool fallback) =>
        parseFlag(env[envKey] ?? decoded[jsonKey] ?? fallback, jsonKey);

    /// A flag with THREE states: said yes, said no, said nothing.
    ///
    /// Not `flag(..., fallback)`, because a default would erase the difference
    /// between an operator who wrote `false` and one who wrote nothing — and
    /// for the shared seeds those mean different things: the first is a
    /// refusal, the second hands the question to the identity's own space
    /// ([HeadlessConfig.useBundledSeeds]). An empty environment variable is
    /// "unset", the same reading [text] gives it, so exporting an empty string
    /// cannot silently mean "off".
    bool? optionalFlag(String envKey, String jsonKey) {
      final fromEnv = env[envKey];
      final raw = fromEnv != null && fromEnv.trim().isNotEmpty
          ? fromEnv.trim()
          : decoded[jsonKey];
      if (raw == null) return null;
      return parseFlag(raw as Object, jsonKey);
    }

    final peersRaw = decoded['bootstrap_peers'] ?? const <dynamic>[];
    if (peersRaw is! List) {
      throw const FormatException('bootstrap_peers must be an array');
    }
    final psk = env['XVEIL_OBFS4_PSK_FILE'] ?? decoded['obfs4_psk_file'];
    if (psk != null && psk is! String) {
      throw const FormatException('obfs4_psk_file must be a path');
    }
    final reflectorsRaw = env['XVEIL_UDP_REFLECTORS'] != null
        ? env['XVEIL_UDP_REFLECTORS']!.split(',')
        : decoded['udp_reflectors'] ?? const <dynamic>[];
    if (reflectorsRaw is! List || reflectorsRaw.any((e) => e is! String)) {
      throw const FormatException('udp_reflectors must be an array of strings');
    }
    final reflectorStrings = reflectorsRaw.cast<String>();
    final udpReflectors = EmbeddedNode.normalizeUdpReflectors(reflectorStrings);
    if (reflectorStrings.any(
      (e) => EmbeddedNode.normalizeUdpReflectors([e]).isEmpty,
    )) {
      throw const FormatException(
        'udp_reflectors must contain numeric IP:port endpoints',
      );
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
      udpReflectors: udpReflectors,
      obfs4PskFile: psk is String && psk.trim().isNotEmpty
          ? File(psk.trim()).absolute.path
          : null,
      useBundledSeeds: optionalFlag(
        'XVEIL_USE_BUNDLED_SEEDS',
        'use_bundled_seeds',
      ),
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
    // Absent from a written config means "let the store decide" — see
    // [useBundledSeeds]. Spelled out in the example because the alternative is
    // learning that a daemon dials operator-run seed nodes by reading its
    // traffic.
    'use_bundled_seeds': true,
    'bootstrap_peers': <Object>[],
  };
}
