import 'dart:io';

import 'package:xveil/core/log.dart';

import 'veil_stack.dart' show runtimeDirIsOurs;

/// The names this project's runtime-dir generator ACTUALLY produces.
///
/// `claimRuntimeDirUnder` names the directory after the pid, and appends
/// `-<attempt>` when that name is already taken — so `xveil-rt-4321-1` is one
/// of ours, and on a busy or recycled-pid host it is the common case rather
/// than the exotic one.
///
/// The sweeper used to take everything after `xveil-rt-` and parse it as an
/// integer. On a collision name that yields null, and null meant "skip". Not
/// "skip this time": the name never changes, so the directory was skipped by
/// every launch, forever. Inside it are the node's unix sockets and the public
/// obfuscation key — no attacker anywhere in this, just a permanent record on
/// disk that an identity ran here, which is the one thing this directory is
/// deleted to avoid (audit XV-14).
final RegExp _ourRuntimeDirName = RegExp(r'^xveil-rt-(\d+)(?:-(\d+))?$');

/// Runtime working directories the embedded node makes for itself.
///
/// Desktop only, and only when TMPDIR does not point inside our runtime dir;
/// otherwise these are nested under ours and go when it goes.
const _nodeWorkDirPrefix = 'veil-deferred-';

/// True when the process with [otherPid] is still alive (POSIX `kill -0`).
///
/// Conservative: any error — no `kill` binary, no permission — counts as ALIVE,
/// so a sweep never removes a live instance's runtime dir.
Future<bool> defaultPidAlive(int otherPid) async {
  try {
    final r = await Process.run('kill', ['-0', '$otherPid']);
    return r.exitCode == 0;
  } catch (_) {
    return true;
  }
}

/// Most recent mtime under [dir] (the dir itself + every file inside). Errors
/// on individual entries are skipped — the sweep must never throw.
Future<DateTime> newestMtimeUnder(Directory dir) async {
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

/// Best-effort reaper for per-run directories that only a GRACEFUL exit
/// removes. Returns how many it took.
///
///  - `xveil-rt-<pid>` and `xveil-rt-<pid>-<attempt>`: our unix sockets, the
///    public obfs4 PSK, and the node's nested working dir with its
///    preallocated ~1.5 MB outbox.db;
///  - desktop-only sibling `veil-deferred-*` directories.
///
/// Android force-stop, an OOM kill and a stand's `kill -9` never run the
/// teardown that would remove these, so they accumulate one per launch.
///
/// THIS CODE DELETES, RECURSIVELY, so what it will not touch matters more than
/// what it will. One of ours is reclaimed only when the name is a name we
/// generate, the pid in it is dead, AND the ownership marker we wrote at
/// creation is still inside it. The marker is the load-bearing one: matching on
/// the NAME alone is how a sweeper becomes a weapon, since anything that can
/// create `xveil-rt-<some dead pid>` in the base — a shared `/tmp`, an
/// operator's `XVEIL_RUNTIME_DIR`, another user — could aim a recursive delete
/// wherever it liked.
///
/// A `veil-deferred-*` directory cannot carry that marker: veil creates it, not
/// us, so there is nothing of ours to find inside. It is reclaimed on the
/// weaker evidence it does have — the exact name, plus a full day in which
/// nothing inside was touched (a live node keeps writing its outbox.db) — and
/// that asymmetry is deliberate rather than an oversight.
Future<int> sweepStaleRuntimeDirs(
  String runtimeBase, {
  Duration staleAfter = const Duration(hours: 24),
  int? selfPid,
  bool singleInstanceHost = false,
  Future<bool> Function(int pid)? pidAlive,
  DateTime Function()? now,
}) async {
  final self = selfPid ?? pid;
  final alive = pidAlive ?? defaultPidAlive;
  final clock = now ?? DateTime.now;
  // Mobile runs a single instance per package, so any pid but ours is a dead
  // launch. Desktop keeps a directory whose pid is still alive (dev
  // multi-instance); a recycled pid there merely defers the reclaim to the
  // OS's periodic temp cleanup, which is never worth risking a live dir over.
  final singleInstance =
      singleInstanceHost || Platform.isAndroid || Platform.isIOS;
  var removed = 0;
  try {
    await for (final e in Directory(runtimeBase).list(followLinks: false)) {
      // A symlink is not a directory here (followLinks: false), so a link
      // planted under our name is skipped rather than followed into.
      if (e is! Directory) continue;
      final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      try {
        final ours = _ourRuntimeDirName.firstMatch(name);
        if (ours != null) {
          final dirPid = int.parse(ours.group(1)!);
          if (dirPid == self) continue;
          if (!singleInstance && await alive(dirPid)) continue;
          if (!runtimeDirIsOurs(e.path)) {
            devLog(
              () =>
                  'xVeil[sweep]: $name carries our name but not our marker — '
                  'leaving it alone',
            );
            continue;
          }
        } else if (name.startsWith(_nodeWorkDirPrefix)) {
          // No pid in the name — recency is the only signal, measured on the
          // NEWEST file inside (the directory's own mtime is frozen at
          // creation). A full day of silence inside means no node owns it.
          if (clock().difference(await newestMtimeUnder(e)) < staleAfter) {
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
  return removed;
}
