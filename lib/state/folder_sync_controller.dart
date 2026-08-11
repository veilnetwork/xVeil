import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/posix_file_facts.dart';
import '../data/storage/folder_sync_store.dart';
import '../domain/folder_sync.dart';
import 'cloud_service.dart';
import 'folder_sync_adapters.dart';
import 'folder_sync_engine.dart';
import 'folder_sync_scheduler.dart';
import 'providers.dart';

/// One pair as the UI needs to see it: its configuration plus what the last
/// pass made of it.
class FolderSyncPairView {
  const FolderSyncPairView({
    required this.pair,
    required this.conflicts,
    required this.lastPassAtMs,
    required this.lastRefusal,
    required this.busy,
  });

  final FolderSyncPair pair;
  final Set<String> conflicts;
  final int? lastPassAtMs;
  final String? lastRefusal;
  final bool busy;
}

/// Owns the configured pairs and runs their passes.
///
/// Passes are SERIALISED per pair and never overlap: two passes over one
/// folder would each read a base the other is about to rewrite, and the loser
/// would record a state that never existed.
class FolderSyncController extends Notifier<List<FolderSyncPairView>> {
  final Set<String> _running = {};

  /// Long enough that a save, an unpack or our own downloads settle into one
  /// pass; short enough that a person who dropped a file in does not wonder
  /// whether anything is happening.
  static const quietPeriod = Duration(seconds: 3);

  /// The backstop for the signals that never arrive: a watcher the OS killed,
  /// a cloud change this device was not told about.
  static const sweepInterval = Duration(minutes: 5);

  FolderSyncScheduler? _scheduler;

  FolderSyncStore get _store => ref.read(folderSyncStoreProvider);
  FolderSyncEngine? get _engine => ref.read(folderSyncEngineProvider);

  @override
  List<FolderSyncPairView> build() {
    // Automatic passes are DESKTOP only, for the same reason pairs are: a
    // phone has no folder another app writes to, and Directory.watch is not
    // dependable there. Tests get no scheduler either — a background timer
    // outliving a test is how a suite becomes flaky.
    final desktop =
        Platform.isMacOS || Platform.isLinux || Platform.isWindows;
    if (desktop && !Platform.environment.containsKey('FLUTTER_TEST')) {
      final scheduler = FolderSyncScheduler(
        (pair) => runOnce(pair).then((_) {}),
        quietPeriod,
        sweepInterval,
      );
      _scheduler = scheduler;
      ref.onDispose(scheduler.dispose);
      // Another device's edit arrives as a change to the cloud index; nothing
      // local happens, so without this it would wait for the sweep.
      final cloud = ref.read(cloudServiceProvider);
      if (cloud != null) {
        final sub = cloud.watchItems().listen(
          (_) => scheduler.noteRemoteChange(),
        );
        ref.onDispose(sub.cancel);
      }
    }
    unawaited(reload());
    return const [];
  }

  /// Point the scheduler at the pairs that exist now.
  void _rewatch(List<FolderSyncPair> pairs) {
    final scheduler = _scheduler;
    if (scheduler == null) return;
    for (final pair in pairs) {
      final directory = Directory(pair.localPath);
      if (!directory.existsSync()) continue;
      try {
        scheduler.watch(
          pair,
          directory.watch(recursive: true).map((_) {}),
        );
      } catch (_) {
        // Watching can fail outright (no inotify handles left, an unsupported
        // file system). The sweep still covers the pair, so this costs
        // latency rather than correctness.
      }
    }
  }

  Future<void> reload() async {
    final pairs = await _store.pairs();
    final views = <FolderSyncPairView>[];
    for (final pair in pairs) {
      final saved = await _store.state(pair.id);
      views.add(
        FolderSyncPairView(
          pair: pair,
          conflicts: saved.pendingConflicts,
          lastPassAtMs: saved.lastPassAtMs,
          lastRefusal: saved.lastRefusal,
          busy: _running.contains(pair.id),
        ),
      );
    }
    state = views;
    _rewatch([for (final view in views) view.pair]);
  }

  /// Configure [localPath] as a sync root. Null when it was taken; otherwise
  /// why it was refused.
  Future<String?> addPair({
    required String localPath,
    String? cloudFolderId,
    required String id,
  }) async {
    final pairs = [...await _store.pairs()];
    // Refused rather than supported: a file inside two pairs is uploaded
    // twice, under two cloud paths, with two independent bases — nothing is
    // lost, but one file quietly becomes two objects and deleting it locally
    // deletes both, which is impossible to explain to whoever it happens to.
    if (pairs.any((p) => folderPairsOverlap(p.localPath, localPath))) {
      return 'it overlaps a folder that is already synced';
    }
    final unsafe = folderSyncRootRefusal(localPath);
    if (unsafe != null) return unsafe;
    pairs.add(
      FolderSyncPair(id: id, localPath: localPath, cloudFolderId: cloudFolderId),
    );
    await _store.savePairs(pairs);
    await reload();
    return null;
  }

  Future<void> removePair(String id) async {
    final pairs = (await _store.pairs()).where((p) => p.id != id).toList();
    await _store.savePairs(pairs);
    // The remembered base goes with it. Keeping it would make a later re-add
    // of the same folder infer deletions from a picture of the distant past.
    await _store.forget(id);
    _scheduler?.unwatch(id);
    await reload();
  }

  Future<FolderSyncReport?> runOnce(FolderSyncPair pair) async {
    final engine = _engine;
    if (engine == null || !_running.add(pair.id)) return null;
    try {
      // Inside the try, not before it. `_running` is what stops a second pass
      // over the same pair, and the id went in one statement earlier — so a
      // throw from this reload left the pair marked busy for the lifetime of
      // the controller, and the only way to sync that folder again was a
      // restart.
      await reload();
      return await engine.runOnce(pair);
    } finally {
      _running.remove(pair.id);
      await reload();
    }
  }

  Future<void> resolveConflict(
    String pairId,
    String path, {
    required bool keepLocal,
  }) async {
    await _engine?.resolveConflict(pairId, path, keepLocal: keepLocal);
    await reload();
  }
}

/// Why [path] must not become a sync root, or null when it may.
///
/// The mirror writes into this folder on behalf of whatever the cloud account
/// admits, so who ELSE can reach the folder is this app's business and not the
/// user's alone. If any step of the path — the folder itself or an ancestor —
/// may be written by group or by other, another local account can rename or
/// replace it between two passes, and the mirror will then create the user's
/// files under a name that account chose. That is the only arrangement in
/// which this app is a confused deputy: an attacker running as the SAME user
/// gains nothing here they could not do directly.
///
/// ANCESTORS are the point. A leaf-only check looks correct and is not: a
/// perfectly private `0755` folder inside a `0777` parent can simply be
/// swapped for a link to somewhere else, leaf permissions untouched.
///
/// This is a PRECONDITION, not a race fix. The window between this check and a
/// later write stays open — closing that needs descriptor-relative `openat`
/// with `O_NOFOLLOW`, which `dart:io` does not expose (see the note on
/// `mirrorPathWithin`). What the gate removes is the setting in which the
/// window has somebody else standing in it.
///
/// Both the path as given and the path with its links resolved are walked, for
/// the reason the privileged-launch guard walks both: the resolved chain says
/// where writes land, the literal chain says which links could be repointed to
/// land elsewhere. A symlink STEP is not refused for being one — a link's own
/// mode means nothing on POSIX, what governs it is its parent's write bits and
/// what it points at, and both are steps of this same walk. (`/var` on macOS
/// is a symlink; refusing links outright would refuse every temporary folder
/// on the platform.)
String? folderSyncRootRefusal(String path) {
  // Windows says nothing about this in mode bits: rights there live in ACLs,
  // which this code does not read and a POSIX mode cannot describe. Same
  // reasoning as `runtimeDirMustBePrivate()` — a check that cannot be made
  // faithfully must not be faked, so nothing is refused. A host whose ABI is
  // not in the `lstat` table is the same case.
  if (Platform.isWindows || !posixFactsAvailable) return null;

  final String canonical;
  try {
    canonical = Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException catch (error) {
    return 'the real location behind $path could not be resolved '
        '(${error.osError?.message ?? error.message})';
  }

  for (final step in {..._rootChain(canonical), ..._rootChain(path)}) {
    final facts = posixLstat(step);
    // Unreadable is not evidence of safety. Every step of a path that just
    // resolved does exist, so a null here is an anomaly, not a normal state.
    if (facts == null) return 'the permissions of $step could not be read';
    if (facts.isSymlink) continue;
    // Sticky takes the dangerous half of the write bit back: in `/tmp` others
    // may create their own entries but may not touch this one.
    if (facts.groupOrOtherWritable && !(facts.isDirectory && facts.isSticky)) {
      return '$step can be written by other accounts on this computer, so '
          'what is mirrored into it could be redirected somewhere else';
    }
  }
  return null;
}

/// [path] and every ancestor above it, leaf first. Bounded, so a malformed
/// path cannot spin here.
List<String> _rootChain(String path) {
  final steps = <String>[];
  var current = path;
  for (var guard = 0; guard < 128; guard++) {
    steps.add(current);
    final index = current.lastIndexOf('/');
    if (index < 0) break;
    final parent = index == 0 ? '/' : current.substring(0, index);
    if (parent == current) break;
    current = parent;
  }
  return steps;
}

final folderSyncStoreProvider = Provider<FolderSyncStore>(
  (ref) => FolderSyncStore(ref.watch(storageProvider)),
);

final folderSyncEngineProvider = Provider<FolderSyncEngine?>((ref) {
  final cloud = ref.watch(cloudServiceProvider);
  if (cloud == null) return null;
  return FolderSyncEngine(
    CloudServiceFolderSync(cloud),
    const LocalFolderSyncDisk(),
    ref.watch(folderSyncStoreProvider),
    () => DateTime.now().millisecondsSinceEpoch,
  );
});

final folderSyncControllerProvider =
    NotifierProvider<FolderSyncController, List<FolderSyncPairView>>(
      FolderSyncController.new,
    );
