import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'data/node/embedded_node.dart';
import 'data/node/node_controller.dart';
import 'data/storage/async_kv_log_store.dart';
import 'data/storage/hidden_volume_storage.dart';
import 'data/storage/hv_kv_log_store.dart';
import 'data/storage/hv_native.dart';
import 'data/transport/veil_native.dart';
import 'data/veil_stack.dart';
import 'state/providers.dart';
import 'package:xveil/core/log.dart';

Future<void> main() async {
  // Root-zone safety net. The app does heavy lifecycle churn (unlock,
  // identity-switch, storage-compaction all tear the session down and reopen),
  // and the FFI boundary (hidden_volume / veil_flutter) throws. Without a
  // global handler an uncaught async error has nowhere to go: it logs to the
  // console and the UI silently wedges (or, on a synchronous build error,
  // flashes a red ErrorWidget). These handlers turn every uncaught error into
  // a logged, survived event. They are defense-in-depth ONLY — the call sites
  // still guard + recover; this is the net under them.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      final priorFlutterOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        devLog(() => 'xVeil[uncaught:flutter]: ${details.exceptionAsString()}');
        // Keep the framework default (red ErrorWidget in debug, console in
        // release) so a genuine widget bug is still diagnosable in dev.
        priorFlutterOnError?.call(details);
      };

      // Uncaught async / platform errors (the fire-and-forget teardown legs the
      // audit flagged). Returning true marks them handled so they don't escalate.
      PlatformDispatcher.instance.onError = (error, stack) {
        devLog(() => 'xVeil[uncaught:platform]: $error\n$stack');
        return true;
      };

      // In a SHIPPED build never surface a raw stack-trace red screen to the
      // user (poor UX, and a stack on screen is an information leak in a deniable
      // app). Replace it with a neutral placeholder; the error is still logged
      // above. Debug keeps the red screen so developers see failures.
      if (kReleaseMode) {
        ErrorWidget.builder = (details) => const SizedBox.shrink();
      }

      runApp(
        ProviderScope(
          overrides: await _bootstrapOverrides(),
          child: const XVeilApp(),
        ),
      );
    },
    (error, stack) {
      devLog(() => 'xVeil[uncaught:zone]: $error\n$stack');
    },
  );
}

/// Builds provider overrides at launch:
/// - Native hidden-volume storage when available (else the in-memory fake).
/// - The real veil stack ONLY when the opt-in env flags XVEIL_VEIL_CLI +
///   XVEIL_VEIL_CONFIG are set; otherwise the default loopback path is left
///   entirely untouched. Any failure degrades to the fakes rather than
///   blocking launch.
Future<List<Override>> _bootstrapOverrides() async {
  final overrides = <Override>[];
  String? storePath; // the deniable container path, shared with the boot config

  try {
    if (ensureHiddenVolumeLoaded()) {
      // XVEIL_STORE_PATH lets two instances on one machine use separate
      // containers (dev/demo); otherwise the per-app support dir.
      final override = Platform.environment['XVEIL_STORE_PATH'];
      final dir = await getApplicationSupportDirectory();
      final path = (override != null && override.isNotEmpty)
          ? override
          : '${dir.path}/xveil.store';
      storePath = path;
      overrides.add(
        singleSpaceStorageProvider.overrideWith((ref) {
          // OFF-ISOLATE (DESKTOP only): open + serve on a dedicated worker isolate
          // so the hidden-volume FFI never blocks the UI thread (fixes the
          // desktop freeze). On MOBILE the worker is NOT used: a spawned isolate
          // there could not open the container ("wrong password" lockout — the
          // native lib doesn't resolve in a non-main isolate on Android), so
          // mobile uses the proven INLINE path (identical to pre-off-isolate).
          // The keys-opener (master openWithKeys) stays inline either way.
          final mobile = Platform.isAndroid || Platform.isIOS;
          final storage = mobile
              ? HiddenVolumeStorage(
                  hvSpaceOpener(path),
                  keysOpener: hvKeysSpaceOpener(path),
                )
              : HiddenVolumeStorage.async(
                  workerSpaceOpener(path),
                  keysOpener: syncWrappedKeysOpener(hvKeysSpaceOpener(path)),
                );
          // Large-file tier (Phase B): blobs too big for the hidden-volume index
          // are stored ENCRYPTED here (per-blob key + opaque name kept in the
          // volume). Alongside the container so a separate store (dev override)
          // gets its own. Capability only — a large file is stored on disk only
          // when the per-identity policy opts in (the receiver gates download).
          storage.useOnDiskTier(Directory('${File(path).parent.path}/blobs'));
          ref.onDispose(storage.close);
          return storage;
        }),
      );
    } else {
      // SAFETY: the native hidden-volume library did not load, so the app is
      // about to run on the IN-MEMORY FAKE store — every password opens the same
      // space, with NO encryption and NO deniability. That must never pass
      // silently in a deniable messenger. On desktop this usually means the
      // dylibs weren't bundled into the .app (see scripts/bundle-macos-dylibs.sh).
      devLog(
        () =>
            'xVeil[storage]: ************************************************',
      );
      devLog(
        () =>
            'xVeil[storage]: FATAL: hidden-volume native lib NOT loaded — '
            'falling back to the IN-MEMORY FAKE store. Passwords are MEANINGLESS, '
            'data is NOT encrypted and is lost on exit. DO NOT trust this build.',
      );
      devLog(
        () =>
            'xVeil[storage]: ************************************************',
      );
    }
  } catch (e) {
    // Stay on the in-memory store — but make the degradation visible.
    devLog(
      () =>
          'xVeil[storage]: FATAL: secure storage init threw -> IN-MEMORY '
          'FAKE store (no encryption/deniability): $e',
    );
  }

  final cli = Platform.environment['XVEIL_VEIL_CLI'];
  final config = Platform.environment['XVEIL_VEIL_CONFIG'];
  if (cli != null && cli.isNotEmpty && config != null && config.isNotEmpty) {
    // Legacy dev path: boot from a pre-made config.toml at launch.
    try {
      if (ensureVeilClientLoaded()) {
        final sock = '${File(config).parent.path}/app.sock';
        // XVEIL_NODE_MODE=embedded runs the node in-process (no subprocess) —
        // requires a node-embedded dylib. Default spawns veil-cli.
        final embedded = Platform.environment['XVEIL_NODE_MODE'] == 'embedded';
        final stack = await RealVeilStack.start(
          veilCliPath: cli,
          configPath: config,
          appSocketPath: sock,
          embedded: embedded,
        );
        overrides.add(realStackProvider.overrideWith((ref) => stack));
        devLog(
          () =>
              'xVeil[real:legacy]: connected, node=${stack.myInvite.nodeId.short}',
        );
      } else {
        devLog(() => 'xVeil[real]: veil dylib failed to load');
      }
    } catch (e) {
      devLog(() => 'xVeil[real]: start failed -> loopback: $e');
    }
  } else if (ensureVeilClientLoaded() && embeddedNodeAvailable()) {
    // Deniable path: the node boots IN-PROCESS post-unlock from the identity
    // stored inside the unlocked container (AppController._ensureRealStack),
    // so nothing identity-bearing is ever written to a config.toml. Each
    // instance needs its own listener port (XVEIL_LISTEN_PORT) + sockets dir.
    // Runtime sockets dir (admin/ipc unix sockets + the public PSK). On mobile,
    // Directory.systemTemp is the app's code_cache, where some devices' SELinux
    // policy DENIES creating unix socket files (`sock_file create`) — the
    // embedded node then can't bind its admin socket and apply-config fails with
    // ENOENT (observed on a MediaTek Android 11). The app's PRIMARY data dir
    // (getApplicationSupportDirectory — where the container already lives,
    // proven writable) is where apps are expected to place unix sockets. Desktop
    // keeps systemTemp (/tmp): short paths that stay under the ~104-char
    // unix-socket path limit (the app-support dir there is long).
    final String runtimeBase;
    if (Platform.isAndroid || Platform.isIOS) {
      runtimeBase = (await getApplicationSupportDirectory()).path;
    } else {
      runtimeBase = Directory.systemTemp.path;
    }
    final runtimeDir =
        Platform.environment['XVEIL_RUNTIME_DIR'] ??
        '$runtimeBase/xveil-rt-$pid';
    final port =
        int.tryParse(Platform.environment['XVEIL_LISTEN_PORT'] ?? '') ?? 9000;
    // XVEIL_BOOTSTRAP_PEERS points at a local JSON file (gitignored — a testnet
    // set is environment-specific, never committed) listing the network's
    // bootstrap peers. Absent ⇒ the node relies on its compiled-in BUILTIN_SEEDS.
    // Bootstrap peers serve two roles: DHT entry points AND mailbox-relay
    // candidates (the receiver advertises one in its rendezvous ad so senders
    // can reach it by node_id behind NAT). The env-file path is for desktop
    // testnets; when it's empty — ALWAYS on a packaged mobile build — fall back
    // to the bundled production seeds. Without this the mobile node has NO relay
    // candidate, never registers a rendezvous publisher, and is unreachable by
    // node_id. (These mirror veil's compiled-in builtin_seeds, so DHT bootstrap
    // is unchanged — this only makes them available to Dart as relay options.)
    var bootstrapPeers = _loadBootstrapPeers();
    if (bootstrapPeers.isEmpty) {
      bootstrapPeers = await _loadBundledSeeds();
    }
    // XVEIL_OBFS4_PSK: base64 deployment-wide obfs4 key for networks that pin
    // one (testnet/production). Without it, dialing obfs4 bootstrap peers fails
    // the handshake. Treated as config, not a secret — but environment-specific.
    // On mobile there is no env var, so fall back to the bundled deployment PSK
    // asset (gitignored; present in production builds, absent in clean clones).
    final obfs4Psk =
        Platform.environment['XVEIL_OBFS4_PSK'] ?? await _loadBundledObfs4Psk();
    overrides.add(
      deniableBootProvider.overrideWithValue(
        DeniableBootConfig(
          runtimeDir: runtimeDir,
          listenPort: port,
          storePath: storePath,
          bootstrapPeers: bootstrapPeers,
          obfs4Psk: (obfs4Psk != null && obfs4Psk.isNotEmpty) ? obfs4Psk : null,
        ),
      ),
    );
    // Real node expected: show an honest "connecting…" until it's up (or an
    // error if the in-process boot fails) — never the demo node's fake count.
    overrides.add(
      nodeBootStateProvider.overrideWith(
        (ref) => const NodeStatus(phase: NodePhase.starting),
      ),
    );
    devLog(
      () =>
          'xVeil[real:deniable]: armed (runtimeDir=$runtimeDir port=$port '
          'bootstrapPeers=${bootstrapPeers.length} obfs4Psk=${obfs4Psk != null && obfs4Psk.isNotEmpty})',
    );
  } else if (Platform.isAndroid || Platform.isIOS) {
    // A packaged mobile build ALWAYS ships the in-process node, so reaching here
    // means the native library failed to load / lacks the embedded-node FFI.
    // Surface that honestly instead of silently showing the demo node.
    overrides.add(
      nodeBootStateProvider.overrideWith(
        (ref) => const NodeStatus(
          phase: NodePhase.error,
          message: 'embedded node unavailable (native library failed to load)',
        ),
      ),
    );
    devLog(
      () =>
          'xVeil[real]: embedded node unavailable on mobile '
          '(veilLoaded=${ensureVeilClientLoaded()} embedded=${embeddedNodeAvailable()})',
    );
  }

  return overrides;
}

/// Load the deployment-wide obfs4 PSK bundled at `assets/prod/obfs4_psk.b64`
/// (gitignored — present in production builds, absent in clean clones). Returns
/// null when the asset is missing/empty, so the node simply has no PSK (the
/// graceful-degradation path) rather than blocking launch. This is the mobile
/// equivalent of the desktop `XVEIL_OBFS4_PSK` env var.
Future<String?> _loadBundledObfs4Psk() async {
  try {
    final raw = (await rootBundle.loadString(
      'assets/prod/obfs4_psk.b64',
    )).trim();
    return raw.isEmpty ? null : raw;
  } catch (_) {
    return null; // asset not bundled (clean clone) — degrade gracefully
  }
}

/// Load bootstrap peers from the local JSON file named by `XVEIL_BOOTSTRAP_PEERS`
/// (a list of `{transport, public_key, nonce, algo?}`). Best-effort: a missing
/// or malformed file degrades to the empty set (compiled-in seeds), never blocks
/// launch. The file is gitignored — a testnet set must not land in the repo.
List<BootstrapPeerCfg> _loadBootstrapPeers() {
  final path = Platform.environment['XVEIL_BOOTSTRAP_PEERS'];
  if (path == null || path.isEmpty) return const [];
  try {
    final raw = File(path).readAsStringSync();
    final json = jsonDecode(raw);
    if (json is List) return BootstrapPeerCfg.listFromJson(json);
    devLog(() => 'xVeil[bootstrap]: $path is not a JSON array — ignoring');
  } catch (e) {
    devLog(() => 'xVeil[bootstrap]: failed to read $path: $e');
  }
  return const [];
}

/// Load the bundled production seed descriptors (`assets/prod/seeds.json`,
/// public — mirrors veil's builtin_seeds). The mobile fallback when no
/// environment bootstrap file is set, so the node has concrete mailbox-relay
/// candidates and can publish a rendezvous ad. Absent (clean clone) ⇒ empty.
Future<List<BootstrapPeerCfg>> _loadBundledSeeds() async {
  try {
    final raw = await rootBundle.loadString('assets/prod/seeds.json');
    final json = jsonDecode(raw);
    if (json is List) return BootstrapPeerCfg.listFromJson(json);
  } catch (_) {
    // Asset not bundled (clean clone) — degrade to the compiled-in seeds.
  }
  return const [];
}
