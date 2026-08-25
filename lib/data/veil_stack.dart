import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart' show visibleForTesting;

import 'package:xveil/core/cleanup_legs.dart';
import 'package:xveil/core/secret_wipe.dart' show wipeSecretBytes;
import 'package:xveil/core/posix_file_facts.dart';

import 'native_libs.dart' show openEnvLib, processLibFor;
// The DECISION only, never `bundled_seeds_prefs.dart`: the preference store is
// package:shared_preferences, which is package:flutter, and this file is on the
// headless daemon's import path — one such import stopped `dart build cli`
// producing the daemon at all while every app build stayed green (709f3b9).
import 'node/bundled_seeds.dart'
    show bundledSeedsAllowedFromSpace, kBundledSeedsDefault;
import 'node/dht_participation.dart';
import 'node/embedded_node.dart';
import 'node/identity_config_fields.dart';
import 'node/node_controller.dart';
import 'node/proxy_routing.dart';
import 'node/ratchet_ffi.dart'
    show
        FfiRatchetStateHandle,
        RatchetStateHandle,
        dropRejectedRatchetStates,
        importRatchetStates,
        loadStoredRatchetStates,
        recoverReservedSendPositions;
import 'node/sovereign_identity_material.dart';
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

/// What a document-side revocation actually accomplished.
///
/// A bool could not carry this: "already tombstoned" and "could not
/// tombstone" both read as false, and the difference is the whole security
/// question. The first means the key is dead — a retry of a revocation that
/// already landed, which is the ordinary shape of a repair — while the second
/// means the document still vouches for a device the operator believes they
/// just revoked. Reported live 2026-08-18 as one indistinguishable `false`.
enum DocumentRevocation {
  /// A master-signed tombstone was written for this device id by this call.
  tombstoned,

  /// The document already carried the tombstone. The key is dead; there was
  /// simply nothing left to do.
  alreadyTombstoned,

  /// The document was NOT amended: no usable sovereign material, the wrong
  /// credential (a certificate identity cannot be revoked through the phrase
  /// path), a refusal from the native guard, or an I/O failure. The device's
  /// key remains certified — callers must not report a revocation.
  failed;

  /// Whether the device's key is now out of the document, however it got
  /// there.
  bool get keyIsRetired => this != DocumentRevocation.failed;
}

/// What a delegation into the identity document actually accomplished.
///
/// Same reason [DocumentRevocation] exists: a bool collapsed "this key is
/// already in the document" — the ordinary shape of a re-link, and a success
/// — with "the document was not amended", which leaves the group trusting a
/// key no master ever certified. The linking ceremony proceeded on both,
/// producing a half-linked device whose every row fails verification on every
/// peer. Reported 2026-08-18.
enum DeviceDelegation {
  /// The document now names this device key, added by this call.
  delegated,

  /// The document already named it. A re-link, or a retry of a delegation
  /// that landed.
  alreadyPresent,

  /// The document was NOT amended: no usable sovereign material, a credential
  /// that cannot derive this identity's master, the key limit, or an I/O
  /// failure. The ceremony must stop — a group membership added on top of
  /// this is a device the identity does not vouch for.
  failed;

  /// Whether the document names the device key, however it got there.
  bool get documentNamesDevice => this != DeviceDelegation.failed;
}

/// The identity document holds a master-signed tombstone for this device id,
/// so its key can never be vouched for again — relinking requires a freshly
/// minted device key.
///
/// Its own type because the linking ceremony has a GROUP half that knows
/// nothing about tombstones: a swallowed refusal here lets the group admit
/// the id anyway, producing a member frames queue to that no verifier
/// accepts. Callers abort the whole ceremony on this.
class TombstonedDeviceException implements Exception {
  TombstonedDeviceException(this.message);

  final String message;

  @override
  String toString() => message;
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

/// Why a deniable boot did not reach [NodePhase.connected], in words that
/// survive a shipped build.
///
/// The first Windows report of this failure read, in full:
/// `deniable node did not connect: NodePhase.stopped (null)`. That is not a
/// diagnosis, and it could not have been one: `NodeStatus.stopped` is a const
/// whose `message` is null, so a boot that never left its initial state has
/// nothing to say, and everything that WOULD have said something goes through
/// `devLog`, which a release build compiles out. The only record left of how
/// far the boot got is the runtime directory, and the old code threw it away —
/// the cleanup that stops the node deletes the directory — before anyone could
/// look.
///
/// So the directory listing is folded into the message. What is in there is
/// exactly the fork:
///
///  - only the claim marker: the node bound nothing and this app wrote nothing
///    either — the failure is before, or inside, the node's own start;
///  - `obfs4_psk.b64` but no port sidecars: this app got as far as staging its
///    config and the node still bound nothing;
///  - `ipc.port` / `ipc.token`: the node DID bind, and the app failed to reach
///    a node that was running.
///
/// Names only, never contents. `obfs4_psk.b64` is a file whose presence is
/// evidence and whose bytes are the deployment key.
///
/// Pure, so every branch is reachable from a test without a node, a container
/// or a platform.
String describeBootFailure({
  required NodePhase phase,
  required String? message,
  required List<String> runtimeDirEntries,
  bool? hadObfs4Psk,
}) {
  final names = [...runtimeDirEntries]..sort();
  final bound = names.any((n) => n == 'ipc.port' || n == 'admin.port');
  final staged = names.contains('obfs4_psk.b64');

  final String reading;
  if (names.isEmpty) {
    reading =
        'the runtime directory is empty — not even the claim marker, so '
        'this app never finished claiming it';
  } else if (bound) {
    reading =
        'the node DID bind (port sidecars are present) and this app did '
        'not reach it';
  } else if (staged) {
    reading = 'this app staged its config and the node bound nothing';
  } else {
    reading =
        'nothing was written past the claim marker: the node bound '
        'nothing and this app did not get as far as staging its config';
  }

  // `message` is the one part that may legitimately be absent, so it is never
  // interpolated bare — "(null)" is what made the original report useless.
  final said = (message == null || message.isEmpty)
      ? 'the node reported no reason'
      : 'the node said "$message"';

  // Stated rather than inferred from the listing. "No obfs4_psk.b64 in the
  // directory" has two very different causes — the app had no key to write, or
  // it had one and never got that far — and reading the absence the wrong way
  // sends the next investigation at the wrong half of the system. This is known
  // for certain at the moment of failure, so it is said out loud.
  //
  // `_loadBundledObfs4Psk` returns null both for "clean clone, no asset" and
  // for "asset is there and could not be read", which is why a shipped build
  // that quietly has no key looks exactly like a developer build that never
  // had one.
  final key = hadObfs4Psk == null
      ? ''
      : hadObfs4Psk
      ? '; the app did have an obfs4 key'
      : '; the app had NO obfs4 key — without one every bootstrap peer is '
            'refused by the transport before any handshake';

  return '$phase — $said; $reading$key '
      '[runtime dir: ${names.isEmpty ? '<empty>' : names.join(', ')}]';
}

/// The names in [runtimeDir], for [describeBootFailure].
///
/// Never throws: this runs on the failure path, and a diagnosis that can itself
/// fail is how the original error came to say nothing at all.
List<String> _runtimeDirEntries(String runtimeDir) {
  try {
    return Directory(runtimeDir)
        .listSync(followLinks: false)
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .toList();
  } catch (e) {
    return ['<unreadable: $e>'];
  }
}

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
    throw RuntimeDirNotPrivate(
      dir,
      'refusing to claim a directory we did not create',
    );
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
  Timer? _heartbeat;

  /// How often the marker's mtime is refreshed while this lease is held.
  ///
  /// The sweep reads that mtime as "somebody is still here" on a platform
  /// where process liveness cannot be asked for — Windows (report12 X-M11).
  /// Before this, recency meant the newest mtime anywhere under the tree,
  /// which an IDLE but perfectly alive sibling never moves: it does no I/O,
  /// so after a day of quiet its directory was reclaimed out from under it.
  ///
  /// Far below the sweep's staleness window, so a missed tick or two costs
  /// nothing, and one file timestamp an hour is not a cost worth measuring.
  static const Duration heartbeatEvery = Duration(minutes: 15);

  /// Bases nothing may be leased directly on top of.
  ///
  /// The lease only ever removes its own child, so these are belt-and-braces —
  /// but `/` or `$HOME` in a runtime-dir field is a configuration mistake worth
  /// naming at the moment it is made rather than a location worth using.
  static bool _forbiddenBase(String base) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final normalized =
        base.length > 1 && (base.endsWith('/') || base.endsWith(r'\'))
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
  /// Refresh the marker's mtime now, and keep doing it until release.
  ///
  /// Separate from [acquire] so a caller that only wants the directory (a
  /// test, a one-shot tool) does not leave a timer behind, and so the touch
  /// itself is drivable without waiting a quarter of an hour.
  void startHeartbeat() {
    _heartbeat?.cancel();
    touchLease();
    _heartbeat = Timer.periodic(heartbeatEvery, (_) => touchLease());
  }

  /// One heartbeat. Best-effort: a marker that cannot be touched is not a
  /// reason to bring anything down, and the sweep's other guards — the pid,
  /// the marker's presence, its secret — all still stand.
  @visibleForTesting
  void touchLease() {
    if (_released) return;
    try {
      File('$path/$kRuntimeDirMarker').setLastModifiedSync(DateTime.now());
    } catch (_) {}
  }

  Future<String?> release() async {
    _heartbeat?.cancel();
    _heartbeat = null;
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

/// A link ceremony offered a document this device would not take in.
class SovereignDocumentRefused implements Exception {
  const SovereignDocumentRefused();

  @override
  String toString() =>
      'SovereignDocumentRefused: the identity document was not adopted — it '
      'does not name this device, or is not this family\'s document';
}

/// Take in a ceremony partner's identity document, or end the ceremony.
///
/// Returns whether the running node needs to be handed the new material
/// (adopted); false means this device already held exactly that document, or
/// none was offered, and there is nothing to publish.
///
/// Throws [SovereignDocumentRefused] when the document was NOT taken in. That
/// case used to be indistinguishable from "nothing changed" — the same `false`
/// — and all three ceremony paths carried on regardless, so a device could
/// finish linking to a family whose document it does not hold: publishing a
/// registry naming itself alone, sealing for nobody. The usual reason for a
/// refusal is that the document does not name this device's key, or is not
/// this family's document at all, which is exactly what a substituted ceremony
/// produces.
///
/// [merge] and [adoptNamed] are the same injection seams
/// [RealVeilStack.adoptSovereignDocument] takes, so this rule is testable
/// without a dylib.
Future<bool> adoptCeremonyDocument(
  Storage storage, {
  required Uint8List document,
  required String stagingBase,
  Future<void> Function(String identityToml, String veilDir, Uint8List document)?
  merge,
  Future<void> Function(String identityToml, String veilDir, Uint8List document)?
  adoptNamed,
}) async {
  final outcome = await RealVeilStack.adoptSovereignDocument(
    storage,
    document: document,
    stagingBase: stagingBase,
    merge: merge,
    adoptNamed: adoptNamed,
  );
  if (outcome == SovereignDocumentAdoption.refused) {
    throw const SovereignDocumentRefused();
  }
  return outcome == SovereignDocumentAdoption.adopted;
}

/// What came of an attempt to take in another device's identity document.
///
/// This used to be a bare `bool`, and of its eight false paths exactly one was
/// benign — "we already hold this document", which ends the exchange instead of
/// trading identical documents forever. The other seven are refusals, and one
/// of them is the security-relevant case: the native adopt threw because the
/// document does not name this device's key, or is not this family's document
/// at all. A link ceremony read all eight the same way and carried on, so a
/// device could finish linking to a family whose document it does not hold —
/// publishing a registry naming itself alone, and sealing for nobody.
enum SovereignDocumentAdoption {
  /// Merged, and the material written.
  adopted,

  /// Already exactly what this device holds. Nothing to do, nothing wrong.
  alreadyHeld,

  /// No document was offered.
  nothingOffered,

  /// The document was NOT taken in: it does not name this device, this device
  /// has no material to merge under, or the merge left it incomplete. A
  /// ceremony must stop here rather than treat it as "no change needed".
  refused,
}

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
    this.embeddedNode,
    this.identityDir,
    List<BootstrapPeerCfg> registeredSeeds = const [],
    Future<void> Function(String uri)? joinEndpoint,
  }) : _cli = veilCliPath,
       _config = configPath,
       _flutterTransport = nodeIpc,
       // An initializing formal is what the analyzer asks for and what Dart
       // forbids here: these are NAMED parameters, and a named parameter
       // cannot begin with an underscore, so `this._registeredSeeds` does not
       // compile. The fields stay private because nothing outside this class
       // has business with them.
       // ignore: prefer_initializing_formals
       _registeredSeeds = registeredSeeds,
       // ignore: prefer_initializing_formals
       _joinEndpoint = joinEndpoint;

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

  /// The seed set this boot registered, kept for [redialSeeds]. Empty on
  /// paths that never dialed (fakes, config-driven boots).
  final List<BootstrapPeerCfg> _registeredSeeds;
  final Future<void> Function(String uri)? _joinEndpoint;

  /// Re-dial the boot's seed set over the SAME join primitive the boot used.
  ///
  /// The lifecycle-resume half of the suspended-node defect: an Android node
  /// that lost its overlay sessions in the background comes back DARK — zero
  /// inbound from anyone, senders' "live leg ok" a fiction — and nothing in
  /// the runtime re-dials on its own. Measured live 2026-08-17: only a full
  /// app restart revived it. Joining an already-live session is a cheap
  /// no-op, so calling this on every resume is safe.
  Future<int> redialSeeds() async {
    final join = _joinEndpoint;
    if (join == null || _registeredSeeds.isEmpty) return 0;
    final n = await registerRuntimeBootstrapPeers(_registeredSeeds, join);
    devLog(
      () =>
          'xVeil[bootstrap]: resume redial — '
          '$n/${_registeredSeeds.length} seed(s) joined',
    );
    return n;
  }
  final BootstrapInvite myInvite;

  /// The running node and the directory it reads its identity from — the two
  /// things [refreshSovereignIdentity] needs and nothing else should touch.
  /// Public only because a private name cannot be a named parameter; treat them
  /// as read-only.
  final EmbeddedNode? embeddedNode;
  final String? identityDir;

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
    // The phrase names an identity that already exists elsewhere. The FIRST
    // device of an identity takes the phrase's own keypair as its node key —
    // that is what makes `node_id` recoverable from the words. Every LATER
    // device must mint one of its own: two devices holding the same node key
    // are one node, they cannot link ("self device"), and both would drive the
    // same ratchets. What ties the new key to the identity is the sovereign
    // document, not the key itself.
    bool restoringIdentity = false,
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
      if (restoringIdentity) {
        // BOTH at once. This device boots on a key of its own, and it still
        // needs the master's key AND nonce to hand out an invite contacts can
        // address the identity by. Sequentially that is two waits; in parallel
        // it is about one on any machine with a spare core, which is what makes
        // a second device cost what the first one did.
        final mined = await Future.wait([
          lib == null
              ? Isolate.run(_mineConfigInIsolate)
              : Future.value(EmbeddedNode.mineConfig(0, lib: lib)),
          lib == null
              ? Isolate.run(() => _configFromPhraseInIsolate(phrase))
              : Future.value(EmbeddedNode.configFromPhrase(phrase, lib: lib)),
        ]);
        identityToml = mined[0];
        await storage.putSetting(kMasterConfigSetting, mined[1]);
        origin = 'restored-device';
      } else {
        identityToml = lib == null
            ? await Isolate.run(() => _configFromPhraseInIsolate(phrase))
            : EmbeddedNode.configFromPhrase(phrase, lib: lib);
        origin = 'phrase';
      }
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

  /// Provision this device's sovereign identity ONCE, and hand back the
  /// material to be laid out before every later boot.
  ///
  /// Only the phrase path can do this, and that is the whole point: a mined
  /// identity has no master behind it, so the degenerate document the node
  /// builds for itself is the truthful description of a single device. A
  /// phrase, by contrast, IS a master — several devices can stand under it,
  /// and until this material exists none of them can, because the node keeps
  /// answering that master and device are the same key.
  ///
  /// Returns null when there is nothing to provision (no phrase) — the caller
  /// boots exactly as before, which is what keeps this change additive for
  /// every identity already in the field.
  static Future<Map<String, Uint8List>?> ensureSovereignIdentity(
    Storage storage, {
    required String stagingBase,
    String? identityPhrase,
    DynamicLibrary? lib,
    String instanceLabel = 'xveil',
    // The native call, as an argument, so that "this never provisions twice"
    // is checkable by counting rather than by hoping a dylib fails to load.
    // The invariant is worth that: a second provisioning mints a second device
    // key and orphans the document already published for this identity.
    Future<void> Function(String phrase, String veilDir)? provision,
  }) async {
    final stored = await storage.getSetting(kSovereignIdentitySetting);
    if (stored != null) {
      final decoded = decodeSovereignIdentity(stored);
      // A stored entry that will not decode is NOT a reason to provision a
      // second time: minting a fresh device key would orphan the document
      // already published under this identity. Boot degenerate and say so —
      // the material is recoverable from the phrase, a stale published
      // document is not.
      if (decoded == null ||
          missingSovereignIdentityFiles(decoded).isNotEmpty) {
        devLog(
          () =>
              'xVeil[identity]: stored sovereign material is unusable '
              '(${decoded == null ? 'undecodable' : missingSovereignIdentityFiles(decoded).join(', ')}) '
              '— booting without it',
        );
        return null;
      }
      return decoded;
    }
    if (identityPhrase == null || identityPhrase.isEmpty) return null;

    // Provisioning writes MASTER-DERIVED material to disk, so it happens in a
    // directory this call creates and removes, under the app's own runtime
    // base rather than a shared temp — and the bytes reach the container
    // before the directory goes away.
    final staging =
        '$stagingBase/xveil-idprov-${Random.secure().nextInt(1 << 32)}';
    try {
      await Directory(staging).create(recursive: true);
      if (provision != null) {
        await provision(identityPhrase, staging);
      } else {
        // THE KEY THIS DEVICE ALREADY RUNS ON. Provisioning otherwise mints a
        // second one and names it in the document, so the node signs with its
        // own key while the document vouches for another — and every signature
        // the device makes fails its own author binding, without a word.
        //
        // Read here rather than passed in because the ordering is already
        // right: the node config is written before any of this runs, on both
        // the phrase and the restore paths. Null on a first run that has none
        // yet, where the key comes from the phrase and there is nothing to
        // reconcile.
        EmbeddedNode.provisionSovereignIdentity(
          identityPhrase,
          veilDir: staging,
          instanceLabel: instanceLabel,
          nodeConfigToml: await storage.loadNodeConfig(),
          lib: lib,
        );
      }
      final files = await collectSovereignIdentity(staging);
      final missing = missingSovereignIdentityFiles(files);
      if (missing.isNotEmpty) {
        devLog(
          () =>
              'xVeil[identity]: provisioning left no ${missing.join(', ')} '
              '— booting without a sovereign document',
        );
        return null;
      }
      await storage.putSetting(
        kSovereignIdentitySetting,
        encodeSovereignIdentity(files),
      );
      // The master, kept apart from the node config. Admitting a further device
      // needs it long after the phrase is gone, and the config only carries it
      // while the config IS the master — which stops being true the moment a
      // device gets a transport key of its own.
      if (provision == null) {
        try {
          final master = EmbeddedNode.masterKeyFromPhrase(
            identityPhrase,
            lib: lib,
          );
          await storage.putSetting(kMasterKeySetting, base64.encode(master));
          wipeSecretBytes(master);
        } on Object catch (e) {
          devLog(() => 'xVeil[identity]: could not keep the master key: $e');
        }
      }
      devLog(
        () =>
            'xVeil[identity]: sovereign identity provisioned '
            '(${files.length} files, this device has its own key)',
      );
      return files;
    } on Object catch (e) {
      // A device that cannot provision still has a working node — it is the
      // one-device case, which is what it was before this existed.
      devLog(
        () => 'xVeil[identity]: could not provision sovereign identity: $e',
      );
      return null;
    } finally {
      try {
        await Directory(staging).delete(recursive: true);
      } on FileSystemException {
        // Nothing was created, or it is already gone.
      }
    }
  }

  /// The address this identity RECEIVES under, or null when this device has no
  /// sovereign document.
  ///
  /// Not the same question as "what is my node id". The node speaks on the wire
  /// under its `[identity]` config key, and that is what a peer authenticates
  /// against. But a sender seals mail to an IDENTITY — node_id → document →
  /// registry → one envelope per device — and an identity with several devices
  /// has ONE address for all of them.
  ///
  /// The two are the same 32 bytes for every identity in the field, because a
  /// phrase-provisioned config key IS the master the document names. They part
  /// company once a device is given a transport key of its own, and from that
  /// moment a device that keeps publishing its rendezvous ad and polling its
  /// mailbox under the transport id is waiting where nobody sends — while
  /// looking reachable from every angle.
  ///
  /// Null is the honest answer for a mined identity: there is no master, the
  /// node's degenerate document names only itself, and the config id is the
  /// whole story.
  static Future<Uint8List?> sovereignReceiveAddress(
    Storage storage, {
    DynamicLibrary? lib,
    Uint8List Function(Uint8List document)? readNodeId,
  }) async {
    final raw = await storage.getSetting(kSovereignIdentitySetting);
    if (raw == null) return null;
    final files = decodeSovereignIdentity(raw);
    final doc = files?[kIdentityDocumentFile];
    if (doc == null || doc.isEmpty) return null;
    try {
      return readNodeId != null
          ? readNodeId(doc)
          : EmbeddedNode.identityDocumentNodeId(doc, lib: lib);
    } on Object catch (e) {
      // A document we cannot read is not a reason to receive nowhere: the
      // caller falls back to the config id, which is the correct answer for
      // every identity that has no document anyway.
      devLog(() => 'xVeil[identity]: could not read the receive address: $e');
      return null;
    }
  }

  /// This device's stored identity document, or null when it has none.
  ///
  /// One reader, because the ceremony moves this document in BOTH directions —
  /// out with the device-link invite and back with the link token — and two
  /// copies of "where the document lives" is one copy too many.
  static Future<Uint8List?> storedSovereignDocument(Storage storage) async {
    final raw = await storage.getSetting(kSovereignIdentitySetting);
    if (raw == null) return null;
    final doc = decodeSovereignIdentity(raw)?[kIdentityDocumentFile];
    return (doc == null || doc.isEmpty) ? null : doc;
  }

  /// Hand a document merged AFTER the boot to the running node.
  ///
  /// The node reads `identity_document.bin` when a config is applied, and
  /// publishes its instance registry from what it read. Merging a sibling's
  /// document into storage therefore changes nothing anyone can see: the node
  /// goes on publishing a registry naming one instance, sealing for "my other
  /// devices" keeps finding none, and the snapshot that would carry the merge
  /// onward is deposited for nobody. Measured on the stand, this was the whole
  /// of the remaining gap -- the merge said `merged=true` and the registry
  /// still said `instances=1`.
  ///
  /// So the material is laid back into the directory the node reads and the
  /// node is told to read it again.
  ///
  /// Told, not made to. This used to re-apply the same config, because a config
  /// apply happens to re-read the document on its way past — and it gets there
  /// by stopping and restarting every service the node runs, which takes every
  /// IPC connection the app holds down with it. On the stand the link succeeded
  /// and then every single mailbox deposit failed with `connection closed`, for
  /// the rest of the session. `reloadIdentity` is the same re-read with none of
  /// the rest of it.
  Future<bool> refreshSovereignIdentity(Storage storage) async {
    final node = embeddedNode;
    final dir = identityDir;
    if (node == null || dir == null) return false;
    final raw = await storage.getSetting(kSovereignIdentitySetting);
    if (raw == null) return false;
    final files = decodeSovereignIdentity(raw);
    if (files == null || missingSovereignIdentityFiles(files).isNotEmpty) {
      return false;
    }
    await materialiseSovereignIdentity(dir, files);
    node.reloadIdentity();
    devLog(() => 'xVeil[identity]: document re-read by the running node');
    return true;
  }

  /// Delegate [devicePubkey] into THIS identity's document, master-signed.
  ///
  /// The missing half of linking. [GroupService.linkDevice] admits the new
  /// device into the GROUP — membership, epochs, history — and nothing ever
  /// amended the DOCUMENT: the registry kept advertising yesterday's
  /// instances (measured: reg_version frozen for a day across three links
  /// and two revocations), mailbox envelopes for the identity missed the
  /// new device, and every row it later signed with its subkey failed
  /// verification on any THIRD device — a linked phone deterministically
  /// missing exactly the second device's rows. The native machinery for
  /// this existed end to end (`veil_delegate_device_from_phrase`); nothing
  /// called it.
  ///
  /// Same copy-first staging discipline as [adoptSovereignDocument]: a
  /// delegation that fails half way must not leave this device holding a
  /// document it cannot sign with. `AlreadyPresent` from a re-link surfaces
  /// as "nothing changed" — false, quietly. A TOMBSTONED device is the one
  /// refusal that must not be quiet: it throws [TombstonedDeviceException],
  /// because the ceremony around this call has a group half that would
  /// happily admit the id, and "false" here reads as "no change needed".
  static Future<DeviceDelegation> delegateDeviceIntoDocument(
    Storage storage, {
    required String phrase,
    required Uint8List devicePubkey,
    required String stagingBase,
    DynamicLibrary? lib,
  }) async {
    if (phrase.isEmpty || devicePubkey.length != 32) {
      return DeviceDelegation.failed;
    }
    final storedRaw = await storage.getSetting(kSovereignIdentitySetting);
    if (storedRaw == null) return DeviceDelegation.failed;
    final stored = decodeSovereignIdentity(storedRaw);
    if (stored == null || missingSovereignIdentityFiles(stored).isNotEmpty) {
      devLog(
        () =>
            'xVeil[identity]: cannot delegate a device — this device has no '
            'usable sovereign material',
      );
      return DeviceDelegation.failed;
    }
    final staging =
        '$stagingBase/xveil-iddelegate-${Random.secure().nextInt(1 << 32)}';
    try {
      await materialiseSovereignIdentity(staging, stored);
      EmbeddedNode.delegateDeviceFromPhrase(
        phrase,
        veilDir: staging,
        devicePubkey: devicePubkey,
        lib: lib,
      );
      final amended = await collectSovereignIdentity(staging);
      if (missingSovereignIdentityFiles(amended).isNotEmpty) {
        return DeviceDelegation.failed;
      }
      final encoded = encodeSovereignIdentity(amended);
      if (encoded == storedRaw) return DeviceDelegation.failed;
      await storage.putSetting(kSovereignIdentitySetting, encoded);
      devLog(
        () =>
            'xVeil[identity]: delegated a device subkey into the document — '
            'the registry and every verifier now learn the new device',
      );
      return DeviceDelegation.delegated;
    } on Object catch (e) {
      // The tombstone refusal must ABORT the caller's ceremony, not blend
      // into "nothing changed": measured live — the linking flow swallowed
      // it, admitted the id into the device group anyway (control seq 11),
      // and the "linked" device became a half-ghost frames queue to while no
      // verifier anywhere accepts its rows. The message substring is the
      // native DelegateDeviceError::Revoked text — the FFI's only channel.
      if ('$e'.contains('is REVOKED in this document')) {
        throw TombstonedDeviceException('$e');
      }
      // AlreadyPresent is a SUCCESS — the document already names this key,
      // which is what a re-link looks like — and it used to be reported with
      // the same `false` as a wrong phrase or missing material, so the
      // ceremony could not tell "nothing to do" from "the identity does not
      // vouch for this device". The native text is the FFI's only channel;
      // it is matched here rather than at the call sites so the distinction
      // exists once.
      if ('$e'.contains('already present as identity_keys[')) {
        return DeviceDelegation.alreadyPresent;
      }
      devLog(() => 'xVeil[identity]: could not delegate the device: $e');
      return DeviceDelegation.failed;
    } finally {
      try {
        await Directory(staging).delete(recursive: true);
      } on FileSystemException {
        // Never created, or already gone.
      }
    }
  }

  /// Retire a revoked device's key from the stored identity document — the
  /// cryptographic half of revocation, run right after the group-membership
  /// half succeeds.
  ///
  /// Same copy-first staging discipline as [delegateDeviceIntoDocument]: a
  /// revocation that fails half way must not leave this device holding a
  /// document it cannot sign with. Returns true when the stored document
  /// changed (callers then refresh the node and announce, exactly like a
  /// delegation).
  static Future<DocumentRevocation> revokeDeviceFromDocument(
    Storage storage, {
    required String phrase,
    required Uint8List deviceId,
    required String stagingBase,
    DynamicLibrary? lib,
  }) async {
    if (phrase.isEmpty || deviceId.length != 32) {
      return DocumentRevocation.failed;
    }
    final storedRaw = await storage.getSetting(kSovereignIdentitySetting);
    if (storedRaw == null) return DocumentRevocation.failed;
    final stored = decodeSovereignIdentity(storedRaw);
    if (stored == null || missingSovereignIdentityFiles(stored).isNotEmpty) {
      devLog(
        () =>
            'xVeil[identity]: cannot revoke a device key — this device has no '
            'usable sovereign material',
      );
      return DocumentRevocation.failed;
    }
    final staging =
        '$stagingBase/xveil-idrevoke-${Random.secure().nextInt(1 << 32)}';
    try {
      await materialiseSovereignIdentity(staging, stored);
      final changed = EmbeddedNode.revokeIdentityDeviceFromPhrase(
        phrase,
        veilDir: staging,
        deviceId: deviceId,
        lib: lib,
      );
      if (!changed) {
        // The native side answers false for exactly one reason: this device
        // id is already in the tombstone list. The key is dead, so this is a
        // success — a revocation retried after it landed, which is what a
        // repair looks like.
        return DocumentRevocation.alreadyTombstoned;
      }
      final amended = await collectSovereignIdentity(staging);
      if (missingSovereignIdentityFiles(amended).isNotEmpty) {
        return DocumentRevocation.failed;
      }
      final encoded = encodeSovereignIdentity(amended);
      if (encoded == storedRaw) return DocumentRevocation.failed;
      await storage.putSetting(kSovereignIdentitySetting, encoded);
      devLog(
        () =>
            'xVeil[identity]: revoked a device key from the document — a '
            'master-signed tombstone now outlives every stale sibling copy',
      );
      return DocumentRevocation.tombstoned;
    } on Object catch (e) {
      // A wrong phrase and a self-revocation are both refused natively
      // before anything is written. A CERTIFICATE identity lands here too:
      // this path derives the master from a phrase, and a recovery code is
      // not one — which is why the caller must never read a failure as a
      // revocation.
      devLog(() => 'xVeil[identity]: could not revoke the device key: $e');
      return DocumentRevocation.failed;
    } finally {
      try {
        await Directory(staging).delete(recursive: true);
      } on FileSystemException {
        // Never created, or already gone.
      }
    }
  }

  /// Adopt an identity document received from ANOTHER device of this identity,
  /// adding this device to it.
  ///
  /// The half of multi-device that cannot be done alone. Two devices set up
  /// from one master phrase each hold a document naming only themselves, and
  /// both carry the same `node_id` — it is BLAKE3 of the master key they both
  /// derived. Both publish under that id, the later publisher displaces the
  /// earlier, and the displaced device stays online believing it is reachable.
  /// One document has to end up naming both keys, and only a device that has
  /// seen the other's document can produce it.
  ///
  /// The master authority comes from the stored node config, not from the
  /// phrase: the phrase is consumed at setup and never kept, and this runs when
  /// devices are linked, which may be days later.
  ///
  /// Returns whether the stored material CHANGED — not whether the merge
  /// succeeded, and the difference is what stops an announcement echoing
  /// forever. Two devices answer each other's documents; the moment one
  /// receives a document it already holds, nothing changes and it falls quiet.
  ///
  /// False — without touching anything — when this device has no sovereign
  /// material of its own, or no config to authorise with. Those are the
  /// mined-identity and legacy cases, where there is no master and so nothing
  /// to delegate under.
  static Future<SovereignDocumentAdoption> adoptSovereignDocument(
    Storage storage, {
    required Uint8List document,
    required String stagingBase,
    DynamicLibrary? lib,
    // The native call as an argument, so the merge policy is testable without
    // a dylib — same reason [ensureSovereignIdentity] takes its provisioner.
    Future<void> Function(
      String identityToml,
      String veilDir,
      Uint8List document,
    )?
    merge,
    // The no-master native call, same injection seam as [merge].
    Future<void> Function(
      String identityToml,
      String veilDir,
      Uint8List document,
    )?
    adoptNamed,
  }) async {
    if (document.isEmpty) return SovereignDocumentAdoption.nothingOffered;
    final storedRaw = await storage.getSetting(kSovereignIdentitySetting);
    if (storedRaw == null) {
      // No sovereign material at all — the mined-identity case: no master, no
      // phrase, nothing to delegate under. What CAN save this device is a
      // document that already NAMES its key, because the master's authority
      // arrives inside it (every subkey is master-signed). The config here
      // holds the device's own key — exactly what the named adopt authorises
      // with. Before this branch existed the return above was silent, and a
      // freshly linked device stayed on documentBytes:0 forever.
      final identityToml = await storage.loadNodeConfig();
      if (identityToml == null) {
        devLog(
          () =>
              'xVeil[identity]: cannot adopt a document — no sovereign '
              'material and no node config to authorise a named adopt with',
        );
        return SovereignDocumentAdoption.refused;
      }
      final staging =
          '$stagingBase/xveil-idadopt-${Random.secure().nextInt(1 << 32)}';
      try {
        if (adoptNamed != null) {
          await adoptNamed(identityToml, staging, document);
        } else {
          EmbeddedNode.adoptIdentityDocumentNamed(
            identityToml,
            veilDir: staging,
            document: document,
            lib: lib,
          );
        }
        final adopted = await collectSovereignIdentity(staging);
        final missing = missingSovereignIdentityFiles(adopted);
        if (missing.isNotEmpty) {
          devLog(
            () =>
                'xVeil[identity]: named adopt left the material incomplete '
                '(${missing.join(', ')})',
          );
          return SovereignDocumentAdoption.refused;
        }
        await storage.putSetting(
          kSovereignIdentitySetting,
          encodeSovereignIdentity(adopted),
        );
        devLog(
          () =>
              'xVeil[identity]: adopted the family document that names this '
              'device — sovereign material created from nothing',
        );
        return SovereignDocumentAdoption.adopted;
      } on Object catch (e) {
        // The usual reason: the document does not name this device's key —
        // either the ceremony partner has not delegated us yet, or the
        // document is not this family's at all.
        devLog(() => 'xVeil[identity]: could not adopt that document: $e');
        return SovereignDocumentAdoption.refused;
      } finally {
        try {
          await Directory(staging).delete(recursive: true);
        } on FileSystemException {
          // Never created, or already gone.
        }
      }
    }
    final stored = decodeSovereignIdentity(storedRaw);
    if (stored == null || missingSovereignIdentityFiles(stored).isNotEmpty) {
      devLog(
        () =>
            'xVeil[identity]: cannot adopt a document — this device has no '
            'usable sovereign material',
      );
      return SovereignDocumentAdoption.refused;
    }
    // The master authority, preferring the key kept for exactly this over the
    // node config. The config answers only while it IS the master; the stored
    // key answers either way.
    final masterRaw = await storage.getSetting(kMasterKeySetting);
    final identityToml = await storage.loadNodeConfig();
    if (masterRaw == null && identityToml == null) return SovereignDocumentAdoption.refused;

    final staging =
        '$stagingBase/xveil-idmerge-${Random.secure().nextInt(1 << 32)}';
    try {
      // The merge happens on a COPY. A delegation that fails half way — a
      // document from another identity, a truncated transfer — must not leave
      // this device holding a document it cannot sign with, which would take it
      // off the network entirely.
      await materialiseSovereignIdentity(staging, stored);
      if (merge != null) {
        await merge(identityToml ?? '', staging, document);
      } else {
        // ONE native call for both directions: append this device when the
        // incoming document does not name it, adopt when it does, and record
        // this device's own subkey index either way — the document's own
        // sig_key_idx names whichever device signed it.
        if (masterRaw != null) {
          final master = base64.decode(masterRaw);
          try {
            EmbeddedNode.adoptIdentityDocumentWithMaster(
              master,
              veilDir: staging,
              document: document,
              lib: lib,
            );
          } on StateError {
            // OUR master derives a DIFFERENT identity than the incoming
            // document — the exact shape of a device with its own identity
            // being linked INTO a family. The master cannot authorise that
            // join, but the document already names this device's key (the
            // ceremony partner delegated it), so the named adopt can: this
            // is the identity switch linking exists to perform. Without the
            // fallback a previously standalone device could never join.
            final toml = identityToml;
            if (toml == null) rethrow;
            EmbeddedNode.adoptIdentityDocumentNamed(
              toml,
              veilDir: staging,
              document: document,
              lib: lib,
            );
          } finally {
            wipeSecretBytes(master);
          }
        } else {
          final toml = identityToml!;
          try {
            EmbeddedNode.adoptIdentityDocument(
              toml,
              veilDir: staging,
              document: document,
              lib: lib,
            );
          } on StateError {
            // The config is a DEVICE key, not the master — true for every
            // linked device past the first. It cannot delegate anything, but
            // it can still take (and union with) a document whose authority
            // is internal: every subkey in it is master-signed. Without this
            // a linked device refuses every later document update.
            EmbeddedNode.adoptIdentityDocumentNamed(
              toml,
              veilDir: staging,
              document: document,
              lib: lib,
            );
          }
        }
      }
      final merged = await collectSovereignIdentity(staging);
      if (missingSovereignIdentityFiles(merged).isNotEmpty) return SovereignDocumentAdoption.refused;
      final encoded = encodeSovereignIdentity(merged);
      // Already what we hold: a device answering our announcement with the
      // document we sent it. Saying "nothing changed" is what ends the
      // exchange instead of trading identical documents forever.
      if (encoded == storedRaw) return SovereignDocumentAdoption.alreadyHeld;
      // Already what we hold: a device answering our announcement with the
      // document we sent it. Saying "nothing changed" is what ends the
      // exchange instead of trading identical documents forever.
      await storage.putSetting(kSovereignIdentitySetting, encoded);
      devLog(
        () =>
            'xVeil[identity]: adopted a document from another device of this '
            'identity and added this one to it',
      );
      return SovereignDocumentAdoption.adopted;
    } on Object catch (e) {
      // A document from a DIFFERENT identity is refused natively, and that is
      // the common case here: it means the sender is not who the ceremony took
      // them for. Nothing has changed, so the device carries on as it was.
      devLog(() => 'xVeil[identity]: could not adopt that document: $e');
      return SovereignDocumentAdoption.refused;
    } finally {
      try {
        await Directory(staging).delete(recursive: true);
      } on FileSystemException {
        // Never created, or already gone.
      }
    }
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
    // A RESTORE: the phrase names an identity that already exists, so this
    // device mints its own node key rather than taking the phrase's. See
    // [ensureNodeConfig].
    bool restoringIdentity = false,
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
    // Read here rather than passed in: unlike the seeds answer this one has no
    // profile-preference history to migrate from, so the space is the only
    // source and the daemon resolves it exactly as the app does.
    final serveDht = await dhtParticipationEffective(storage);
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
      restoringIdentity: restoringIdentity,
      lib: lib,
    );
    devLog(
      () =>
          'xVeil[deniable]: identity ready (${identityToml.length} B) '
          '[+${lap()}ms config]',
    );

    // The sovereign material rides alongside the config: provisioned once from
    // the phrase, stored in the container, laid out into the runtime directory
    // below. Null means "no master behind this identity" (a mined one) or "not
    // provisioned" (everything already in the field) — both boot as before.
    final sovereign = await ensureSovereignIdentity(
      storage,
      stagingBase: runtimeDirBase,
      identityPhrase: identityPhrase,
      lib: lib,
    );

    // 2. Ephemeral, identity-free runtime endpoints, in a directory this boot
    // CREATES under the configured base and owns outright (audit C-02).
    // 2b. Read the stored ratchet sessions NOW, while the only thing that can
    // fail is a container read. They have to be back inside veil before the
    // node can be handed a frame, and the import itself is a synchronous FFI
    // call in the middle of the boot — so the async half is done first, here.
    final storedRatchet = await loadStoredRatchetStates(storage);

    final lease = await RuntimeDirLease.acquire(runtimeDirBase);
    // From here on this process says, on a timer, that the directory is still
    // in use. A sibling launch that cannot ask the OS whether our pid is alive
    // reads that instead of guessing from whatever I/O happened to touch the
    // tree — and an idle instance does none (report12 X-M11).
    lease.startHeartbeat();
    try {
      return await _startDeniableIn(
        lease,
        identityToml: identityToml,
        sovereign: sovereign,
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
        serveDht: serveDht,
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
    required Map<String, Uint8List>? sovereign,
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
    required bool serveDht,
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

    // Filled by the starter below. Kept so a document merged AFTER the boot
    // can be handed to the running node — see [refreshSovereignIdentity].
    EmbeddedNode? embeddedNode;

    // This device's sovereign identity, laid out BEFORE the node starts: the
    // runtime reads `identity_document.bin` from its `veil_dir` exactly once,
    // at construction, and silently builds a degenerate document when the file
    // is not there yet. Late is the same as absent.
    if (sovereign != null) {
      await materialiseSovereignIdentity(runtimeDir, sovereign);
      devLog(
        () =>
            'xVeil[deniable]: sovereign identity laid out '
            '(${sovereign.length} files) — node_id is the master, this device '
            'has its own key',
      );
    }

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
      // Only when there IS material: naming a directory that holds no document
      // changes nothing for the node, but it would move the ML-KEM key and the
      // persisted name claims of every existing identity out of the place veil
      // has always kept them.
      identityDir: sovereign == null ? null : runtimeDir,
      serveDht: serveDht,
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
        final node = embeddedNode = createThenPromote<EmbeddedNode>(
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
      //
      // The evidence is read BEFORE that cleanup, and this order is the whole
      // point: stopping the node takes the runtime directory with it, and the
      // runtime directory is the only thing that distinguishes "the node never
      // bound anything" from "the node bound and this app never reached it".
      // Collected after the cleanup, it would always describe an empty
      // directory.
      final why = describeBootFailure(
        phase: controller.current.phase,
        message: controller.current.message,
        runtimeDirEntries: _runtimeDirEntries(runtimeDir),
        hadObfs4Psk: obfs4Psk != null && obfs4Psk.isNotEmpty,
      );
      await runCleanupLegs('veil-stack-boot', [
        ('controller', controller.stop),
      ]);
      throw StateError('deniable node did not connect: $why');
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
      await runCleanupLegs('veil-stack-boot', [
        ('controller', controller.stop),
      ]);
      rethrow;
    }
    try {
      final rejected = importRatchetStates(ratchetState, storedRatchet);
      // Whatever veil would not take can never open a frame again, so the
      // records go rather than being re-read on every launch forever.
      await dropRejectedRatchetStates(storage, rejected);
      // Before ANY of this app's traffic starts, and right after the states
      // are back: step every conversation past the send indices its last
      // reservation allowed (report12 X-H5). A state whose write never landed
      // is behind what was already published from it, and without this the
      // next send re-derives a key and nonce that a frame on the wire already
      // used. Keys burned here were never emitted, so the peer sees a gap its
      // skipped-key window absorbs.
      if (ratchetState != null) {
        await recoverReservedSendPositions(ratchetState, storage);
      }
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
        devLog(
          () => 'xVeil[ratchet]: aged out $aged unanswered conversation(s)',
        );
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
        masterConfig: await storage.getSetting(kMasterConfigSetting),
        embeddedNode: embeddedNode,
        identityDir: sovereign == null ? null : runtimeDir,
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
    // Where the master's key and nonce live on a device that boots on a key of
    // its own. Null on every identity that boots on the phrase's own key.
    required String? masterConfig,
    // The two things a post-boot document merge needs to reach the running
    // node — see [refreshSovereignIdentity]. Null on the paths that have no
    // in-process node or no sovereign material.
    required EmbeddedNode? embeddedNode,
    required String? identityDir,
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
    // A device running on a key of its OWN must not hand that key out. The
    // address a contact writes down is the hash of the key in the invite, and
    // this device collects mail under the IDENTITY's address — so its own key
    // would have contacts addressing somewhere nobody listens. The master's key
    // and nonce were mined and kept at restore for exactly this.
    //
    // Absent for every identity that boots on the phrase's own key, which is
    // every one in the field: there the node's invite already names the
    // identity, and this falls through to it unchanged.
    final masterFields = masterConfig == null
        ? null
        : identityConfigFields(masterConfig);
    if (masterConfig != null && masterFields == null) {
      devLog(
        () =>
            'xVeil[identity]: the stored master config carries no usable '
            '[identity] — handing out this device\'s own invite, which '
            'contacts would address the DEVICE by',
      );
    }
    final invite = BootstrapInvite(
      publicKey: masterFields?.publicKey ?? veilInvite.publicKey,
      nonce: masterFields?.nonce ?? veilInvite.nonce,
      algo: masterFields?.algo ?? veilInvite.algo,
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
      embeddedNode: embeddedNode,
      identityDir: identityDir,
      registeredSeeds: seedsToRegister,
      joinEndpoint: transport.joinP2PEndpoint,
    );
  }

  /// Dev boot from an existing `config.toml`. [embedded] runs the node
  /// in-process; otherwise it spawns `veil-cli node run`. Still used by the
  /// dev scripts — see the class doc.
  /// Test seam: the controller this boot drives. Production leaves it null and
  /// gets the embedded or subprocess one below.
  ///
  /// Here because the unwind is the thing worth testing and it cannot be
  /// reached otherwise: what has to be proved is that a node which STARTED and
  /// then failed to come up is stopped again, and only a controller that can
  /// be told to fail that way can prove it.
  @visibleForTesting
  static NodeController Function()? debugControllerFactory;

  static Future<RealVeilStack> start({
    required String veilCliPath,
    required String configPath,
    required String appSocketPath,
    bool embedded = false,
  }) async {
    final NodeController controller =
        debugControllerFactory?.call() ??
        (embedded
            ? EmbeddedNodeController(
                configPath: configPath,
                appSocketPath: appSocketPath,
              )
            : veilSubprocessController(
                veilCliPath: veilCliPath,
                configPath: configPath,
                appSocketPath: appSocketPath,
              ));
    await controller.start();
    // From here on there is a STARTED node behind every line, so every way out
    // has to take it down again — a node left running with nobody holding it
    // keeps its sockets, its runtime directory and, on the embedded path, an
    // in-process runtime inside an app that has given up on it (report12
    // X-L5).
    //
    // Two exits used to leave it: a phase that never reached `connected`
    // threw with nothing stopped, and a failing bootstrap invite skipped both
    // the node and the transport. Naming the legs in one place is what keeps
    // the next exit from being a third.
    Future<void> unwind(List<(String, Future<void> Function())> legs) =>
        runCleanupLegs('veil-stack-dev-boot', legs).then((_) {});

    if (controller.current.phase != NodePhase.connected) {
      await unwind([('controller', controller.stop)]);
      throw StateError(
        'node did not reach connected: ${controller.current.phase}',
      );
    }

    final VeilTransport transport;
    try {
      transport = await VeilFlutterTransport.connect(appSocketPath);
    } catch (_) {
      await unwind([('controller', controller.stop)]);
      rethrow;
    }

    final BootstrapInvite invite;
    try {
      invite = await veilBootstrapInvite(
        veilCliPath: veilCliPath,
        configPath: configPath,
      );
    } catch (_) {
      await unwind([
        ('transport', transport.dispose),
        ('controller', controller.stop),
      ]);
      rethrow;
    }
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
