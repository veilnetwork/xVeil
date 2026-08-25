import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart'
    show kProfileMode, kReleaseMode, visibleForTesting;
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
import 'data/node/network_flavor.dart';
import 'data/node/bundled_seeds.dart' show resolveBootstrapPeers;
import 'data/node/bundled_seeds_prefs.dart' show bundledSeedsAllowed;
import 'data/node/embedded_node.dart';
import 'data/node/node_controller.dart';
import 'data/storage/app_profile.dart';
import 'data/storage/async_kv_log_store.dart';
import 'data/storage/hidden_volume_storage.dart';
import 'data/storage/hv_native.dart';
import 'data/storage/on_disk_blob_store.dart';
import 'data/storage/profile_prefs_store.dart';
import 'data/runtime_dir_sweep.dart';
import 'data/transport/veil_native.dart';
import 'data/veil_stack.dart';
import 'debug/soak_hook.dart';
import 'features/bootstrap/storage_unavailable_app.dart';
import 'features/bootstrap/startup_failed_app.dart';
import 'state/providers.dart';
import 'state/translate_ffi.dart' show kRequiredSymbols, openTranslateLibrary;
import 'state/storage_preferences.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/log.dart';

/// The profile this launch resolved to. Declared beside [AppProfiles.directory]
/// — the data layer resolves model paths from it and must not import the
/// entrypoint — and re-exported here, where every reader already looks for it.
export 'data/storage/app_profile.dart' show activeProfile;

Duration? _disableAutomaticProviderRetry(int retryCount, Object error) => null;

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
  runZonedGuarded(() => runStartup(), (error, stack) {
    devLog(() => 'xVeil[uncaught:zone]: $error\n$stack');
    errorJournal.record(
      kind: 'zone',
      error: error,
      stack: stack,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
  });
}

/// Bring the app up, and put SOMETHING on screen even if that fails.
///
/// The zone handler around this can only LOG an uncaught error; it cannot
/// un-skip the `runApp` the throw jumped over. Every failure in [boot] — a
/// preference store that will not install, a container path that will not
/// resolve, a provider override that throws while it is built — therefore ended
/// as an empty window: the process alive, a log written where nobody looks, and
/// a user with no way to tell whether their data had been touched.
///
/// [boot] and [present] are injectable so the guarantee is testable: an app
/// that only fails to appear when something goes wrong during startup is not
/// something a test can arrange from the outside.
@visibleForTesting
Future<void> runStartup({
  Future<void> Function() boot = _bootAndRunApp,
  void Function(Widget) present = runApp,
}) async {
  try {
    await boot();
  } catch (e, st) {
    devLog(() => 'xVeil[startup]: FAILED before runApp: $e\n$st');
    errorJournal.record(
      kind: 'startup',
      error: e,
      stack: st,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    // Last resort, and it must not be able to throw on its own: a const widget
    // over the compiled-in localizations, nothing read, nothing opened.
    present(const StartupFailedApp());
  }
}

/// Everything between process start and the app appearing on screen. Extracted
/// so [runStartup] has one thing to guard and one thing to fall back from.
/// Whether the config-file dev boot may run on this platform (report12 X-L5).
///
/// It ends at `veil-cli`, a BINARY: iOS cannot spawn one at all, and a phone
/// that half-started a subprocess launcher is worse off than one that never
/// tried. Mobile boots the node in-process instead, which is what the app
/// actually ships.
///
/// `no_subprocess_on_mobile_paths_test` already lists `veil_node.dart` as
/// desktop-only and names THIS branch as the reason a phone never reaches it.
/// That was a claim about reachability with nothing enforcing it — two
/// environment variables were the whole condition. This is what makes it true.
@visibleForTesting
bool configFileDevBootAllowed({
  required bool isMacOS,
  required bool isLinux,
  required bool isWindows,
}) => isMacOS || isLinux || isWindows;

Future<void> _bootAndRunApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  // FIRST, before anything can read a preference: take the app's
  // preferences out of the platform's system store and into a file in the
  // active profile's own directory (audit XV-16).
  //
  // On iOS the system store is `Library/Preferences/<bundle>.plist`, which
  // iOS copies into iCloud and encrypted device backups; the
  // exclude-from-backup flag the app sets covers Application Support and
  // cannot reach a directory the system owns. What was leaving the device
  // in the clear was the whole posture — active profile, whether the
  // profile switcher had been found, proxy and VPN routing policy with its
  // app list and subnets, notification settings, language — and, in the KEY
  // NAMES, a roster of which profiles exist at all.
  //
  // Ordering is load-bearing: `SharedPreferences` caches its map on first
  // use, so this has to win the race with every other reader.
  //
  // Still never fatal — a launch that dies over a preference is a worse
  // outcome than one that starts without them — but "not fatal" used to
  // mean "carry on with the SYSTEM STORE", which is the exact thing being
  // escaped. The assignment that swaps the backend is the last line of the
  // installer, so any throw before it (a missing `path_provider`, an
  // app-support directory that will not create) left everything after this
  // point writing back into `NSUserDefaults` and back into the backup,
  // profile roster and all. The fallback now leans the other way: an empty
  // in-memory store. Settings are lost on exit; nothing leaves the device.
  activeProfile = await installProfilePreferencesOrFallback(
    supportDir: () async => (await getApplicationSupportDirectory()).path,
    args: launchArguments,
    onError: (e, st) => devLog(
      () =>
          'xVeil[prefs]: profile preference install failed, running on an '
          'in-memory store for this session: $e\n$st',
    ),
  );

  // Whether the translation engine is reachable, answered once at startup.
  //
  // The whole probe is INSIDE the closure on purpose: `devLog` only calls it
  // when logging is on, so a release build with diagnostics off pays nothing.
  // A probe placed outside the gate has cost this app real time before.
  //
  // Worth answering at boot rather than at first use because the failure it
  // catches is invisible otherwise: on iOS the archive is linked into the
  // executable, and an executable exports nothing by default -- a whole
  // release configuration shipped with the engine inside the binary and
  // unreachable, and nothing would have said so until somebody tried to
  // translate and got "unavailable".
  devLog(() {
    final library = openTranslateLibrary();
    return library == null
        ? 'xVeil[translate]: engine NOT reachable from this build'
        : 'xVeil[translate]: engine reachable, '
              '${kRequiredSymbols.length} entry points';
  });

  // Desktop: arm window_manager so the close button can hide to tray
  // (DesktopTrayHost decides) instead of quitting. No-op on mobile.
  //
  // Guarded because this runs BEFORE `runApp` (audit X-16). The zone
  // handler below catches the error and logs it, but there is no UI yet to
  // log it to: the user gets a window that never appears, over an optional
  // piece of window chrome. Losing the tray behaviour is a far smaller
  // failure than losing the app, so carry on without it.
  try {
    await initDesktopWindow();
  } catch (e, st) {
    devLog(() => 'xVeil: desktop window setup failed, continuing: $e\n$st');
  }

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

  final boot = await _bootstrapOverrides();
  if (mustRefuseInsecureStorage(
    shipped: kReleaseMode || kProfileMode,
    secureStorageReady: boot.secureStorageReady,
  )) {
    // Refuse here rather than anywhere later: this runs before the router,
    // so no unlock screen, no onboarding and no API can be reached by any
    // subsequent navigation. A dead end is the point.
    runApp(const StorageUnavailableApp());
    return;
  }

  runApp(
    ProviderScope(
      overrides: boot.overrides,
      // Riverpod 3 retries failed providers by default. Preserve the
      // established fail-fast behavior here: operational retries already
      // live in the mailbox/node services with their own bounded backoff,
      // while retrying provider construction could duplicate side effects.
      retry: _disableAutomaticProviderRetry,
      child: const DesktopTrayHost(child: DebugSoakHookHost(child: XVeilApp())),
    ),
  );
}

/// Whether this build must refuse to start rather than run on the fake store.
///
/// [FakeKvLogStore] is the dev/test wiring: EVERY non-empty password opens the
/// SAME in-memory space, nothing is encrypted and nothing survives the process.
/// Degrading to it is defensible while developing and indefensible in a build
/// handed to someone: the app would show a password prompt, accept whatever was
/// typed, and present an empty space that looks like their secure one. They
/// would write a recovery phrase down for a container that does not exist.
///
/// The old code degraded silently in exactly the build where it mattered. Its
/// FATAL banner goes through [devLog], which is compiled out under
/// `dart.vm.product` unless XVEIL_RELEASE_LOG is set — so a shipped build with
/// a missing or ABI-broken hidden-volume library said nothing at all.
///
/// Pure and separate so the decision is unit-testable without a bootstrap:
/// the same reason [redirectForPhase] and [shouldOpenJoinSheet] are.
bool mustRefuseInsecureStorage({
  required bool shipped,
  required bool secureStorageReady,
}) => shipped && !secureStorageReady;

/// What [_bootstrapOverrides] resolved: the provider overrides, and whether the
/// NATIVE container actually backs storage. The flag is not derivable from the
/// override list — an empty list is both "nothing to override" and "the secure
/// path failed", which is precisely the ambiguity that let this ship.
typedef BootstrapResult = ({List<Override> overrides, bool secureStorageReady});

/// Builds provider overrides at launch:
/// - Native hidden-volume storage when available (else the in-memory fake, and
///   see [mustRefuseInsecureStorage] for what a shipped build does then).
/// - The real veil stack ONLY when the opt-in env flags XVEIL_VEIL_CLI +
///   XVEIL_VEIL_CONFIG are set; otherwise the default loopback path is left
///   entirely untouched. A veil-side failure still degrades to the loopback
///   fakes rather than blocking launch — an app that cannot reach the network
///   is honest about it on screen, unlike one that cannot protect a password.
Future<BootstrapResult> _bootstrapOverrides() async {
  final overrides = <Override>[];
  var secureStorageReady = false;
  String? storePath; // the deniable container path, shared with the boot config
  unawaited(_sweepPickedFileCache());

  try {
    if (ensureHiddenVolumeLoaded()) {
      // XVEIL_STORE_PATH lets two instances on one machine use separate
      // containers (dev/demo); otherwise the per-app support dir.
      final override = Platform.environment['XVEIL_STORE_PATH'];
      final dir = await getApplicationSupportDirectory();
      // [activeProfile] was resolved in main() together with the preference
      // store that belongs to it. The default profile resolves to the
      // historical container path, so an existing install is untouched and a
      // user who never opens the switcher cannot tell this exists.
      final prefs = await SharedPreferences.getInstance();
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
          // Open + serve the space on a dedicated worker isolate on EVERY
          // platform. Android ANR traces proved that the old mobile-inline
          // exception could park the Flutter main thread inside SpaceHandle.open
          // for >5s. The worker resolves the packaged Android soname in its own
          // isolate and both openers retain a guarded inline fallback for a
          // genuine worker bootstrap failure.
          //
          // BOTH openers, now. The master `openWithKeys` path was still lifted
          // inline here — so entering an identity, switching identity or editing
          // the roster still opened and scanned the container ON THE UI
          // ISOLATE, which is the same >5s ANR with a different entry point
          // (audit XV-14).
          final storage = HiddenVolumeStorage.async(
            workerSpaceOpener(path, paddingPreset: paddingPreset),
            keysOpener: workerKeysSpaceOpener(
              path,
              paddingPreset: paddingPreset,
            ),
          );
          // Large-file tier (Phase B): blobs too big for the hidden-volume index
          // are stored ENCRYPTED here (per-blob key + opaque name kept in the
          // volume). Alongside the container so a separate store (dev override)
          // gets its own. Capability only — a large file is stored on disk only
          // when the per-identity policy opts in (the receiver gates download).
          storage.useOnDiskTier(blobRootFor(path));
          ref.onDispose(storage.close);
          return storage;
        }),
      );
      secureStorageReady = true;
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
  if (configFileDevBootAllowed(
        isMacOS: Platform.isMacOS,
        isLinux: Platform.isLinux,
        isWindows: Platform.isWindows,
      ) &&
      cli != null &&
      cli.isNotEmpty &&
      config != null &&
      config.isNotEmpty) {
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
    // `XVEIL_RUNTIME_DIR` names a BASE we may create under — never a directory
    // we may own. Teardown removes the claimed directory RECURSIVELY, and the
    // first version of this claimed the operator's path itself: aimed at a
    // directory that already held data, the marker we wrote became the evidence
    // that it was ours to delete (audit XV-09). We now create a fresh child and
    // own only that, so a recursive delete can never reach anything that was
    // there before us.
    final runtimeDir = await claimRuntimeDirUnder(
      Platform.environment['XVEIL_RUNTIME_DIR'] ?? runtimeBase,
      uniqueSuffix: '$pid',
    );
    // The soak hook is default-OFF now; say so once, or a stand polling a port
    // that answers nothing reads as a node that failed to bootstrap.
    final hookNote = debugHookDisabledExplanation();
    if (hookNote != null) devLog(() => hookNote);
    // Reap what non-graceful exits leaked (force-stop / OOM-kill / crash skip
    // the graceful teardown that would remove these): one xveil-rt-<pid> dir
    // per launch, each holding the node's veil-deferred working dir with a
    // ~1.5 MB outbox.db — hundreds of launches quietly cost ~100 MB.
    // Sweep the base we actually claimed under, not the platform default — an
    // operator who set XVEIL_RUNTIME_DIR gets their leftovers reaped too, and
    // the default path is unchanged when they did not.
    unawaited(sweepStaleRuntimeDirs(File(runtimeDir).parent.path));
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
    // MERGE rather than either/or: the env file used to REPLACE the bundled
    // seeds, so naming one alternative entry point silently cost the node
    // every production seed — trading one single point of failure for
    // another. Both sets ride together, env entries first (an operator who
    // names a host meant it to be tried), deduplicated by public key.
    //
    // BUILT from this identity's answer to the shared-seed question, not
    // filtered afterwards: when the seeds are declined they are never merged
    // in, so nothing downstream is ever holding an address it could decide to
    // fall back to. The operator's env file survives either answer — declining
    // the SHARED seeds is not declining a node you named yourself. The other
    // half of the opt-out is `builtin_seed_policy = "never"` in the composed
    // node config (see [EmbeddedNode.withBuiltinSeedPolicy]); without it the
    // node dials its compiled-in seeds regardless of what this list holds.
    final useBundledSeeds = await bundledSeedsAllowed();
    final operatorPeers = _loadBootstrapPeers();
    final bundledSeeds = await _loadBundledSeeds();
    final bootstrapPeers = resolveBootstrapPeers(
      operatorPeers: operatorPeers,
      bundledSeeds: bundledSeeds,
      useBundledSeeds: useBundledSeeds,
    );
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
      bundledSeedsChoiceProvider.overrideWith((ref) => useBundledSeeds),
    );
    // `overrideWith` rather than `overrideWithValue`: the peer list is REBUILT
    // whenever the answer changes, which is what makes the choice effective on
    // the launch it is made. Everything expensive (claiming the runtime dir,
    // reading the asset) already happened above and is captured — the closure
    // only composes an immutable value, so a rebuild has no side effects. Every
    // consumer `ref.read`s this, so nothing re-renders off the back of it.
    overrides.add(
      deniableBootProvider.overrideWith(
        (ref) => DeniableBootConfig(
          runtimeDir: runtimeDir,
          listenPort: port,
          // Read here for the same reason XVEIL_LISTEN_PORT is: a stand that
          // runs two instances on one machine has to move BOTH addresses, and
          // the metrics one had no lever at all.
          debugMetricsPort: int.tryParse(
            Platform.environment['XVEIL_METRICS_PORT'] ?? '',
          ),
          storePath: storePath,
          bootstrapPeers: resolveBootstrapPeers(
            operatorPeers: operatorPeers,
            bundledSeeds: bundledSeeds,
            useBundledSeeds: ref.watch(bundledSeedsChoiceProvider),
          ),
          // The two halves, kept APART as well as merged. The merged list above
          // is the pre-unlock one — it can only be built from one answer, and
          // this process may host several identities that answered differently.
          // Each boot path rebuilds its identity's own list from these
          // ([DeniableBootConfig.peersFor]).
          operatorPeers: operatorPeers,
          bundledSeeds: bundledSeeds,
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
          'bundledSeeds=$useBundledSeeds '
          'obfs4Psk=${obfs4Psk != null && obfs4Psk.isNotEmpty} '
          'udpReflectors=${udpReflectors.length})',
    );
  } else if (Platform.isAndroid ||
      Platform.isIOS ||
      kReleaseMode ||
      kProfileMode) {
    // A packaged build ALWAYS ships the in-process node, so reaching here means
    // the native library failed to load / lacks the embedded-node FFI. Surface
    // that honestly instead of silently showing the demo node.
    //
    // `kReleaseMode || kProfileMode` covers DESKTOP too (audit XV-01). The
    // guard used to be mobile-only, so a packaged desktop build whose veil
    // dylib failed to load fell through with a null boot state — which selects
    // `FakeNodeController`, and the transport provider paired it with a
    // loopback that answers your own messages. A dev build still gets the demo
    // node, which is what it is for.
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
          'xVeil[real]: embedded node unavailable '
          '(veilLoaded=${ensureVeilClientLoaded()} embedded=${embeddedNodeAvailable()})',
    );
  }

  return (overrides: overrides, secureStorageReady: secureStorageReady);
}

/// What to complain about when the bundled obfs4 key did not arrive, or null
/// when its absence is the ordinary, expected kind.
///
/// TWO CAUSES WORE THE SAME ANSWER, and that is the defect this exists to end.
/// `null` used to mean both "this is a clean clone and the gitignored asset was
/// never bundled" — which is correct and must stay quiet — and "the asset IS
/// bundled and could not be read", which is a shipped build that can never
/// reach the production network. Without the key the transport refuses every
/// obfs4 bootstrap peer before any handshake, so the app starts, looks healthy,
/// and connects to nothing.
///
/// The one place that said anything went through `devLog`, which a release
/// build compiles out — so on exactly the builds where this matters it was
/// invisible. The complaint is therefore recorded where a shipped build can
/// still show it: the error journal behind "copy error report".
///
/// Pure, so both arms are reachable from a test with no asset bundle.
@visibleForTesting
String? bundledObfs4PskComplaint({
  required bool assetMissing,
  required String? raw,
}) {
  if (assetMissing) return null; // clean clone — expected, say nothing
  if (raw == null) {
    return 'the bundled obfs4 key is present but could not be read; '
        'without it every bootstrap peer is refused before any handshake';
  }
  if (raw.trim().isEmpty) {
    return 'the bundled obfs4 key is present but empty; '
        'without it every bootstrap peer is refused before any handshake';
  }
  return null;
}

/// Load the deployment-wide obfs4 PSK bundled for THIS BUILD'S NETWORK
/// (gitignored — present in shipped builds, absent in clean clones). Returns
/// null when the asset is missing/empty, so the node simply has no PSK (the
/// graceful-degradation path) rather than blocking launch. This is the mobile
/// equivalent of the desktop `XVEIL_OBFS4_PSK` env var.
///
/// Degrading gracefully is right; degrading SILENTLY was not — see
/// [bundledObfs4PskComplaint].
Future<String?> _loadBundledObfs4Psk() async {
  String? raw;
  var assetMissing = false;
  try {
    raw = (await rootBundle.loadString(veilNetwork.obfs4PskAsset)).trim();
  } on FlutterError {
    // The asset is not in the manifest at all: `loadString` answers a missing
    // asset with a FlutterError, and that is the clean-clone case. Anything
    // else — a platform read that failed, a decode that failed — is a bundled
    // asset this build could not get at, and is worth saying out loud.
    assetMissing = true;
  } catch (_) {
    raw = null;
  }
  final complaint = bundledObfs4PskComplaint(
    assetMissing: assetMissing,
    raw: raw,
  );
  if (complaint != null) {
    errorJournal.record(
      kind: 'network',
      error: complaint,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    devLog(() => 'xVeil[bootstrap]: $complaint');
  }
  return (raw == null || raw.isEmpty) ? null : raw;
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

/// Load the bundled seed descriptors for THIS BUILD'S NETWORK (public —
/// mirrors veil's builtin_seeds for the same network). The mobile fallback when
/// no
/// environment bootstrap file is set, so the node has concrete mailbox-relay
/// candidates and can publish a rendezvous ad. Absent (clean clone) ⇒ empty.
Future<List<BootstrapPeerCfg>> _loadBundledSeeds() async {
  try {
    final raw = await rootBundle.loadString(veilNetwork.seedsAsset);
    final json = jsonDecode(raw);
    if (json is List) return BootstrapPeerCfg.listFromJson(json);
  } catch (_) {
    // Asset not bundled (clean clone) — degrade to the compiled-in seeds.
  }
  return const [];
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
