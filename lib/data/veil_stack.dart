import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:xveil/core/cleanup_legs.dart';
import 'package:xveil/core/posix_file_facts.dart';

import 'native_libs.dart' show openEnvLib, processLibFor;
// The DECISION only, never `bundled_seeds_prefs.dart`: the preference store is
// package:shared_preferences, which is package:flutter, and this file is on the
// headless daemon's import path — one such import stopped `dart build cli`
// producing the daemon at all while every app build stayed green (709f3b9).
import 'node/bundled_seeds.dart'
    show bundledSeedsAllowedFromSpace, kBundledSeedsDefault;
import 'node/embedded_node.dart';
import 'node/node_controller.dart';
import 'node/proxy_routing.dart';
import 'node/ratchet_ffi.dart'
    show
        FfiRatchetStateHandle,
        RatchetStateHandle,
        dropRejectedRatchetStates,
        importRatchetStates,
        loadStoredRatchetStates;
import 'node/veil_node.dart';
import 'storage/storage.dart';
import 'transport/bootstrap_invite.dart';
import 'transport/veil_flutter_transport.dart';
import 'transport/veil_transport.dart';
import 'package:xveil/core/log.dart';

/// Thrown when the runtime directory cannot be made owner-only.
///
/// Carried as its own type so the boot path can report it as a refusal rather
/// than as a generic I/O failure — the distinction the operator needs is
/// "we declined to start" versus "the disk is broken".
class RuntimeDirNotPrivate implements Exception {
  RuntimeDirNotPrivate(this.dir, this.reason);

  final String dir;
  final String reason;

  @override
  String toString() =>
      'runtime directory $dir cannot be made owner-only ($reason); refusing to '
      'put the node control socket there';
}

/// Whether a failure to secure the runtime directory must stop the boot.
///
/// On macOS and Linux the path can sit on a filesystem other local users
/// share, so an unprotected directory is a real exposure and we refuse. On
/// Android and iOS the directory is inside the app sandbox — the OS is already
/// the boundary — and on Windows access is governed by the profile ACL, which
/// a POSIX mode cannot describe and this code does not attempt to set. Failing
/// the boot on those platforms would trade a guarantee they already have for
/// an outage.
bool runtimeDirMustBePrivate() => Platform.isMacOS || Platform.isLinux;

/// How this platform carries the node's two LOCAL control channels: the admin
/// socket the app drives the node through, and the app IPC socket it talks to
/// it over.
///
/// Two platforms cannot use a Unix domain socket and take authenticated
/// loopback TCP instead, for unrelated reasons:
///
///  * **iOS** — application-container paths exceed `sockaddr_un`'s `SUN_LEN` on
///    both physical devices and the Simulator, so the bind fails on a path the
///    app is not free to shorten.
///  * **Windows** — there is no Unix domain socket to bind at all. This was the
///    defect: Windows fell through to the POSIX branch and sent the node a bare
///    `C:\...\admin.sock`, which the FFI wrapped as `unix://C:\...` and pasted
///    into a TOML template, where `\U` opens a unicode escape. The shipped
///    build could not compose a config, let alone start a node, and said so
///    only as a TOML column number. veil's own `veil-cfg` already answers
///    `tcp://127.0.0.1:0` for `not(unix)`; this had been overriding it.
///
/// TCP and not a named pipe, on Windows, for three independent reasons:
/// `veil_node_start_deferred` rejects a `pipe://` endpoint outright, the Dart
/// readiness probe knows how to watch the TCP sidecars and knows nothing about
/// a pipe, and client-side anchor discovery already covers the TCP shape.
///
/// Pure and platform-named rather than reading [Platform] itself, so every
/// branch is reachable from a test on one host.
LocalEndpointPlan localEndpointPlanFor(String operatingSystem) =>
    LocalEndpointPlan(
      loopbackTcp: operatingSystem == 'ios' || operatingSystem == 'windows',
    );

/// The local-endpoint shape [localEndpointPlanFor] picked, resolved against a
/// runtime directory.
///
/// The `*Socket` paths are what the APP watches and connects to; the
/// `*Endpoint` values are what the NODE is told to bind. Under Unix sockets
/// they are the same string. Under loopback TCP they differ: the node binds an
/// ephemeral port and drops `ipc.port`/`ipc.token` sidecars in the runtime
/// directory, and the app finds them through the `.anchor` path, whose parent
/// directory is the part that matters.
class LocalEndpointPlan {
  const LocalEndpointPlan({required this.loopbackTcp});

  /// Carry admin + IPC over authenticated loopback TCP, with `.anchor`
  /// sidecars, instead of Unix domain sockets.
  final bool loopbackTcp;

  String ipcSocket(String runtimeDir) =>
      loopbackTcp ? '$runtimeDir/ipc.anchor' : '$runtimeDir/app.sock';

  String adminSocket(String runtimeDir) =>
      loopbackTcp ? '$runtimeDir/admin.anchor' : '$runtimeDir/admin.sock';

  String ipcEndpoint(String runtimeDir) => loopbackTcp
      ? 'tcp://127.0.0.1:0?runtime_dir=$runtimeDir'
      : ipcSocket(runtimeDir);

  String adminEndpoint(String runtimeDir) => loopbackTcp
      ? 'tcp://127.0.0.1:0?runtime_dir=$runtimeDir'
      : adminSocket(runtimeDir);
}

/// `chmod 700`, through libc. Null when the mode was applied, otherwise WHY it
/// was not.
///
/// There is no subprocess fallback, and that is not a simplification. The
/// fallback was `Process.run('chmod', …)`, which resolves a bare command name
/// through PATH — the substitutable oracle audit C-01 was about — and which on
/// iOS does not run at all: `Starting new processes is not supported on iOS`.
/// A "fallback" that throws on the platform it exists for is worse than none,
/// because it converts "I could not apply the mode" into an exception nobody
/// reads as that.
///
/// Where libc genuinely cannot answer, this says so and lets
/// [restrictRuntimeDir] read the mode back: what the directory IS decides,
/// never what a call claimed about it.
Future<String?> _chmod700(String dir) async {
  final rc = posixChmod(dir, 0x1C0); // 0700
  if (rc == null) return 'chmod(2) is not available on this host';
  return rc == 0 ? null : 'chmod(2) refused $dir';
}

/// Create [path] as a directory that MUST NOT already exist.
///
/// `Directory.create` happily returns an existing directory, so it cannot say
/// "this one is mine, I just made it". `mkdir(2)` can, and it applies the mode
/// in the same call, which also closes the window in which the directory
/// existed at the process umask. Returns false when the path was taken (or the
/// creation failed for any other reason).
bool _createExclusiveDir(String path) {
  final rc = posixMkdir(path, 0x1C0); // 0700
  if (rc != null) return rc == 0;
  // No libc binding (Windows): the pre-check is not atomic, but it is still a
  // refusal to adopt somebody else's directory rather than a silent reuse.
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return false;
  }
  try {
    Directory(path).createSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

String _randomName(String prefix) {
  final random = Random.secure();
  final bytes = List<int>.generate(4, (_) => random.nextInt(256));
  return '$prefix-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

String _randomSecret() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Name of the file that marks a directory as one xVeil created and may delete.
///
/// The runtime base comes from `XVEIL_RUNTIME_DIR` when set, and teardown
/// removes it RECURSIVELY. Nothing checked that the path was ours, so a wrong
/// launcher entry — or an env var set by anything else in the session — turned
/// lock/wipe into a recursive delete of whatever it pointed at (audit X-12).
const kRuntimeDirMarker = '.xveil-runtime';

/// Claim a runtime directory we CREATED, and return its path.
///
/// ## Why this returns a child rather than marking [base]
///
/// The first version of this wrote the marker straight into whatever
/// `XVEIL_RUNTIME_DIR` named, creating it if absent. That made the marker prove
/// the wrong thing: not "we created this directory" but "we were once pointed
/// at it". Aim the variable at a directory that already holds data and the very
/// next teardown recursively removed it — with the marker we had just written
/// ourselves as the evidence it was ours (audit XV-09).
///
/// So the operator's path is treated as a BASE we may create things under, not
/// as a directory we may own. We make a fresh, uniquely-named child inside it
/// with `create-new` semantics and own only that. Deleting it can never take
/// anything that was in the base beforehand, because the child did not exist
/// beforehand.
///
/// The operator's choice of base is still honoured. Refusing a non-empty or
/// pre-existing path — the audit's suggestion — would break headless and bot
/// deployments and profiles, which legitimately run on an operator-chosen
/// directory; that is the same reason the "overrides only in debug" half of
/// X-12 was declined.
///
/// [uniqueSuffix] exists for tests. Production passes the pid, which is the
/// same disambiguator the default base already uses.
Future<String> claimRuntimeDirUnder(
  String base, {
  required String uniqueSuffix,
}) async {
  // The BASE may legitimately already exist (it is usually the system temp dir
  // or the app-support dir). It must not be a symlink: `Directory.create`
  // follows one, and a link planted here would relocate everything below.
  if (FileSystemEntity.typeSync(base, followLinks: false) ==
      FileSystemEntityType.link) {
    throw RuntimeDirNotPrivate(base, 'runtime base is a symlink');
  }
  await Directory(base).create(recursive: true);

  // Created EXCLUSIVELY: an existing name is somebody else's — a live sibling,
  // a dead run's leftovers, or something planted — and is never adopted. The
  // name keeps the pid because the launch sweeper reaps by it.
  var attempt = 0;
  while (true) {
    final suffix = attempt == 0 ? uniqueSuffix : '$uniqueSuffix-$attempt';
    final child = '$base/xveil-rt-$suffix';
    if (!_createExclusiveDir(child)) {
      attempt++;
      if (attempt > 64) {
        throw RuntimeDirNotPrivate(base, 'no free runtime directory name');
      }
      continue;
    }
    await _writeRuntimeDirMarker(child);
    return child;
  }
}

/// Write the ownership marker into a directory we just created.
///
/// [secret] is written by [RuntimeDirLease] and is what makes the marker
/// evidence rather than decoration: it is unguessable and lives inside an
/// owner-only directory, so a directory that answers with it is the very one
/// this lease created — not one that was moved into its place afterwards.
Future<void> _writeRuntimeDirMarker(String dir, {String? secret}) async {
  await File('$dir/$kRuntimeDirMarker').writeAsString(
    'Created by xVeil. Deleting this file makes xVeil leave the directory '
    'alone on teardown instead of removing it.\n'
    '${secret == null ? '' : 'lease $secret\n'}',
  );
}

/// Mark an ALREADY-CREATED directory as ours.
///
/// Only for callers that made the directory themselves (the headless runtime
/// builds its own layout). It deliberately does NOT create the directory: a
/// marker written into a directory we did not create is the XV-09 hole.
Future<void> markRuntimeDirOwned(String dir) async {
  if (!Directory(dir).existsSync()) {
    throw RuntimeDirNotPrivate(dir, 'refusing to claim a directory we did not create');
  }
  if (FileSystemEntity.typeSync(dir, followLinks: false) ==
      FileSystemEntityType.link) {
    throw RuntimeDirNotPrivate(dir, 'path is a symlink');
  }
  await _writeRuntimeDirMarker(dir);
}

/// Whether [dir] carries our marker — i.e. may be removed recursively.
///
/// A missing directory answers false: there is nothing to delete, and saying
/// "yes" would make the caller's guard look like it passed.
bool runtimeDirIsOurs(String dir) =>
    File('$dir/$kRuntimeDirMarker').existsSync();

/// Ownership of ONE runtime directory this process created, and the only thing
/// that may remove it.
///
/// The runtime dir arrives from configuration — `runtime_dir` in the headless
/// config, `XVEIL_RUNTIME_DIR` in the app. It used to be taken as a finished
/// directory: `chmod 700` was applied to it and teardown ran
/// `delete(recursive: true)` on it with nothing checked. Name `/`, a home
/// directory, or a shared `/run` in that field — a typo, a copied unit file, a
/// variable set by something else in the session — and a daemon, typically
/// running as root, re-permissioned it on the way up and erased its contents on
/// the way down (audit C-02).
///
/// So the configured path is a BASE we may create under, never a directory we
/// may own:
///
///   * a fresh, randomly named child is created with `mkdir(2)` and mode 0700 —
///     exclusive, so an existing name is a refusal rather than an adoption, and
///     the directory is never briefly world-readable at the process umask;
///   * a secret is written into the marker inside it. The directory is
///     owner-only, so nobody else can read the secret to forge it elsewhere;
///   * the device+inode and owner are remembered at creation.
///
/// [release] deletes only after all of that still matches. Anything it cannot
/// confirm — the marker gone or changed, a different inode behind the same
/// name, an owner that is not us, a path that is no longer a directory — leaves
/// the directory alone. A few leftover sockets are a rounding error next to
/// erasing the wrong tree.
class RuntimeDirLease {
  RuntimeDirLease._({
    required this.path,
    required this.base,
    required this._secret,
    required this._identity,
  });


  /// The directory this lease created and owns.
  final String path;

  /// What it was created under. Never removed by this lease.
  final String base;

  final String _secret;
  final PosixFileFacts? _identity;
  bool _released = false;

  /// Bases nothing may be leased directly on top of.
  ///
  /// The lease only ever removes its own child, so these are belt-and-braces —
  /// but `/` or `$HOME` in a runtime-dir field is a configuration mistake worth
  /// naming at the moment it is made rather than a location worth using.
  static bool _forbiddenBase(String base) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final normalized = base.length > 1 && (base.endsWith('/') || base.endsWith(r'\'))
        ? base.substring(0, base.length - 1)
        : base;
    if (normalized.isEmpty || normalized == '/' || normalized == r'\') {
      return true;
    }
    if (RegExp(r'^[A-Za-z]:$').hasMatch(normalized)) return true;
    if (home != null && home.isNotEmpty && normalized == home) return true;
    return false;
  }

  /// Take a fresh directory under [base].
  ///
  /// [prefix] only shapes the name; the disambiguator is random, so two
  /// processes — or two identities in one process — never race for the same
  /// one, and a crashed run's leftovers are never adopted.
  static Future<RuntimeDirLease> acquire(
    String base, {
    String prefix = 'rt',
  }) async {
    if (base.trim().isEmpty) {
      throw RuntimeDirNotPrivate(base, 'no runtime directory base was given');
    }
    if (_forbiddenBase(base)) {
      throw RuntimeDirNotPrivate(
        base,
        'a filesystem root or home directory is not a runtime base',
      );
    }
    // The BASE may legitimately already exist (a system temp dir, an app
    // support dir, an operator's /run/xveil). It must not be a symlink:
    // `Directory.create` follows one, and a link planted here would relocate
    // everything below — including what teardown then removes.
    if (FileSystemEntity.typeSync(base, followLinks: false) ==
        FileSystemEntityType.link) {
      throw RuntimeDirNotPrivate(base, 'runtime base is a symlink');
    }
    await Directory(base).create(recursive: true);

    for (var attempt = 0; attempt < 8; attempt++) {
      final path = '$base/${_randomName(prefix)}';
      if (!_createExclusiveDir(path)) continue;
      final secret = _randomSecret();
      await _writeRuntimeDirMarker(path, secret: secret);
      // Mode 0700 came from `mkdir` itself, but a filesystem that ignores it
      // (some mounted shares do) must still be caught, and Windows has no mode
      // to set at all — so the existing verify-or-refuse runs unchanged.
      await restrictRuntimeDir(path);
      return RuntimeDirLease._(
        path: path,
        base: base,
        secret: secret,
        identity: posixLstat(path),
      );
    }
    throw RuntimeDirNotPrivate(base, 'no free runtime directory name');
  }

  /// Why this lease may NOT delete its directory, or null when it may.
  ///
  /// Fail-closed by construction: every branch that cannot establish something
  /// returns a reason. Exposed so the refusal is testable without arranging a
  /// deletion.
  String? refusalToRelease() {
    if (_released) return 'already released';
    if (path == base) return 'the lease path is the base itself';
    if (!path.startsWith('$base/') && !path.startsWith('$base\\')) {
      return 'the lease path is no longer under its base';
    }
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return 'the directory is already gone';
    }
    if (type != FileSystemEntityType.directory) {
      return 'the path is no longer a directory ($type)';
    }
    final identity = _identity;
    if (identity != null) {
      // POSIX: the name may have been re-pointed at something else entirely
      // while we held it. Identity is the (device, inode) pair, not the path.
      final now = posixLstat(path);
      if (now == null) return 'the directory could not be re-read';
      if (!now.isDirectory) return 'the path is no longer a directory';
      if (!now.sameObjectAs(identity)) {
        return 'a different directory now answers to this path';
      }
      if (now.uid != identity.uid) return 'the directory changed owner';
      final euid = posixEuid();
      if (euid != null && now.uid != euid) {
        return 'the directory is not owned by this process';
      }
    }
    final marker = File('$path/$kRuntimeDirMarker');
    if (FileSystemEntity.typeSync(marker.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return 'the ownership marker is missing';
    }
    final String contents;
    try {
      contents = marker.readAsStringSync();
    } on FileSystemException catch (error) {
      return 'the ownership marker could not be read ($error)';
    }
    if (!contents.contains('lease $_secret')) {
      return 'the ownership marker is not the one this lease wrote';
    }
    return null;
  }

  /// Remove the directory this lease created — and nothing else.
  ///
  /// Idempotent, and silent about a directory that has already gone. Returns
  /// the reason it declined, so a caller that cares can log it; production
  /// callers treat teardown as best-effort.
  Future<String?> release() async {
    final refusal = refusalToRelease();
    if (refusal != null) {
      _released = true;
      if (refusal != 'the directory is already gone' &&
          refusal != 'already released') {
        devLog(
          () =>
              'xVeil[deniable]: NOT removing $path — $refusal. Leaving it is '
              'the safe answer; deleting the wrong tree is not.',
        );
      }
      return refusal;
    }
    _released = true;
    try {
      await Directory(path).delete(recursive: true);
      return null;
    } on FileSystemException catch (error) {
      devLog(() => 'xVeil[deniable]: could not remove $path ($error)');
      return '$error';
    }
  }
}

/// Apply and VERIFY the owner-only mode on a directory we made.
///
/// It holds `admin.sock` — the node's CONTROL socket — next to `app.sock` and
/// the obfs4 PSK. `Directory.create` leaves the mode at the process umask,
/// which on a typical desktop is world-readable, so on a shared machine
/// another local user could reach the admin endpoint of someone else's node.
///
/// Two things this does that the old best-effort `chmod` did not:
///
///   * **verifies the result** by reading the mode back, instead of trusting
///     that `chmod` exiting zero means the filesystem honoured it. Mounted
///     shares and some vendor mounts accept the call and keep the old mode.
///   * **fails closed** where it matters ([runtimeDirMustBePrivate]) instead
///     of logging and carrying on. A hardening step that only logs is a
///     comment claiming something untrue.
///
/// The window this used to describe — the directory existing at the umask
/// between `create` and `chmod` — is gone: [RuntimeDirLease] creates through
/// `mkdir(2)` with the mode in the same call. This is now the verification
/// half only, which is why it no longer creates anything.
///
/// [chmod] exists for tests only — null from it means "applied", a string means
/// "not applied, and here is why". A filesystem that accepts the call and keeps
/// the old mode is the case the read-back guards against, and there is no way
/// to produce one on demand — so it is injected rather than described, and the
/// verification stays covered.
Future<void> restrictRuntimeDir(
  String dir, {
  Future<String?> Function(String dir)? chmod,
}) async {
  if (Platform.isWindows) return;
  String? notApplied;
  try {
    notApplied = await (chmod ?? _chmod700)(dir);
  } catch (e) {
    notApplied = 'chmod could not be run: $e';
  }

  // The mode read back is what decides, never the call's own account of
  // itself. That catches the filesystem which accepts chmod and ignores it —
  // and, in the other direction, it means a host with no `chmod(2)` binding is
  // not failed for that alone: if `mkdir(2)` or the umask already left the
  // directory owner-only, the guarantee holds and the boot goes on.
  String? failure;
  try {
    final mode = Directory(dir).statSync().mode;
    if (mode & 0x3F != 0) {
      final octal = (mode & 0x1FF).toRadixString(8);
      failure = notApplied == null
          ? 'mode is $octal after chmod, not 700'
          : 'mode is $octal and the mode could not be applied ($notApplied)';
    }
  } catch (e) {
    failure = 'could not stat the directory back: $e';
  }

  if (failure == null) return;
  if (runtimeDirMustBePrivate()) {
    throw RuntimeDirNotPrivate(dir, failure);
  }
  devLog(
    () =>
        'xVeil[deniable]: $dir is not owner-only ($failure) — the OS sandbox '
        'is the boundary on this platform, continuing',
  );
}

/// Register every application-supplied seed on the already-running node.
///
/// The app's deniable boot composes its config with `bootstrapPeers: const []`
/// on purpose — injecting them made `veil_node_apply_config` fail with ENOENT on
/// Android (a per-peer persist path that does not exist in the ephemeral runtime
/// dir). So the bundled seeds and the operator's own entry points are in NO
/// config the node ever reads: veil's compiled-in list is what a keeper's reload
/// splices in, and anything outside that list — a `XVEIL_BOOTSTRAP_PEERS` host,
/// a seed bundled ahead of a submodule bump — would otherwise never be dialled
/// at all. Redeeming each descriptor over IPC is how they reach the running
/// node; already-known builtin seeds are harmless refreshes and one bad seed
/// never blocks the rest.
///
/// Not a workaround for a reload that drops connectors — it does not. The
/// reload apply-config performs re-runs veil's bootstrap task and opens
/// connectors for every `[[bootstrap_peers]]` entry the applied config carries
/// (pinned by `the_applied_config_is_what_puts_a_deferred_node_on_the_network`
/// in veil-node-runtime). This exists because the applied config carries none.
Future<int> registerRuntimeBootstrapPeers(
  List<BootstrapPeerCfg> peers,
  Future<void> Function(String uri) join,
) async {
  var registered = 0;
  for (final peer in peers) {
    final uri =
        'veil:bootstrap?pk=${peer.publicKey}'
        '&t=${peer.transport}'
        '&a=${peer.algo}'
        '&nc=${peer.nonce}';
    try {
      await join(uri);
      registered++;
    } catch (e) {
      devLog(
        () =>
            'xVeil[bootstrap]: runtime seed registration failed '
            'transport=${peer.transport.split(':').first} '
            'error=${e.runtimeType}',
      );
    }
  }
  return registered;
}

/// Mine a node identity in a worker isolate. Re-opens the veil dylib INSIDE the
/// isolate (the parent's load is not guaranteed visible across isolates): from
/// `VEIL_FFI_DYLIB` when set (desktop/tests), else [processLibFor] — which on
/// Android `dlopen`s `libveilclient_ffi.so` by name (its symbols are LOCAL to
/// that handle, NOT in the global `DynamicLibrary.process()` table, so a
/// process() lookup of `veil_config_init` fails with "undefined symbol").
/// Top-level so it is a valid `Isolate.run` entry point.
///
/// THROUGH [openEnvLib] (audit X-17). These two isolates read the variable and
/// called `DynamicLibrary.open` on it themselves, testing only that the file
/// existed — the single exception to the rule `native_libs.dart` declares and
/// explains at length, that an operator's override must be ABSOLUTE. A
/// relative one resolves against whatever directory the app was launched from,
/// and `dlopen` runs the library's constructors on the spot. Being in an
/// isolate made it quieter, not safer.
String _mineConfigInIsolate() {
  final lib = openEnvLib('VEIL_FFI_DYLIB') ?? processLibFor('veilclient_ffi');
  return EmbeddedNode.mineConfig(0, lib: lib);
}

/// Same isolate-entry contract as [_mineConfigInIsolate], but the identity is
/// DERIVED from the onboarding master phrase (only the anti-sybil nonce is
/// mined) — see EmbeddedNode.configFromPhrase.
String _configFromPhraseInIsolate(String phrase) {
  final lib = openEnvLib('VEIL_FFI_DYLIB') ?? processLibFor('veilclient_ffi');
  return EmbeddedNode.configFromPhrase(phrase, lib: lib);
}

/// The composed real veil stack the app runs: a started node ([controller]), a
/// connected overlay [transport], this device's shareable [myInvite], and
/// contact redemption ([addContact]).
///
/// Two ways to build it:
/// - [startDeniable] (production): the node identity lives INSIDE the unlocked
///   deniable container; the node boots deferred and gets its config applied in
///   memory, so nothing identity-bearing is written to a `config.toml`. Invite
///   creation + join run over the node's own IPC.
/// - [start] (config-file dev path): boots from a pre-existing `config.toml`
///   and shells out to `veil-cli` for invite/join. Not deprecated — it is what
///   `scripts/run-real-instance.sh`, `run-deniable-instance.sh` and
///   `dev-real-pair.sh` still use, and `doc/REAL-MODE.md` documents.
/// The metrics endpoint's own define, and the soak hook's.
///
/// Read here rather than at the call site so the two defaults sit next to each
/// other and cannot drift apart again.
const bool kXVeilDebugMetricsDefine = bool.fromEnvironment(
  'XVEIL_DEBUG_METRICS',
);
const bool kXVeilDebugHookDefine = bool.fromEnvironment('XVEIL_DEBUG_HOOK');

/// Whether to open the loopback metrics endpoint (audit report10 X-10).
///
/// One define used to control two things with OPPOSITE defaults. The soak hook
/// reads `XVEIL_DEBUG_HOOK` plainly — default FALSE, deliberately, because a
/// full control plane should not be on for everyone who builds in debug. The
/// metrics endpoint read the SAME name with `defaultValue: true`. So an
/// ordinary debug build, with no defines at all, got no hook and an
/// unauthenticated Prometheus endpoint on 39997/39998 that any local process
/// could read activity counters from.
///
/// Now they share a default: off unless asked for. The hook's define still
/// turns metrics on, so a stand recipe that passes only `XVEIL_DEBUG_HOOK=true`
/// keeps working — the leak was the DEFAULT, not the coupling, and silently
/// taking metrics away from the stands that rely on them would trade one
/// surprise for another.
bool debugMetricsWanted({
  required bool debugBuild,
  required bool metricsDefine,
  required bool hookDefine,
}) => debugBuild && (metricsDefine || hookDefine);

class RealVeilStack {
  RealVeilStack._({
    required this.controller,
    required this.transport,
    required this.myInvite,
    String? veilCliPath,
    String? configPath,
    VeilFlutterTransport? nodeIpc,
    this._runtimeLease,
    this.listenPort = 0,
    this.lanListen = false,
    this.listenScheme = 'tcp',
    this.ratchetState,
  }) : _cli = veilCliPath,
       _config = configPath,
       _flutterTransport = nodeIpc;

  /// Assemble a stack over parts that already exist.
  ///
  /// Only for driving [dispose] against fakes: the teardown it performs is the
  /// one that removes the runtime directory, which is a DENIABILITY control,
  /// and a control nothing can reach is a control nothing can check.
  ///
  /// Production code builds its stacks through [startDeniable] or [start];
  /// nothing else should call this.
  static RealVeilStack overParts({
    required NodeController controller,
    required VeilTransport transport,
    required BootstrapInvite myInvite,
    RuntimeDirLease? runtimeLease,
  }) => RealVeilStack._(
    controller: controller,
    transport: transport,
    myInvite: myInvite,
    runtimeLease: runtimeLease,
  );

  final NodeController controller;
  final VeilTransport transport;
  final BootstrapInvite myInvite;

  /// The port this instance's node listener is bound on, and whether that bind
  /// is LAN-wide (`0.0.0.0`, P2P policy allowed it) or loopback-only. The P2P
  /// endpoint service combines [listenPort] with the device's LAN addresses to
  /// mint the direct-dial URIs it shares with consenting contacts; when
  /// [lanListen] is false it shares nothing (nobody could dial us anyway).
  final int listenPort;
  final bool lanListen;

  /// Scheme of the actual peer listener. P2P endpoint exchange must preserve
  /// it: advertising `tcp://` for a QUIC socket silently falls back to the
  /// ordered stream path and reintroduces video head-of-line stalls.
  final String listenScheme;

  /// The node's ratchet-state door, when it has one.
  ///
  /// Null on the subprocess/dev paths (no IPC handle of our own) and on a dylib
  /// built without `node-embedded`. The stored conversations were already
  /// handed back to veil by the time this stack exists — see [startDeniable];
  /// what remains for the messaging layer is the write after every operation.
  ///
  /// Its own `veil_connect` connection, closed by [dispose]. Borrowing the
  /// transport's would mean reaching into `VeilClient`'s private handle and
  /// then racing its close on the send path.
  final RatchetStateHandle? ratchetState;

  // The config-file dev path uses veil-cli + a config file for invite/join.
  final String? _cli;
  final String? _config;
  // ...the deniable path uses the node's own IPC instead.
  final VeilFlutterTransport? _flutterTransport;
  // Ownership of the ephemeral runtime dir (sockets + public PSK) this boot
  // CREATED. Released on dispose so it leaves NO at-rest artifact — and
  // released only after it proves the directory is still the one it made
  // (see [RuntimeDirLease]).
  final RuntimeDirLease? _runtimeLease;

  /// Step 1 of the deniable boot, extracted so the provenance contract is
  /// unit-testable: load the stored node config, or provision + store one on
  /// first run — derived from [identityPhrase] when given, mined at random
  /// otherwise. Records [kIdentityOriginSetting] ('phrase'/'mined') alongside
  /// a FRESH provision only, so the honest "no phrase" state of a space
  /// provisioned before the marker existed is never overwritten.
  static Future<String> ensureNodeConfig(
    Storage storage, {
    String? identityPhrase,
    DynamicLibrary? lib,
  }) async {
    final existing = await storage.loadNodeConfig();
    if (existing != null) return existing;
    final String identityToml;
    final String origin;
    if (identityPhrase != null && identityPhrase.isNotEmpty) {
      devLog(
        () =>
            'xVeil[deniable]: deriving node identity from phrase '
            '(first run)…',
      );
      // Phrase-derived identity (P2): the keypair is deterministic, only the
      // nonce search burns CPU — still off the UI isolate like the mine.
      final phrase = identityPhrase;
      identityToml = lib == null
          ? await Isolate.run(() => _configFromPhraseInIsolate(phrase))
          : EmbeddedNode.configFromPhrase(phrase, lib: lib);
      origin = 'phrase';
    } else {
      devLog(() => 'xVeil[deniable]: mining node identity (first run)…');
      // Canonical-difficulty PoW is CPU-heavy. Run it on a separate isolate so
      // the UI thread stays responsive (the "setting up" screen animates). The
      // worker isolate re-opens the dylib itself (from VEIL_FFI_DYLIB) rather
      // than relying on the parent's load being visible via process(), which is
      // not guaranteed across isolates. The explicit-lib path (tests) mines
      // inline.
      identityToml = lib == null
          ? await Isolate.run(_mineConfigInIsolate)
          : EmbeddedNode.mineConfig(0, lib: lib);
      origin = 'mined';
    }
    await storage.saveNodeConfig(identityToml);
    await storage.putSetting(kIdentityOriginSetting, origin);
    return identityToml;
  }

  /// Production boot: identity comes from the unlocked [storage] (mined +
  /// stored on first run), the node boots in-process via deferred-init and has
  /// its real config applied in memory — no `config.toml` on disk.
  ///
  /// [runtimeDirBase] is a BASE, not a directory to take over: this boot
  /// creates its own randomly-named child under it and owns only that. The
  /// configured value used to be treated as a finished directory that was
  /// `chmod`-ed on the way up and recursively deleted on the way down, so a
  /// `runtime_dir` of `/`, a home directory or a shared `/run` was
  /// re-permissioned and then emptied by a daemon that usually runs as root
  /// (audit C-02). [listenPort] is this instance's listener (give two
  /// instances on one host distinct ports).
  static Future<RealVeilStack> startDeniable({
    required Storage storage,
    required String runtimeDirBase,
    DynamicLibrary? lib,
    int listenPort = 9000,
    // P2P direct-session epic: bind the node's listener on all interfaces so
    // LAN contacts can dial the exchanged `tcp://<lan-ip>:<listenPort>`
    // endpoint. Gated by the caller on the P2P policy (never for an anonymous
    // posture, never when policy=denied) — a loopback-only node stays
    // undialable, which is the deniable default.
    bool lanListen = false,
    bool anonymous = false,
    bool lazyMining = false,
    List<BootstrapPeerCfg> bootstrapPeers = const [],
    // Optional post-connect set: activates app-bundled alternatives without
    // injecting them into the deferred reload config. Null reuses the config
    // set, which is the natural behaviour for headless callers.
    List<BootstrapPeerCfg>? runtimeBootstrapPeers,
    List<String> udpReflectors = const [],
    String? obfs4Psk,
    ProxyRouting proxy = ProxyRouting.disabled,
    // Test/headless multi-node runs may host several embedded nodes in one
    // process. Give each one a distinct loopback-only metrics port; ordinary
    // app boots keep the established platform default.
    int? debugMetricsPort,
    // First-run only (onboarding-phrase epic P2): when set and no node config
    // is stored yet, the identity is DERIVED from this master phrase instead
    // of mined at random — node_id becomes deterministic in the phrase, so
    // disaster recovery restores the same identity. Consumed once; the phrase
    // itself is never persisted (the derived [Identity] TOML goes into the
    // deniable container like the mined one always has).
    String? identityPhrase,
    // Whether this identity may reach the network through the SHARED seed
    // nodes. Null resolves it from THIS identity's own space — the [storage]
    // this boot already holds open — which is what makes the opt-out impossible
    // for a caller to forget. Callers that resolved it themselves (both app
    // boot paths, which need the same answer to build the peer list) pass it in
    // rather than reading twice; the daemon passes what its config file said,
    // or null when the file did not say; tests pass it explicitly.
    //
    // Resolved from the SPACE and not from a preference: the preference store is
    // one file per app profile, so a decoy master — another space in the same
    // container — used to inherit the real identity's answer from it, and two
    // identities online at once could not disagree at all.
    //
    // It is NOT enough to hand over an empty peer list — see
    // [EmbeddedNode.withBuiltinSeedPolicy] for the compiled-in seeds the node
    // would otherwise dial entirely on its own.
    bool? useBundledSeeds,
  }) async {
    // The SPACE alone, with no preference behind it. This runs inside the
    // headless daemon too, which has no app profile and therefore no preference
    // to read or migrate from; the one-time migration off the profile
    // preference belongs to the app and happens above, in `planIdentitySeeds`,
    // which is why both app boot paths pass the answer in.
    final seedsAllowed =
        useBundledSeeds ??
        await bundledSeedsAllowedFromSpace(
          storage,
          ifUnanswered: kBundledSeedsDefault,
        );
    // Time each phase so the log pinpoints where a slow boot/switch goes (the
    // boot is mining-free when the identity already exists, so a slow switch is
    // the node bind/connect, not PoW). Zero-cost diagnostic; reads at a glance.
    final sw = Stopwatch()..start();
    int lap() {
      final ms = sw.elapsedMilliseconds;
      sw.reset();
      return ms;
    }

    // 1. Load this identity's node config, or derive/mine + store it on
    // first run.
    final identityToml = await ensureNodeConfig(
      storage,
      identityPhrase: identityPhrase,
      lib: lib,
    );
    devLog(
      () =>
          'xVeil[deniable]: identity ready (${identityToml.length} B) '
          '[+${lap()}ms config]',
    );

    // 2. Ephemeral, identity-free runtime endpoints, in a directory this boot
    // CREATES under the configured base and owns outright (audit C-02).
    // 2b. Read the stored ratchet sessions NOW, while the only thing that can
    // fail is a container read. They have to be back inside veil before the
    // node can be handed a frame, and the import itself is a synchronous FFI
    // call in the middle of the boot — so the async half is done first, here.
    final storedRatchet = await loadStoredRatchetStates(storage);

    final lease = await RuntimeDirLease.acquire(runtimeDirBase);
    try {
      return await _startDeniableIn(
        lease,
        identityToml: identityToml,
        storage: storage,
        storedRatchet: storedRatchet,
        lap: lap,
        lib: lib,
        listenPort: listenPort,
        lanListen: lanListen,
        anonymous: anonymous,
        lazyMining: lazyMining,
        bootstrapPeers: bootstrapPeers,
        runtimeBootstrapPeers: runtimeBootstrapPeers,
        udpReflectors: udpReflectors,
        obfs4Psk: obfs4Psk,
        proxy: proxy,
        debugMetricsPort: debugMetricsPort,
        useBundledSeeds: seedsAllowed,
      );
    } catch (_) {
      // A boot that never completed still made a directory; nothing else will
      // ever come back for it. Every failure path inside [_startDeniableIn]
      // arrives here, which is what makes "no start failure leaves the sockets
      // and the PSK behind" a property of ONE place rather than of five.
      //
      // Through a leg so that a throw out of `release()` itself cannot replace
      // the error that actually explains the failed boot.
      await runCleanupLegs('veil-stack-boot', [
        ('runtime dir', () async => lease.release()),
      ]);
      rethrow;
    }
  }

  /// The rest of [startDeniable], once the runtime directory is OURS.
  ///
  /// Split out so one `try` can own the release of that directory: a boot that
  /// throws half way used to leave the sockets dir behind with nothing left to
  /// come back for it.
  static Future<RealVeilStack> _startDeniableIn(
    RuntimeDirLease lease, {
    required String identityToml,
    required Storage storage,
    required List<RatchetStateEntry> storedRatchet,
    required int Function() lap,
    required DynamicLibrary? lib,
    required int listenPort,
    required bool lanListen,
    required bool anonymous,
    required bool lazyMining,
    required List<BootstrapPeerCfg> bootstrapPeers,
    required List<BootstrapPeerCfg>? runtimeBootstrapPeers,
    required List<String> udpReflectors,
    required String? obfs4Psk,
    required ProxyRouting proxy,
    required int? debugMetricsPort,
    required bool useBundledSeeds,
  }) async {
    final runtimeDir = lease.path;
    final endpoints = localEndpointPlanFor(Platform.operatingSystem);
    final ipcSock = endpoints.ipcSocket(runtimeDir);
    final ipcEndpoint = endpoints.ipcEndpoint(runtimeDir);
    final adminEndpoint = endpoints.adminEndpoint(runtimeDir);
    // Direct peer sessions use QUIC even on a LAN. Besides authenticating and
    // encrypting the listener transport, this makes QUIC DATAGRAM available
    // to real-time media; TCP remains supported when dialing older peers.
    const listenScheme = 'quic';
    final listen = lanListen
        ? '$listenScheme://0.0.0.0:$listenPort'
        : '$listenScheme://127.0.0.1:$listenPort';

    // Deployment-wide obfs4 PSK (networks that pin a shared anti-probe key):
    // drop it in the runtime dir and reference it from the config. Identity-free
    // and ephemeral, so it lives alongside the sockets (never in the container).
    String? obfs4PskFile;
    if (obfs4Psk != null && obfs4Psk.isNotEmpty) {
      obfs4PskFile = '$runtimeDir/obfs4_psk.b64';
      await File(obfs4PskFile).writeAsString(obfs4Psk);
    }

    // 3. Compose a full, bootable config (identity + runtime) in memory.
    // INVARIANT: `anonymous` here MUST match the value passed to startDeferred
    // below. veil pins [anonymity] from the STUB boot config; the applied config
    // is a reload that does not re-apply it but DOES warn `config.anonymity.
    // reload_ignored` if its [anonymity] differs from the boot state. Keeping the
    // applied config's anonymity consistent with the stub's avoids that warning.
    var fullConfig = EmbeddedNode.composeConfig(
      identityToml: identityToml,
      listenTransport: listen,
      ipcSocket: ipcEndpoint,
      adminSocket: adminEndpoint,
      lib: lib,
      anonymous: anonymous,
      lazyMining: lazyMining,
      bootstrapPeers: bootstrapPeers,
      udpReflectors: udpReflectors,
      obfs4PskFile: obfs4PskFile,
      proxy: proxy,
      useBundledSeeds: useBundledSeeds,
    );
    // Debug stands only: loopback Prometheus metrics for the embedded node,
    // the per-node twin of a relay's [metrics] endpoint. Never binds a
    // non-loopback interface.
    if (debugMetricsWanted(
      debugBuild: kXVeilDebugBuild,
      metricsDefine: kXVeilDebugMetricsDefine,
      hookDefine: kXVeilDebugHookDefine,
    )) {
      fullConfig = EmbeddedNode.withDebugMetrics(
        fullConfig,
        debugMetricsPort ??
            ((Platform.isAndroid || Platform.isIOS) ? 39998 : 39997),
      );
    }
    if (proxy.isActive) {
      // Proxy services spawn from the APPLIED config (spawn_all_services runs on
      // apply-config reload too), so unlike [anonymity] this needs no stub
      // boot-arming — the composed config above carries the [proxy.*] sections.
      devLog(
        () =>
            'xVeil[deniable]: traffic routing — socks5=${proxy.socks5Active} '
            'exit=${proxy.exitEnabled}',
      );
    }
    if (bootstrapPeers.isNotEmpty) {
      devLog(
        () =>
            'xVeil[deniable]: dialing ${bootstrapPeers.length} '
            'bootstrap peer(s) from config',
      );
    }
    if (anonymous) {
      // Anonymity must be armed at BOOT (passed to startDeferred below), not via
      // applyConfig: veil pins `[anonymity]` at node start and a reload does not
      // re-apply it. The onion descriptor is sealed against the LIVE identity, so
      // arming the stub anonymous + applying the real identity makes the node
      // onion-reachable under its real identity (the throwaway stub identity is
      // never published — publish is periodic, not at boot). See
      // veil build_stub_config_with_ephemeral_identity / veil_node_start_deferred.
      devLog(
        () =>
            'xVeil[deniable]: anonymous routing — arming onion at boot '
            '(resolves to the real identity after apply-config)',
      );
    }
    devLog(
      () =>
          'xVeil[deniable]: composed config [+${lap()}ms], '
          'booting deferred @ $adminEndpoint',
    );

    // 4. Boot deferred (anonymity armed in the stub when requested), then apply
    // the real config IN MEMORY (no file) to promote the real identity.
    //
    // The first thing the node does is ignore this config. `startDeferred`
    // boots from a stub built on the native side
    // (`veil-cfg/src/store.rs::build_stub_config_with_ephemeral_identity`),
    // which is `Config::default()` plus a fixed throwaway identity — so it
    // carries no `[[bootstrap_peers]]` and no `obfs4_psk_file`, and there is no
    // way to hand it any: `veil_node_start_deferred(sock, len, anonymous, err)`
    // takes no config.
    //
    // That used to mean the boot dialled the network on its own. The stub met
    // veil's `builtin_seed_policy = "auto"` condition — neither `peers` nor
    // `[[bootstrap_peers]]` set — so every start logged
    // `dialing 4 entry point(s): 0 configured + 4 builtin seed(s)` and opened
    // connectors to the compiled-in production seeds, seconds before this
    // config had been applied and therefore before anything had consulted the
    // shared-seed setting at all. An identity that DECLINED them still touched
    // those hosts once per start, on the app and on the daemon alike, and
    // `useBundledSeeds` — which only ever reached [composeConfig] below — could
    // not have stopped it.
    //
    // The stub now sets `builtin_seed_policy = "never"`: a deferred boot
    // reaches nothing, and the network arrives with the config that was asked
    // about. Nothing is lost for an identity that KEPT the seeds — apply-config
    // is a full reload, so veil re-runs its bootstrap task against the config
    // below and splices the same seeds in there, over connectors that outlive
    // the boot. Pinned on the veil side by `deferred_stub_boot_dials_no_builtin
    // _seed` and `the_applied_config_is_what_puts_a_deferred_node_on_the_
    // network`, and from here by the deferred-stub gate in
    // `test/bundled_seeds_match_builtin_test.dart` — this app cannot observe
    // the stub at runtime, so a submodule bump is the way it would come back.
    final controller = EmbeddedNodeController(
      appSocketPath: ipcSock,
      starter: () {
        // Split the two FFI steps so the log distinguishes a slow admin BIND
        // (startDeferred) from a slow admin CONNECT/apply (applyConfig holds the
        // ~90s connect-retry — a big number here is the port-bind stall).
        final ssw = Stopwatch()..start();
        var tDeferred = 0;
        // The node exists between these two calls and the controller does not
        // own it yet — a throw from applyConfig used to strand it running, with
        // its ports held and no handle left to stop it (audit XV-03).
        final node = createThenPromote<EmbeddedNode>(
          create: () {
            final n = EmbeddedNode.startDeferred(
              adminEndpoint,
              anonymous: anonymous,
              lib: lib,
            );
            tDeferred = ssw.elapsedMilliseconds;
            return n;
          },
          promote: (n) => n.applyConfig(fullConfig),
          abandon: (n) => n.stop(),
        );
        devLog(
          () =>
              'xVeil[deniable]: startDeferred +${tDeferred}ms, '
              'applyConfig +${ssw.elapsedMilliseconds - tDeferred}ms',
        );
        return node;
      },
    );
    await controller.start();
    // This lap is the suspect for a slow switch: startDeferred + applyConfig
    // (admin bind/connect) + the readiness poll. A large value here with a
    // mining-free identity points at a port-bind stall, not PoW.
    devLog(
      () =>
          'xVeil[deniable]: controller phase=${controller.current.phase}'
          ' msg=${controller.current.message} [+${lap()}ms boot+connect]',
    );
    if (controller.current.phase != NodePhase.connected) {
      // STOP IT (audit XV-04). Failing the readiness check used to throw and
      // leave the node RUNNING: it kept the admin socket, the IPC socket and
      // the listen port, with no reference left to shut it down. The next boot
      // then found the port taken and failed for a reason that had nothing to
      // do with why the first one had not connected.
      //
      // Through a leg so a throw out of `stop()` cannot swallow the diagnosis
      // below — the phase and message are the only record of WHY the node did
      // not come up (audit XV-12).
      await runCleanupLegs('veil-stack-boot', [('controller', controller.stop)]);
      throw StateError(
        'deniable node did not connect: ${controller.current.phase}'
        ' (${controller.current.message})',
      );
    }

    // 4b. Hand the stored ratchet sessions back to veil, before ANY of this
    // app's traffic starts.
    //
    // This is the earliest point it can happen, and the reason is a type: the
    // ratchet FFI takes a `VeilHandle` — an IPC client connection — and the
    // node handle from `startDeferred` is a different one the handle table
    // refuses. `veil_connect` cannot run until the node's IPC socket answers,
    // which is exactly what the readiness poll above just waited for. So the
    // import lands here, ahead of the transport, ahead of seed registration and
    // ahead of the invite.
    //
    // What that leaves open is honest to state: the node has been on the
    // network for the length of the readiness poll, and a frame arriving in
    // that window is for a conversation not yet restored. It cannot be opened,
    // and unlike a lost packet the sender has already advanced its chain, so
    // nothing re-sends it in a readable form. Closing that window needs the
    // import to happen inside veil's own boot, not from out here.
    final RatchetStateHandle? ratchetState;
    try {
      ratchetState = FfiRatchetStateHandle.connect(ipcSock, lib: lib);
    } catch (e) {
      await runCleanupLegs('veil-stack-boot', [('controller', controller.stop)]);
      rethrow;
    }
    try {
      final rejected = importRatchetStates(ratchetState, storedRatchet);
      // Whatever veil would not take can never open a frame again, so the
      // records go rather than being re-read on every launch forever.
      await dropRejectedRatchetStates(storage, rejected);
      // Age out conversations nobody ever answered, now that the store is
      // whole. veil sweeps by itself only when the store hits its ceiling, so
      // a device that was flooded once would otherwise carry the wreckage in
      // memory until something else needed the room — and would import it back
      // at every launch besides. Here is the one moment per run when the store
      // is known-complete and no traffic has touched it yet.
      //
      // Memory is reclaimed on this line; the stored bytes go with the next
      // flush, which is what the marks veil leaves behind are for. Only
      // conversations this device has never sent on are eligible — aging out
      // one that has carried traffic would wedge both ends for good, since the
      // peer cannot restart its copy from anything on the wire.
      final aged = ratchetState?.expire() ?? 0;
      if (aged > 0) {
        devLog(() => 'xVeil[ratchet]: aged out $aged unanswered conversation(s)');
      }
    } catch (_) {
      await runCleanupLegs('veil-stack-boot', [
        ('ratchet handle', () async => ratchetState?.close()),
        ('controller', controller.stop),
      ]);
      rethrow;
    }

    // 5. Connect the transport, then ask the running node for its own invite.
    final VeilFlutterTransport transport;
    try {
      transport = await VeilFlutterTransport.connect(ipcSock);
    } catch (e) {
      await runCleanupLegs('veil-stack-boot', [
        ('ratchet handle', () async => ratchetState?.close()),
        ('controller', controller.stop),
      ]);
      rethrow;
    }
    // Everything past here owns TWO resources — the node and the transport —
    // and every step can throw (audit XV-04). Unwound in reverse order on the
    // way out, so a failure here cannot leave a live node behind the way the
    // readiness check used to.
    try {
      return await _finishDeniableBoot(
        controller: controller,
        transport: transport,
        runtimeBootstrapPeers: runtimeBootstrapPeers,
        bootstrapPeers: bootstrapPeers,
        runtimeLease: lease,
        listenPort: listenPort,
        lanListen: lanListen,
        listenScheme: listenScheme,
        ratchetState: ratchetState,
      );
    } catch (_) {
      // INDEPENDENT legs. Chained, a throw from `transport.dispose()` skipped
      // `controller.stop()` and left the node running with its admin socket,
      // its IPC socket and its listen port held, and no handle left to stop it
      // — the very thing the readiness check above was fixed for, reappearing
      // one step later (audit XV-12). Cleanup errors are swallowed in favour
      // of whatever failed the boot; that is the error the caller needs.
      await runCleanupLegs('veil-stack-boot', [
        ('transport', transport.dispose),
        ('ratchet handle', () async => ratchetState?.close()),
        ('controller', controller.stop),
      ]);
      rethrow;
    }
  }

  /// The tail of [startDeniable]: register seeds, mint the invite, assemble the
  /// stack. Split out so ONE `try` can own the unwind for all of it.
  static Future<RealVeilStack> _finishDeniableBoot({
    required NodeController controller,
    required VeilFlutterTransport transport,
    required List<BootstrapPeerCfg>? runtimeBootstrapPeers,
    required List<BootstrapPeerCfg> bootstrapPeers,
    required RuntimeDirLease runtimeLease,
    required int listenPort,
    required bool lanListen,
    required String listenScheme,
    required RatchetStateHandle? ratchetState,
  }) async {
    final seedsToRegister = runtimeBootstrapPeers ?? bootstrapPeers;
    final registeredSeeds = await registerRuntimeBootstrapPeers(
      seedsToRegister,
      transport.joinP2PEndpoint,
    );
    if (seedsToRegister.isNotEmpty) {
      devLog(
        () =>
            'xVeil[bootstrap]: runtime seeds registered '
            '$registeredSeeds/${seedsToRegister.length}',
      );
    }
    // IDENTITY-ONLY invite: the deniable node binds its listener on loopback
    // (or the 0.0.0.0 wildcard when [lanListen]), so the invite's advertise
    // address is never a URI a remote contact could meaningfully dial. Strip
    // it — peers reach this node by node_id over the rendezvous network, not
    // by dialing an address. Real direct-dial endpoints (LAN ip:port) travel
    // separately over the E2E contact channel with mutual P2P consent — see
    // P2PEndpointService — never inside the shareable invite.
    final veilInvite = BootstrapInvite.parse(await transport.createInvite());
    final invite = BootstrapInvite(
      publicKey: veilInvite.publicKey,
      nonce: veilInvite.nonce,
      algo: veilInvite.algo,
      transport: null,
    );
    devLog(() => 'xVeil[deniable]: connected + identity-only invite ready');

    return RealVeilStack._(
      controller: controller,
      transport: transport,
      myInvite: invite,
      nodeIpc: transport,
      runtimeLease: runtimeLease,
      listenPort: listenPort,
      lanListen: lanListen,
      listenScheme: listenScheme,
      ratchetState: ratchetState,
    );
  }

  /// Dev boot from an existing `config.toml`. [embedded] runs the node
  /// in-process; otherwise it spawns `veil-cli node run`. Still used by the
  /// dev scripts — see the class doc.
  static Future<RealVeilStack> start({
    required String veilCliPath,
    required String configPath,
    required String appSocketPath,
    bool embedded = false,
  }) async {
    final NodeController controller = embedded
        ? EmbeddedNodeController(
            configPath: configPath,
            appSocketPath: appSocketPath,
          )
        : veilSubprocessController(
            veilCliPath: veilCliPath,
            configPath: configPath,
            appSocketPath: appSocketPath,
          );
    await controller.start();
    if (controller.current.phase != NodePhase.connected) {
      throw StateError(
        'node did not reach connected: ${controller.current.phase}',
      );
    }

    final VeilTransport transport;
    try {
      transport = await VeilFlutterTransport.connect(appSocketPath);
    } catch (e) {
      await controller.stop();
      rethrow;
    }

    final invite = await veilBootstrapInvite(
      veilCliPath: veilCliPath,
      configPath: configPath,
    );
    return RealVeilStack._(
      controller: controller,
      transport: transport,
      myInvite: invite,
      veilCliPath: veilCliPath,
      configPath: configPath,
    );
  }

  /// Redeem a peer's invite so this node dials it — forms the bidirectional
  /// session veil's directional dedup needs. (Pair with the peer redeeming
  /// ours.) Uses the node's own IPC on the deniable path, `veil-cli` on the
  /// config-file dev path.
  Future<void> addContact(BootstrapInvite peer) {
    // IDENTITY-ONLY invite (no transport): there is nothing to dial — the
    // contact is reached by node_id over rendezvous, and the chat is keyed by
    // node_id. A `bootstrap join` here would add a useless (or loopback)
    // bootstrap peer. Only redeem invites that actually carry a dialable peer.
    if (peer.transport == null) return Future.value();
    final ft = _flutterTransport;
    if (ft != null) return ft.joinInvite(peer.toUri());
    return veilBootstrapJoin(
      veilCliPath: _cli!,
      configPath: _config!,
      inviteUri: peer.toUri(),
    );
  }

  /// Tear the stack down: three INDEPENDENT legs, in reverse build order.
  ///
  /// This was a straight `await` chain, and the last link is what makes that a
  /// privacy failure rather than untidiness. A throw from `transport.dispose()`
  /// — an IPC socket that will not close, an FFI stop on a handle already freed
  /// — skipped both the node stop and the runtime-dir removal, and the runtime
  /// dir holds the sockets and the public obfs4 PSK: the plaintext trace that
  /// identities RAN on this machine. Deniability is not something to lose to
  /// somebody else's exception (audit XV-12).
  ///
  /// Sequential on purpose — order matters during teardown — but a failing leg
  /// no longer cancels the ones after it. The first error is still rethrown, so
  /// an unclean teardown is not silent; it is just no longer paid for with the
  /// rest of the teardown.
  Future<void> dispose() async {
    final failure = await runCleanupLegs('veil-stack', [
      ('transport', transport.dispose),
      // Before the node stops: this is an IPC connection TO it, and a handle
      // left open is one more reason the node's shutdown waits.
      ('ratchet handle', () async => ratchetState?.close()),
      ('controller', controller.stop),
      // Through the LEASE, which deletes only the directory this boot created
      // and only while it can still prove that is what it is looking at. The
      // bare `delete(recursive: true)` this replaced would have removed
      // whatever the configured path happened to name (audit C-02).
      ('runtime dir', () async => _runtimeLease?.release()),
    ]);
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
  }
}
