import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;

import 'app.dart';
import 'desktop/desktop_tray.dart';
import 'domain/content_manifest.dart';
import 'data/node/embedded_node.dart';
import 'data/node/node_controller.dart';
import 'data/storage/app_profile.dart';
import 'data/storage/async_kv_log_store.dart';
import 'data/storage/hidden_volume_storage.dart';
import 'data/storage/hv_kv_log_store.dart';
import 'data/storage/hv_native.dart';
import 'data/transport/veil_native.dart';
import 'data/veil_stack.dart';
import 'debug/soak_hook.dart';
import 'state/providers.dart';
import 'state/storage_preferences.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/log.dart';

Duration? _disableAutomaticProviderRetry(int retryCount, Object error) => null;

/// The profile this launch resolved to, for anything that has to report or
/// branch on it (the switcher UI, the node's listener port). Set once during
/// bootstrap, before any provider reads it.
String activeProfile = AppProfiles.defaultName;

/// Command-line arguments as delivered by the embedder — every desktop
/// platform (macOS needs MainFlutterWindow to hand argv to the Dart project;
/// Linux and Windows do it for free). Empty on mobile, where a launcher icon
/// carries no flags and [AppProfiles.envVar] is the only lever.
List<String> launchArguments = const [];

Future<void> main([List<String> args = const []]) async {
  launchArguments = args;
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

      // Desktop: arm window_manager so the close button can hide to tray
      // (DesktopTrayHost decides) instead of quitting. No-op on mobile.
      await initDesktopWindow();

      // Content hashing on the native digest (~30-50x the pure-Dart rate):
      // with package:crypto a 64 MiB attachment spent ~1.8 s hashing before
      // its offer could go out. Probe once — an older bundled dylib without
      // the symbol keeps the pure-Dart fallback (identical digests either
      // way, so contentIds and dedup are unaffected).
      try {
        veil.VeilCrypto.sha256(Uint8List(0));
        ContentManifest.sha256Override = veil.VeilCrypto.sha256;
        devLog(() => 'xVeil[init]: native sha256 engaged for content hashing');
      } catch (_) {
        devLog(() => 'xVeil[init]: native sha256 unavailable, Dart fallback');
      }

      final priorFlutterOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        devLog(() => 'xVeil[uncaught:flutter]: ${details.exceptionAsString()}');
        errorJournal.record(
          kind: 'flutter',
          error: details.exception,
          stack: details.stack,
          atMs: DateTime.now().millisecondsSinceEpoch,
        );
        // Keep the framework default (red ErrorWidget in debug, console in
        // release) so a genuine widget bug is still diagnosable in dev.
        priorFlutterOnError?.call(details);
      };

      // Uncaught async / platform errors (the fire-and-forget teardown legs the
      // audit flagged). Returning true marks them handled so they don't escalate.
      PlatformDispatcher.instance.onError = (error, stack) {
        devLog(() => 'xVeil[uncaught:platform]: $error\n$stack');
        errorJournal.record(
          kind: 'platform',
          error: error,
          stack: stack,
          atMs: DateTime.now().millisecondsSinceEpoch,
        );
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
          // Riverpod 3 retries failed providers by default. Preserve the
          // established fail-fast behavior here: operational retries already
          // live in the mailbox/node services with their own bounded backoff,
          // while retrying provider construction could duplicate side effects.
          retry: _disableAutomaticProviderRetry,
          child: const DesktopTrayHost(
            child: DebugSoakHookHost(child: XVeilApp()),
          ),
        ),
      );
    },
    (error, stack) {
      devLog(() => 'xVeil[uncaught:zone]: $error\n$stack');
      errorJournal.record(
        kind: 'zone',
        error: error,
        stack: stack,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
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
  unawaited(_sweepPickedFileCache());

  try {
    if (ensureHiddenVolumeLoaded()) {
      // XVEIL_STORE_PATH lets two instances on one machine use separate
      // containers (dev/demo); otherwise the per-app support dir.
      final override = Platform.environment['XVEIL_STORE_PATH'];
      final dir = await getApplicationSupportDirectory();
      final prefs = await SharedPreferences.getInstance();
      // Which profile this launch runs on. The default profile resolves to the
      // historical path, so an existing install is untouched and a user who
      // never opens the switcher cannot tell this exists.
      activeProfile = AppProfiles.resolve(
        args: launchArguments,
        remembered: prefs.getString(AppProfiles.activePref),
      );
      final path = (override != null && override.isNotEmpty)
          ? override
          : AppProfiles.storePath(dir.path, activeProfile);
      if (activeProfile != AppProfiles.defaultName) {
        // Created here rather than lazily by the container opener: a missing
        // parent directory surfaces as an opaque native open failure.
        await Directory(
          AppProfiles.directory(dir.path, activeProfile),
        ).create(recursive: true);
        devLog(() => 'xVeil[profile]: running on "$activeProfile" ($path)');
      }
      final leanPadding =
          prefs.getBool(kStorageLeanPaddingPref) ?? kStorageLeanPaddingDefault;
      final paddingPreset = leanPadding
          ? hv.PaddingPreset.none
          : hv.PaddingPreset.bucket256KiB;
      storePath = path;
      overrides.add(
        singleSpaceStorageProvider.overrideWith((ref) {
          // Open + serve the password-backed space on a dedicated worker
          // isolate on EVERY platform. Android ANR traces proved that the old
          // mobile-inline exception could park the Flutter main thread inside
          // SpaceHandle.open for >5s. The worker resolves the packaged Android
          // soname in its own isolate and workerSpaceOpener retains its guarded
          // inline fallback for a genuine worker bootstrap failure. The master
          // openWithKeys path remains separately sync-wrapped for now.
          final storage = HiddenVolumeStorage.async(
            workerSpaceOpener(path, paddingPreset: paddingPreset),
            keysOpener: syncWrappedKeysOpener(
              hvKeysSpaceOpener(path, paddingPreset: paddingPreset),
            ),
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
    // Config-file dev path: boot from a pre-made config.toml at launch.
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
              'xVeil[real:cfgfile]: connected, node=${stack.myInvite.nodeId.short}',
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
    // Reap what non-graceful exits leaked (force-stop / OOM-kill / crash skip
    // the graceful teardown that would remove these): one xveil-rt-<pid> dir
    // per launch, each holding the node's veil-deferred working dir with a
    // ~1.5 MB outbox.db — hundreds of launches quietly cost ~100 MB.
    unawaited(_sweepStaleRuntimeDirs(runtimeBase));
    final port =
        int.tryParse(Platform.environment['XVEIL_LISTEN_PORT'] ?? '') ??
        AppProfiles.listenPort(
          activeProfile,
          base: Platform.isIOS ? 9002 : 9000,
        );
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
    // Reflectors are discovered from authenticated live peers. Packaged apps
    // deliberately inject no central endpoint into the per-identity config.
    const udpReflectors = <String>[];
    overrides.add(
      deniableBootProvider.overrideWithValue(
        DeniableBootConfig(
          runtimeDir: runtimeDir,
          listenPort: port,
          storePath: storePath,
          bootstrapPeers: bootstrapPeers,
          udpReflectors: udpReflectors,
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
          'bootstrapPeers=${bootstrapPeers.length} '
          'obfs4Psk=${obfs4Psk != null && obfs4Psk.isNotEmpty} '
          'udpReflectors=${udpReflectors.length})',
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

/// True when the process with [otherPid] is still alive (POSIX `kill -0`).
/// Conservative: any error (no `kill` binary, permission) counts as ALIVE so a
/// sweep never removes a live instance's runtime dir.
Future<bool> _pidAlive(int otherPid) async {
  try {
    final r = await Process.run('kill', ['-0', '$otherPid']);
    return r.exitCode == 0;
  } catch (_) {
    return true;
  }
}

/// Most recent mtime under [dir] (the dir itself + every file inside). Errors
/// on individual entries are skipped — the sweep must never throw.
Future<DateTime> _newestMtime(Directory dir) async {
  var newest = DateTime.fromMillisecondsSinceEpoch(0);
  try {
    newest = (await dir.stat()).modified;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      try {
        final m = (await e.stat()).modified;
        if (m.isAfter(newest)) newest = m;
      } catch (_) {}
    }
  } catch (_) {}
  return newest;
}

/// Best-effort reaper for per-run dirs that only a GRACEFUL exit removes:
///  - `xveil-rt-<pid>` (unix sockets + PSK + the embedded node's nested
///    `veil-deferred-*` working dir with its preallocated ~1.5 MB outbox.db);
///  - desktop-only sibling `veil-deferred-*` dirs the node creates directly in
///    the system temp dir when TMPDIR doesn't point into the runtime dir.
/// Android force-stop/OOM-kill and stand `kill -9` never run that teardown, so
/// these accumulate one per launch, forever. An xveil-rt dir is reclaimed when
/// its pid is dead; a veil-deferred dir when nothing inside has been touched
/// for a day (a live node keeps writing its outbox.db).
Future<void> _sweepStaleRuntimeDirs(String runtimeBase) async {
  const staleAfter = Duration(hours: 24);
  var removed = 0;
  try {
    await for (final e in Directory(runtimeBase).list(followLinks: false)) {
      if (e is! Directory) continue;
      final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      try {
        if (name.startsWith('xveil-rt-')) {
          final dirPid = int.tryParse(name.substring('xveil-rt-'.length));
          if (dirPid == null || dirPid == pid) continue;
          // Mobile runs a single instance per package, so any other pid is a
          // dead launch. Desktop keeps a dir whose pid is still alive (dev
          // multi-instance; a recycled pid merely defers the reclaim to the
          // OS's periodic temp cleanup — never worth risking a live dir).
          if (!(Platform.isAndroid || Platform.isIOS) &&
              await _pidAlive(dirPid)) {
            continue;
          }
        } else if (name.startsWith('veil-deferred-')) {
          // No pid in the name — recency is the only safe signal, measured on
          // the NEWEST file inside (a live node keeps touching its
          // mailbox/outbox.db; the dir's own mtime is frozen at creation). A
          // full day of silence inside means no node owns it.
          if (DateTime.now().difference(await _newestMtime(e)) < staleAfter) {
            continue;
          }
        } else {
          continue;
        }
        await e.delete(recursive: true);
        removed++;
      } catch (_) {
        // best-effort per entry — a locked/vanished dir must not stop the sweep
      }
    }
  } catch (_) {
    // base dir unreadable — nothing to sweep
  }
  if (removed > 0) {
    devLog(() => 'xVeil[sweep]: reaped $removed stale runtime dir(s)');
  }
}

/// Reap old `file_picker` cache copies. The picker COPIES every attached file
/// into `<cache>/file_picker/<ts>/` and never cleans up — heavy attach use
/// costs gigabytes that the user can only reclaim by clearing app data. A copy
/// is kept for [keep] so a recent attach can still re-serve (durable reoffer
/// reads from this path); an older reoffer honestly answers content-GONE,
/// exactly as when the OS itself evicts the cache dir under storage pressure.
Future<void> _sweepPickedFileCache({
  Duration keep = const Duration(hours: 24),
  int maxBytes = 512 * 1024 * 1024,
}) async {
  if (!(Platform.isAndroid || Platform.isIOS)) return; // desktop picks in place
  try {
    final cache = await getTemporaryDirectory();
    final dir = Directory('${cache.path}/file_picker');
    if (!await dir.exists()) return;
    final entries =
        <({FileSystemEntity entity, DateTime modified, int bytes})>[];
    var removed = 0;
    await for (final e in dir.list(followLinks: false)) {
      try {
        final stat = await e.stat();
        if (DateTime.now().difference(stat.modified) < keep) {
          entries.add((
            entity: e,
            modified: stat.modified,
            bytes: await _treeSizeBytes(e),
          ));
          continue;
        }
        await e.delete(recursive: true);
        removed++;
      } catch (_) {
        // best-effort per entry
      }
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified)); // newest first
    var total = entries.fold<int>(0, (sum, e) => sum + e.bytes);
    for (final e in entries.reversed) {
      if (total <= maxBytes) break;
      try {
        await e.entity.delete(recursive: true);
        total -= e.bytes;
        removed++;
      } catch (_) {
        // best-effort per entry
      }
    }
    if (removed > 0) {
      devLog(() => 'xVeil[sweep]: reaped $removed picked-file cache entries');
    }
  } catch (_) {
    // cache dir unavailable — nothing to sweep
  }
}

Future<int> _treeSizeBytes(FileSystemEntity entity) async {
  try {
    final stat = await entity.stat();
    if (entity is File) return stat.size;
    if (entity is! Directory) return 0;
    var total = 0;
    await for (final child in entity.list(
      recursive: true,
      followLinks: false,
    )) {
      try {
        if (child is File) total += (await child.stat()).size;
      } catch (_) {}
    }
    return total;
  } catch (_) {
    return 0;
  }
}
