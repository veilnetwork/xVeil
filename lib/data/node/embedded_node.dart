import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../native_libs.dart' show processLibFor;
import 'node_controller.dart';
import 'proxy_routing.dart';
import 'veil_node.dart' show veilSocketProbe;

/// The handle the embedded-node symbols resolve against. On Android they live
/// in the dlopen'd `libveilclient_ffi.so` (not the global scope), so we must
/// use that handle; on iOS/desktop they are process-global. See
/// [processLibFor].
DynamicLibrary _veilLib() => processLibFor('veilclient_ffi');

/// One `[[bootstrap_peers]]` entry — a known node the embedded node dials at
/// boot to join a network (seed set / testnet). Fields mirror veil's
/// `BootstrapPeer` (veil-types): [transport] e.g. `obfs4-tcp://host:port`,
/// [publicKey]/[nonce] base64, [algo] signature algorithm.
///
/// NOTE: these point the node at a specific network — treat them as
/// configuration, NOT secrets, but a testnet set is environment-specific and
/// must not be hardcoded into committed source (load from a local, gitignored
/// file via [BootstrapPeerCfg.listFromJson]).
class BootstrapPeerCfg {
  const BootstrapPeerCfg({
    required this.transport,
    required this.publicKey,
    required this.nonce,
    this.algo = 'ed25519',
  });

  final String transport;
  final String publicKey;
  final String nonce;
  final String algo;

  /// Parse a JSON array of `{transport, public_key, nonce, algo?}` objects
  /// (the shape mirrors the ansible inventory's `veil_bootstrap_peers`).
  static List<BootstrapPeerCfg> listFromJson(List<dynamic> json) => [
        for (final e in json)
          BootstrapPeerCfg(
            transport: (e as Map)['transport'] as String,
            publicKey: e['public_key'] as String,
            nonce: e['nonce'] as String,
            algo: (e['algo'] as String?) ?? 'ed25519',
          ),
      ];
}

// C ABI from veilclient-ffi (node-embedded feature):
//   char     *veil_config_init(uint32_t difficulty, char** err_out);
//   VeilNode *veil_node_start(const uint8_t*, size_t, char** err_out);
//   VeilNode *veil_node_start_deferred(const uint8_t*, size_t, bool anonymous, char** err_out);
//   int       veil_node_apply_config(const VeilNode*, const uint8_t*, size_t, char** err_out);
//   void      veil_node_stop(VeilNode*);
//   void      veil_free_string(char*);
typedef _StartNative = Pointer<Void> Function(
    Pointer<Uint8>, IntPtr, Pointer<Pointer<Utf8>>);
typedef _StartDart = Pointer<Void> Function(
    Pointer<Uint8>, int, Pointer<Pointer<Utf8>>);
// Deferred boot carries an extra `bool anonymous` (arms onion at boot).
typedef _StartDeferredNative = Pointer<Void> Function(
    Pointer<Uint8>, IntPtr, Bool, Pointer<Pointer<Utf8>>);
typedef _StartDeferredDart = Pointer<Void> Function(
    Pointer<Uint8>, int, bool, Pointer<Pointer<Utf8>>);
typedef _StopNative = Void Function(Pointer<Void>);
typedef _StopDart = void Function(Pointer<Void>);
typedef _FreeStrNative = Void Function(Pointer<Utf8>);
typedef _FreeStrDart = void Function(Pointer<Utf8>);
typedef _ConfigInitNative = Pointer<Utf8> Function(
    Uint32, Pointer<Pointer<Utf8>>);
typedef _ConfigInitDart = Pointer<Utf8> Function(
    int, Pointer<Pointer<Utf8>>);
typedef _ComposeNative = Pointer<Utf8> Function(
    Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr,
    Pointer<Uint8>, IntPtr, Pointer<Pointer<Utf8>>);
typedef _ComposeDart = Pointer<Utf8> Function(
    Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>, int,
    Pointer<Uint8>, int, Pointer<Pointer<Utf8>>);
typedef _ApplyConfigNative = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, IntPtr, Pointer<Pointer<Utf8>>);
typedef _ApplyConfigDart = int Function(
    Pointer<Void>, Pointer<Uint8>, int, Pointer<Pointer<Utf8>>);

/// True when the loaded veil dylib exposes the embedded-node FFI (i.e. it was
/// built `--features node-embedded`). Lets the app pick the in-process deniable
/// boot path only when the symbols are actually present.
bool embeddedNodeAvailable({DynamicLibrary? lib}) {
  final dl = lib ?? _veilLib();
  try {
    dl.lookup<NativeFunction<_ConfigInitNative>>('veil_config_init');
    return true;
  } catch (_) {
    return false;
  }
}

/// A veil node running IN-PROCESS via the embedded-node FFI (no subprocess).
/// Requires a dylib built with `--features node-embedded` to be loaded.
class EmbeddedNode {
  EmbeddedNode._(this._handle, this._dl);

  final Pointer<Void> _handle;
  final DynamicLibrary _dl;
  bool _stopped = false;

  /// Provision a fresh node identity IN-PROCESS (generate keypair + mine the
  /// PoW nonce) and return its config as TOML — **nothing is written to disk**.
  /// Store the result inside the deniable container (see Storage.saveNodeConfig)
  /// and later boot from it via [startDeferred] + [applyConfig].
  ///
  /// [difficulty] is the PoW difficulty in leading zero bits (0 = canonical
  /// default). Mining can take a while — run it off the UI isolate.
  static String mineConfig(int difficulty, {DynamicLibrary? lib}) {
    final dl = lib ?? _veilLib();
    final initFn =
        dl.lookupFunction<_ConfigInitNative, _ConfigInitDart>('veil_config_init');
    final freeStr =
        dl.lookupFunction<_FreeStrNative, _FreeStrDart>('veil_free_string');
    final errOut = calloc<Pointer<Utf8>>();
    try {
      final out = initFn(difficulty, errOut);
      if (out == nullptr) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_config_init failed: $msg');
      }
      final toml = out.toDartString();
      freeStr(out);
      return toml;
    } finally {
      calloc.free(errOut);
    }
  }

  /// Compose a full, bootable node config from a stored identity (from
  /// [mineConfig], loaded out of the deniable container) plus EPHEMERAL,
  /// per-launch runtime endpoints — a [listenTransport] (e.g.
  /// `tcp://127.0.0.1:9931`), an [ipcSocket], and an [adminSocket] (filesystem
  /// paths). None of these are identity-bearing, so they are never stored.
  static String composeConfig({
    required String identityToml,
    required String listenTransport,
    required String ipcSocket,
    required String adminSocket,
    DynamicLibrary? lib,
    bool anonymous = false,
    bool lazyMining = false,
    List<BootstrapPeerCfg> bootstrapPeers = const [],
    String? obfs4PskFile,
    ProxyRouting proxy = ProxyRouting.disabled,
  }) {
    return _composeConfigImpl(
      identityToml: identityToml,
      listenTransport: listenTransport,
      ipcSocket: ipcSocket,
      adminSocket: adminSocket,
      lib: lib,
      anonymous: anonymous,
      lazyMining: lazyMining,
      bootstrapPeers: bootstrapPeers,
      obfs4PskFile: obfs4PskFile,
      proxy: proxy,
    );
  }

  /// Append a `[transport]` table pointing at a file holding the deployment-wide
  /// obfs4 pre-shared key. Networks that pin a shared obfs4 PSK (anti-probe)
  /// require dialers to present the SAME key — without it the obfs4 handshake
  /// fails with `obfs4-tcp transport requires obfs4_psk set in TransportContext`.
  /// Pure helper (no FFI), so it is unit-testable. [pskFilePath] must already
  /// exist and contain the base64 PSK.
  static String withObfs4PskFile(String toml, String? pskFilePath) {
    if (pskFilePath == null || pskFilePath.isEmpty) return toml;
    if (toml.contains('obfs4_psk_file')) return toml; // already set
    final line = 'obfs4_psk_file = "$pskFilePath"';
    // veil_config_compose serializes a full Config, so a `[transport]` table
    // may already exist; insert the key right under its header (a key-value
    // before any sub-table is valid TOML). Otherwise append a new table.
    const marker = '[transport]\n';
    final idx = toml.indexOf(marker);
    if (idx >= 0) {
      final at = idx + marker.length;
      return '${toml.substring(0, at)}$line\n${toml.substring(at)}';
    }
    return '$toml\n[transport]\n$line\n';
  }

  /// Append `[[bootstrap_peers]]` tables so the node dials a known network
  /// (a seed set / testnet) at boot — without them an embedded node only sees
  /// the compiled-in BUILTIN_SEEDS. Pure helper (no FFI) so it is unit-testable.
  /// Mirrors the on-disk node.toml shape veil renders (top-level tables, NOT
  /// nested under `[network]`).
  static String withBootstrapPeers(String toml, List<BootstrapPeerCfg> peers) {
    if (peers.isEmpty) return toml;
    final buf = StringBuffer(toml);
    for (final p in peers) {
      // Defense-in-depth: never interpolate a value that could break out of the
      // TOML string (quote / newline / backslash) — skip a malformed entry
      // rather than emit a corrupt or injected config. transport must be a
      // structural scheme://rest URI; the rest must be plain base64-ish tokens.
      if (!_tomlSafe(p.transport) ||
          !_tomlSafe(p.publicKey) ||
          !_tomlSafe(p.nonce) ||
          !_tomlSafe(p.algo) ||
          !RegExp(r'^[a-z0-9.+-]+://[^\s\x00-\x1f"\\]+$').hasMatch(p.transport)) {
        continue;
      }
      buf
        ..write('\n[[bootstrap_peers]]\n')
        ..write('transport = "${p.transport}"\n')
        ..write('public_key = "${p.publicKey}"\n')
        ..write('nonce = "${p.nonce}"\n')
        ..write('algo = "${p.algo}"\n');
    }
    return buf.toString();
  }

  /// True when [s] carries no TOML-string-breaking characters, so it is safe to
  /// interpolate inside `key = "..."`.
  static bool _tomlSafe(String s) => !s.contains(RegExp(r'["\n\r\\\t]'));

  /// Append a location-anonymous `[anonymity]` table to a composed [toml] when
  /// [anonymous] — register at a rendezvous relay over an onion circuit
  /// (Tor-hidden-service-style) so peers/relays never learn this identity's IP,
  /// so it can't be correlated to the user's other identities. The defaults are
  /// off + skipped in the rendered config, so appending a new table is safe
  /// (`onion_service` implies the `receive_anonymous` lifecycle). Pure helper —
  /// no FFI — so it is unit-testable.
  static String withAnonymity(String toml, bool anonymous) {
    if (!anonymous || toml.contains('[anonymity]')) return toml;
    return '$toml\n[anonymity]\nreceive_anonymous = true\nonion_service = true\n';
  }

  /// Force the `[Identity]` lazy-mining preference, OVERRIDING whatever the
  /// stored identity baked in. Lazy mining is a CPU-heavy BACKGROUND grind
  /// (raising the identity's anti-sybil difficulty via repeated PoW) that the
  /// node does NOT need to function; it competes with the latency-critical async
  /// runtime on mobile, and identities minted before the cap fix target an
  /// UNREACHABLE difficulty 64 — grinding a core forever, starving IPC (→ 12s FFI
  /// timeouts + UI hangs). Default OFF; the user opts IN via settings.
  ///
  /// Strips any persisted `lazy_mining` / `max_lazy_difficulty` and re-applies:
  /// disabled ⇒ absent ⇒ deserialises to `lazy_mining = false`; enabled ⇒
  /// `lazy_mining = true` with a REACHABLE cap (32, not 64) so the miner finishes
  /// and returns to idle. Pure helper (no FFI), so it is unit-testable.
  static String withLazyMining(String toml, bool enabled) {
    final stripped = toml
        .split('\n')
        .where((l) {
          final t = l.trimLeft();
          return !t.startsWith('lazy_mining') &&
              !t.startsWith('max_lazy_difficulty');
        })
        .join('\n');
    if (!enabled) return stripped;
    // Opt-in: insert under the identity table with a reachable cap. If no
    // identity header is found (shouldn't happen for a real config) the string
    // is returned unchanged, leaving lazy mining OFF — the safe default.
    return stripped.replaceFirstMapped(
      RegExp(r'\[identity\]\n', caseSensitive: false),
      (m) => '${m[0]}lazy_mining = true\nmax_lazy_difficulty = 32\n',
    );
  }

  /// Append a `[session]` table with a TIGHT keepalive so the node's mesh
  /// session to its relays survives mobile NAT / Android socket reaping. The
  /// default keepalive is 30 s; on a phone the obfs4 TCP connection to the seeds
  /// gets reset ("Connection reset by peer") well before that, the routing table
  /// never warms, and `lookup_relay_x25519` (mailbox registration) times out — so
  /// the node can't register and becomes unreachable after a restart. A tight
  /// keepalive keeps the mapping fresh; idle_timeout MUST stay > keepalive.
  /// 15 s still let mobile relay sessions churn (observed: a phone registering
  /// on 2 relays as its session reset between keepalives → rendezvous ad /
  /// subscriber lag → cookie_unknown introduce drops → delivery latency), so
  /// tighten to 10 s to cover more aggressive carrier-NAT / radio idle windows.
  /// Pure helper (no FFI), unit-testable.
  static String withSessionKeepalive(String toml) {
    if (toml.contains('[session]')) return toml;
    return '$toml\n[session]\nkeepalive_interval_secs = 10\nidle_timeout_secs = 45\n';
  }

  /// Append `[proxy.socks5]` / `[proxy.exit]` tables for traffic routing. The
  /// node runtime spawns these as services on boot AND re-spawns them on
  /// apply-config reload, so toggling routing needs no native rebuild — just a
  /// re-applied config carrying (or omitting) these sections. Pure helper (no
  /// FFI), so it is unit-testable. A SOCKS5 client role is only emitted with a
  /// valid exit ([ProxyRouting.socks5Active]); veil skips an exit-less SOCKS5.
  static String withProxy(String toml, ProxyRouting proxy) {
    if (!proxy.isActive || toml.contains('[proxy.')) return toml;
    final buf = StringBuffer(toml);
    if (proxy.socks5Active) {
      buf
        ..write('\n[proxy.socks5]\n')
        ..write('enabled = true\n')
        ..write('listen = "${proxy.socks5Listen}"\n')
        ..write('exit_node_id = "${proxy.exitNodeId}"\n');
    }
    if (proxy.exitEnabled) {
      buf
        ..write('\n[proxy.exit]\n')
        ..write('enabled = true\n')
        ..write('allow_private = ${proxy.exitAllowPrivate}\n');
    }
    return buf.toString();
  }

  static String _composeConfigImpl({
    required String identityToml,
    required String listenTransport,
    required String ipcSocket,
    required String adminSocket,
    DynamicLibrary? lib,
    bool anonymous = false,
    bool lazyMining = false,
    List<BootstrapPeerCfg> bootstrapPeers = const [],
    String? obfs4PskFile,
    ProxyRouting proxy = ProxyRouting.disabled,
  }) {
    final dl = lib ?? _veilLib();
    final composeFn =
        dl.lookupFunction<_ComposeNative, _ComposeDart>('veil_config_compose');
    final freeStr =
        dl.lookupFunction<_FreeStrNative, _FreeStrDart>('veil_free_string');

    final args = [identityToml, listenTransport, ipcSocket, adminSocket]
        .map(utf8.encode)
        .toList();
    final ptrs = <Pointer<Uint8>>[];
    final errOut = calloc<Pointer<Utf8>>();
    try {
      for (final bytes in args) {
        final p = calloc<Uint8>(bytes.length);
        p.asTypedList(bytes.length).setAll(0, bytes);
        ptrs.add(p);
      }
      final out = composeFn(ptrs[0], args[0].length, ptrs[1], args[1].length,
          ptrs[2], args[2].length, ptrs[3], args[3].length, errOut);
      if (out == nullptr) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_config_compose failed: $msg');
      }
      final toml = out.toDartString();
      freeStr(out);
      return withSessionKeepalive(withObfs4PskFile(
        withProxy(
          withBootstrapPeers(
            withLazyMining(withAnonymity(toml, anonymous), lazyMining),
            bootstrapPeers,
          ),
          proxy,
        ),
        obfs4PskFile,
      ));
    } finally {
      for (final p in ptrs) {
        calloc.free(p);
      }
      calloc.free(errOut);
    }
  }

  /// Start a node from [configPath]. [lib] defaults to the in-process symbols
  /// (the preloaded libveilclient_ffi). Throws if start fails.
  static EmbeddedNode start(String configPath, {DynamicLibrary? lib}) {
    final dl = lib ?? _veilLib();
    final startFn = dl.lookupFunction<_StartNative, _StartDart>('veil_node_start');
    final freeStr =
        dl.lookupFunction<_FreeStrNative, _FreeStrDart>('veil_free_string');

    final bytes = utf8.encode(configPath);
    final pathPtr = calloc<Uint8>(bytes.length);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      pathPtr.asTypedList(bytes.length).setAll(0, bytes);
      final handle = startFn(pathPtr, bytes.length, errOut);
      if (handle == nullptr) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_node_start failed: $msg');
      }
      return EmbeddedNode._(handle, dl);
    } finally {
      calloc.free(pathPtr);
      calloc.free(errOut);
    }
  }

  /// Start a node in deferred-init mode bound to [adminSocketPath] (an
  /// ephemeral, identity-free path). It boots under a throwaway identity; call
  /// [applyConfig] with the real config to promote it — so the private key never
  /// touches a config file on disk.
  ///
  /// When [anonymous], `[anonymity]` is armed in the stub BOOT config so the
  /// node is actually onion-reachable once its real identity is applied. This
  /// must be set here, not via [applyConfig]: veil pins anonymity at boot and a
  /// later reload does not re-apply it. The published onion descriptor is sealed
  /// against the live identity, so it resolves to the real identity post-[applyConfig].
  static EmbeddedNode startDeferred(
    String adminSocketPath, {
    bool anonymous = false,
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? _veilLib();
    final startFn = dl.lookupFunction<_StartDeferredNative, _StartDeferredDart>(
        'veil_node_start_deferred');
    final freeStr =
        dl.lookupFunction<_FreeStrNative, _FreeStrDart>('veil_free_string');

    final bytes = utf8.encode(adminSocketPath);
    final sockPtr = calloc<Uint8>(bytes.length);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      sockPtr.asTypedList(bytes.length).setAll(0, bytes);
      final handle = startFn(sockPtr, bytes.length, anonymous, errOut);
      if (handle == nullptr) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_node_start_deferred failed: $msg');
      }
      return EmbeddedNode._(handle, dl);
    } finally {
      calloc.free(sockPtr);
      calloc.free(errOut);
    }
  }

  /// Promote a deferred node to its real identity by applying [configToml]
  /// (e.g. the bytes from [mineConfig], loaded from the deniable container) over
  /// its admin socket, in memory. Throws if the apply fails.
  void applyConfig(String configToml) {
    final applyFn = _dl
        .lookupFunction<_ApplyConfigNative, _ApplyConfigDart>('veil_node_apply_config');
    final freeStr =
        _dl.lookupFunction<_FreeStrNative, _FreeStrDart>('veil_free_string');

    final bytes = utf8.encode(configToml);
    final tomlPtr = calloc<Uint8>(bytes.length);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      tomlPtr.asTypedList(bytes.length).setAll(0, bytes);
      final rc = applyFn(_handle, tomlPtr, bytes.length, errOut);
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_node_apply_config failed: $msg');
      }
    } finally {
      calloc.free(tomlPtr);
      calloc.free(errOut);
    }
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    final stopFn = _dl.lookupFunction<_StopNative, _StopDart>('veil_node_stop');
    stopFn(_handle); // signals shutdown + joins the node thread
  }
}

/// [NodeController] backed by the embedded in-process node — the production
/// path for sandboxed desktop and iOS (no `veil-cli` subprocess). Same
/// readiness contract as the subprocess controller (probe the app socket).
class EmbeddedNodeController implements NodeController {
  EmbeddedNodeController({
    this.configPath,
    required this.appSocketPath,
    this.lib,
    EmbeddedNode Function()? starter,
    this.readinessTimeout = const Duration(seconds: 25),
    this.pollInterval = const Duration(milliseconds: 300),
  })  : _starter = starter,
        assert(configPath != null || starter != null,
            'provide a configPath or a custom starter');

  /// Config file to boot from (file mode). Null when a custom [_starter] is
  /// used — e.g. the deniable path that boots deferred + apply-config.
  final String? configPath;
  final String appSocketPath;
  final DynamicLibrary? lib;
  final Duration readinessTimeout;
  final Duration pollInterval;

  /// Produces a started [EmbeddedNode]. Defaults to a file-config boot; the
  /// deniable path passes a starter that does startDeferred + applyConfig.
  final EmbeddedNode Function()? _starter;

  final _status = StreamController<NodeStatus>.broadcast();
  NodeStatus _current = NodeStatus.stopped;
  EmbeddedNode? _node;

  @override
  NodeStatus get current => _current;
  @override
  Stream<NodeStatus> status() => _status.stream;

  void _emit(NodeStatus s) {
    _current = s;
    if (!_status.isClosed) _status.add(s);
  }

  @override
  Future<void> start() async {
    if (_current.phase == NodePhase.starting ||
        _current.phase == NodePhase.connected) {
      return;
    }
    _emit(const NodeStatus(phase: NodePhase.starting));

    final probe = veilSocketProbe(appSocketPath);
    if (await probe()) {
      _emit(const NodeStatus(phase: NodePhase.connected)); // already up
      return;
    }
    try {
      _node = (_starter ?? () => EmbeddedNode.start(configPath!, lib: lib))();
    } catch (e) {
      _emit(NodeStatus(phase: NodePhase.error, message: '$e'));
      return;
    }

    final deadline = DateTime.now().add(readinessTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await probe()) {
        _emit(const NodeStatus(phase: NodePhase.connected));
        return;
      }
      await Future<void>.delayed(pollInterval);
    }
    _emit(const NodeStatus(
      phase: NodePhase.error,
      message: 'embedded node did not become ready before timeout',
    ));
  }

  @override
  Future<void> setEconomyMode(bool economy) async {
    // Background/economy tier is driven through the transport
    // (VeilClient.setBackgroundMode), not the node-control FFI.
  }

  @override
  Future<void> stop() async {
    _node?.stop();
    _node = null;
    _emit(NodeStatus.stopped);
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
  }
}
