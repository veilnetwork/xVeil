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

  /// The store and engine THIS build belongs to.
  ///
  /// Read through `ref.read` before, which resolves at the moment of the call
  /// — so after an all-online identity switch the pairs in `state` still
  /// belonged to A while these answered with B's store and B's cloud. A
  /// watcher event or the five-minute sweep then uploaded A's local files into
  /// B's cloud, where they are new: a confidentiality and deniability break
  /// with nobody attacking anything (report17 XV17-H2).
  ///
  /// `ref.watch` in `build` is what ties them together: the switch rebuilds
  /// this notifier, `ref.onDispose` takes the scheduler and the watchers with
  /// it, and `state` starts empty and reloads from the store it now has.
  late FolderSyncStore _store;

  /// The engine of the identity this build belongs to.
  ///
  /// READ where it is used, not watched here. It is built from the same
  /// storage as `_store`, so a switch rebuilds this notifier through the watch
  /// below and any read after that answers with the new identity's engine —
  /// while `runOnce` compares the store it captured before its awaits, which
  /// is what actually stops a pass started under A from finishing against B.
  ///
  /// Watching it here instead pulled the cloud service into `build`, and with
  /// it a chain that wants a platform binding — which a notifier that only
  /// lists folder pairs has no business needing.
  FolderSyncEngine? get _engine => ref.read(folderSyncEngineProvider);

  @override
  List<FolderSyncPairView> build() {
    // WATCHED, so a switch rebuilds instead of carrying A's pairs into B.
    _store = ref.watch(folderSyncStoreProvider);
    // Automatic passes are DESKTOP only, for the same reason pairs are: a
    // phone has no folder another app writes to, and Directory.watch is not
    // dependable there. Tests get no scheduler either — a background timer
    // outliving a test is how a suite becomes flaky.
    final desktop = Platform.isMacOS || Platform.isLinux || Platform.isWindows;
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
        scheduler.watch(pair, directory.watch(recursive: true).map((_) {}));
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
  /// why it was refused, as a [FolderSyncRefusal] the UI translates.
  Future<FolderSyncRefusal?> addPair({
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
      return const FolderSyncRefusal(
        FolderSyncRefusalCode.overlapsExistingPair,
      );
    }
    final unsafe = folderSyncRootRefusal(localPath);
    if (unsafe != null) return unsafe;
    pairs.add(
      FolderSyncPair(
        id: id,
        localPath: localPath,
        cloudFolderId: cloudFolderId,
      ),
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
    // The store this pass belongs to, taken before the first await. A pass in
    // flight when the identity changes must not finish against the next
    // identity's store — the rebuild above stops NEW passes, not one already
    // running.
    final store = _store;
    try {
      // EVERY PASS, not only at setup.
      //
      // `addPair` checked this once, when the folder was chosen, and every
      // pass afterwards trusted that answer for as long as the pair existed. A
      // root can stop being safe later: a parent directory made writable by
      // other accounts, or the folder replaced by a symlink pointing
      // elsewhere. From then on each pass read and wrote through a root
      // nothing had looked at since the day it was added.
      //
      // Refused rather than narrowed, and recorded where the screen already
      // shows a refusal — a pass that cannot vouch for its root must not run a
      // partial one.
      final unsafe = folderSyncRootRefusal(pair.localPath);
      if (unsafe != null) {
        final reason =
            'the sync root is no longer safe to use '
            '(${unsafe.code.name}${unsafe.path == null ? '' : ': ${unsafe.path}'})';
        final saved = await store.state(pair.id);
        await store.saveState(
          pair.id,
          FolderSyncState(
            base: saved.base,
            pendingConflicts: saved.pendingConflicts,
            resolutions: saved.resolutions,
            lastPassAtMs: saved.lastPassAtMs,
            lastRefusal: reason,
          ),
        );
        return FolderSyncReport(
          applied: const [],
          failed: const [],
          conflicts: saved.pendingConflicts,
          refusedReason: reason,
        );
      }
      // Inside the try, not before it. `_running` is what stops a second pass
      // over the same pair, and the id went in one statement earlier — so a
      // throw from this reload left the pair marked busy for the lifetime of
      // the controller, and the only way to sync that folder again was a
      // restart.
      await reload();
      if (!identical(_store, store)) {
        // The identity changed under this pass. Its own store is gone from
        // this notifier, and running the engine now would put A's folder into
        // B's cloud.
        return null;
      }
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
FolderSyncRefusal? folderSyncRootRefusal(String path) {
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
    return FolderSyncRefusal(
      FolderSyncRefusalCode.unresolvable,
      path: path,
      detail: error.osError?.message ?? error.message,
    );
  }

  for (final step in {..._rootChain(canonical), ..._rootChain(path)}) {
    final facts = posixLstat(step);
    // Unreadable is not evidence of safety. Every step of a path that just
    // resolved does exist, so a null here is an anomaly, not a normal state.
    if (facts == null) {
      return FolderSyncRefusal(
        FolderSyncRefusalCode.permissionsUnreadable,
        path: step,
      );
    }
    if (facts.isSymlink) continue;
    // Sticky takes the dangerous half of the write bit back: in `/tmp` others
    // may create their own entries but may not touch this one.
    if (facts.groupOrOtherWritable && !(facts.isDirectory && facts.isSticky)) {
      return FolderSyncRefusal(
        FolderSyncRefusalCode.writableByOtherAccounts,
        path: step,
      );
    }
  }
  return null;
}

/// Why a folder was refused as a sync root.
///
/// A CODE, not a sentence, for the same reason `WipeReport.remaining` is a list
/// of codes: the sentence has to be a translated one. These reasons used to be
/// English prose returned from here, and the screen dropped that prose straight
/// into `folderSyncNotAdded` — which IS translated. So a Russian reader got a
/// Russian frame wrapped around an English middle, and the only part naming the
/// actual danger was the part they could not read. That shape hides itself:
/// every string involved is in the ARB, the gate that watches for keys with no
/// call site sees nothing wrong, and the sentence looks translated until you
/// read it.
enum FolderSyncRefusalCode {
  /// The folder is inside, or contains, one that is already mirrored.
  overlapsExistingPair,

  /// The real location behind the path could not be resolved, so nothing about
  /// its permissions could be checked either.
  unresolvable,

  /// A step of the path exists but its mode could not be read. Unreadable is
  /// not evidence of safety.
  permissionsUnreadable,

  /// A step of the path may be written by group or by other, so another local
  /// account can redirect what is mirrored into it.
  writableByOtherAccounts,
}

/// A [FolderSyncRefusalCode] together with the facts a person cannot guess.
///
/// [path] is the STEP the refusal is about, which is not always the folder that
/// was picked — a private folder inside a world-writable parent is refused for
/// the parent, and naming the leaf instead would send someone looking at the
/// one directory that is fine.
class FolderSyncRefusal {
  const FolderSyncRefusal(this.code, {this.path, this.detail});

  final FolderSyncRefusalCode code;

  /// The step of the path this is about. Absent only for
  /// [FolderSyncRefusalCode.overlapsExistingPair], which is about the pair
  /// list rather than about any one directory.
  final String? path;

  /// The operating system's own message, for [FolderSyncRefusalCode
  /// .unresolvable]. Not translated: it comes from the platform, and inventing
  /// a translation for it would misreport what actually failed.
  final String? detail;
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
