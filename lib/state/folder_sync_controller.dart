import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/posix_file_facts.dart';
import '../data/storage/folder_sync_store.dart';
import '../data/storage/managed_fs_platform.dart';
import '../data/storage/managed_fs_windows.dart' as windows;
import '../domain/folder_sync.dart';
import 'app_controller.dart' show IdentityLease, appControllerProvider;
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
    this.rootRefusal,
    this.readIssue,
    this.writeIssue,
  });

  final FolderSyncPair pair;
  final Set<String> conflicts;
  final int? lastPassAtMs;
  final String? lastRefusal;
  final bool busy;
  final FolderSyncRefusal? rootRefusal;
  final FolderSyncFileIssue? readIssue;
  final FolderSyncFileIssue? writeIssue;
}

/// Owns the configured pairs and runs their passes.
///
/// Passes are SERIALISED per pair and never overlap: two passes over one
/// folder would each read a base the other is about to rewrite, and the loser
/// would record a state that never existed.
class FolderSyncController extends Notifier<List<FolderSyncPairView>> {
  final Set<String> _running = {};
  final Map<String, FolderSyncRefusal> _rootRefusals = {};

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
    _rootRefusals.clear();
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

  /// Read the pairs of the store this call belongs to, and publish them only
  /// if that is still the current one.
  ///
  /// `runOnce` has captured its store before its awaits since report17; this
  /// did not, and read `_store` on both sides of two of them. A reload started
  /// under A and finishing after a switch published A's pairs into B's `state`
  /// and — worse — handed them to `_rewatch`, so B's scheduler watched A's
  /// folders and the next watcher event or five-minute sweep uploaded A's
  /// local files into B's cloud (report18 XV18-H6).
  Future<void> reload() async {
    final store = _store;
    final pairs = await store.pairs();
    final views = <FolderSyncPairView>[];
    for (final pair in pairs) {
      final saved = await store.state(pair.id);
      views.add(
        FolderSyncPairView(
          pair: pair,
          conflicts: saved.pendingConflicts,
          lastPassAtMs: saved.lastPassAtMs,
          lastRefusal: saved.lastRefusal,
          busy: _running.contains(pair.id),
          rootRefusal: _rootRefusals[pair.id],
          readIssue: saved.readIssue,
          writeIssue: saved.writeIssue,
        ),
      );
    }
    if (!identical(_store, store)) return;
    state = views;
    _rewatch([for (final view in views) view.pair]);
  }

  /// Configure [localPath] as a sync root. Null when it was taken; otherwise
  /// why it was refused, as a [FolderSyncRefusal] the UI translates.
  /// [owner] is the identity the PICKER was opened under, when there was one.
  ///
  /// The guard below holds `_store` across the awaits inside this method, but
  /// the expensive await is outside it: the native directory picker. Riverpod
  /// reuses this notifier across a switch and repoints `_store` to B, so a
  /// path chosen from A's screen became a pair of B's, and B's scheduler then
  /// uploaded those local files into B's cloud.
  Future<FolderSyncRefusal?> addPair({
    required String localPath,
    String? cloudFolderId,
    required String id,
    IdentityLease? owner,
    FolderSyncRootApproval? rootApproval,
  }) async {
    final store = _store;
    FolderSyncRefusal? refusal;
    await store.updatePairs((pairs) {
      if (!_holdsPairStore(store, owner)) {
        refusal = const FolderSyncRefusal(
          FolderSyncRefusalCode.identityChanged,
        );
        return null;
      }
      if (pairs.any((pair) => folderPairsOverlap(pair.localPath, localPath))) {
        refusal = const FolderSyncRefusal(
          FolderSyncRefusalCode.overlapsExistingPair,
        );
        return null;
      }
      String? identity;
      refusal = folderSyncRootRefusal(
        localPath,
        approval: rootApproval,
        onVerifiedIdentity: (value) => identity = value,
      );
      if (refusal != null) return null;
      return [
        ...pairs,
        FolderSyncPair(
          id: id,
          localPath: localPath,
          cloudFolderId: cloudFolderId,
          deletePropagates: rootApproval?.writeAccess != true,
          rootIdentity: identity,
          rootApproval: rootApproval,
        ),
      ];
    });
    if (refusal == null) await reload();
    return refusal;
  }

  bool _holdsPairStore(FolderSyncStore store, IdentityLease? owner) =>
      identical(_store, store) &&
      (owner == null ||
          ref.read(appControllerProvider.notifier).holdsIdentity(owner));

  Future<FolderSyncRefusal?> approvePair(
    String id,
    FolderSyncRootApproval approval, {
    required IdentityLease owner,
  }) async {
    final store = _store;
    FolderSyncRefusal? refusal;
    await store.updatePairs((pairs) {
      if (!_holdsPairStore(store, owner)) {
        refusal = const FolderSyncRefusal(
          FolderSyncRefusalCode.identityChanged,
        );
        return null;
      }
      final index = pairs.indexWhere((pair) => pair.id == id);
      if (index < 0) {
        refusal = const FolderSyncRefusal(
          FolderSyncRefusalCode.identityChanged,
        );
        return null;
      }
      final pair = pairs[index];
      if ((pair.rootIdentity ?? pair.rootApproval?.identity)
          case final previous? when previous != approval.identity) {
        refusal = FolderSyncRefusal(
          FolderSyncRefusalCode.pathChanged,
          path: pair.localPath,
        );
        return null;
      }
      refusal = folderSyncRootRefusal(pair.localPath, approval: approval);
      if (refusal != null) return null;
      return [...pairs]
        ..[index] = FolderSyncPair(
          id: pair.id,
          localPath: pair.localPath,
          cloudFolderId: pair.cloudFolderId,
          deletePropagates: pair.deletePropagates && !approval.writeAccess,
          rootIdentity: approval.identity,
          rootApproval: approval,
        );
    });
    if (refusal == null && identical(_store, store)) {
      _rootRefusals.remove(id);
      await reload();
    }
    return refusal;
  }

  Future<void> removePair(String id) async {
    final store = _store;
    var removed = false;
    await store.updatePairs((pairs) {
      if (!identical(_store, store)) return null;
      final remaining = pairs.where((pair) => pair.id != id).toList();
      removed = remaining.length != pairs.length;
      return removed ? remaining : null;
    });
    if (!removed) return;
    // A later re-add must not infer deletions from the previous pair's base.
    await store.forget(id);
    if (!identical(_store, store)) return;
    _rootRefusals.remove(id);
    _scheduler?.unwatch(id);
    await reload();
  }

  Future<FolderSyncReport?> runOnce(FolderSyncPair pair) async {
    final engine = _engine;
    if (!_running.add(pair.id)) return null;
    // The store this pass belongs to, taken before the first await. A pass in
    // flight when the identity changes must not finish against the next
    // identity's store — the rebuild above stops NEW passes, not one already
    // running.
    final store = _store;
    try {
      // Reload the pair after taking the per-pair lane. A scheduled pass may
      // have captured its old permissions or a pair that was since removed.
      FolderSyncPair? configured;
      FolderSyncRefusal? refusal;
      await store.updatePairs((pairs) {
        if (!identical(_store, store)) return null;
        final index = pairs.indexWhere((item) => item.id == pair.id);
        if (index < 0) return null;
        final current = configured = pairs[index];
        String? identity;
        refusal = folderSyncRootRefusal(
          current.localPath,
          approval: current.rootApproval,
          expectedIdentity: current.rootIdentity,
          onVerifiedIdentity: (value) => identity = value,
        );
        if (refusal != null || current.rootIdentity != null) return null;
        final bound = configured = FolderSyncPair(
          id: current.id,
          localPath: current.localPath,
          cloudFolderId: current.cloudFolderId,
          deletePropagates: current.deletePropagates,
          rootIdentity: identity,
          rootApproval: current.rootApproval,
        );
        return [...pairs]..[index] = bound;
      });
      if (configured == null || !identical(_store, store)) return null;
      pair = configured!;
      if (refusal case final unsafe?) {
        _rootRefusals[pair.id] = unsafe;
        final reason = unsafe.code.name;
        final saved = await store.updateState(
          pair.id,
          (saved) => FolderSyncState(
            base: saved.base,
            pendingConflicts: saved.pendingConflicts,
            resolutions: saved.resolutions,
            resolutionSerial: saved.resolutionSerial,
            resolutionRevisions: saved.resolutionRevisions,
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
      _rootRefusals.remove(pair.id);
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
      return await engine?.runOnce(pair);
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

/// Only access to the selected directory's contents is reviewable. Every
/// directory above it must protect its name, including the literal path of any
/// symlink step. Consent is scoped to the observed directory and its ACL.
FolderSyncRefusal? folderSyncRootRefusal(
  String path, {
  FolderSyncRootApproval? approval,
  String? expectedIdentity,
  void Function(String)? onVerifiedIdentity,
}) {
  expectedIdentity ??= approval?.identity;
  final absolute = Directory(path).absolute.path;
  final String canonical;
  try {
    canonical = Directory(absolute).resolveSymbolicLinksSync();
  } on FileSystemException catch (error) {
    return FolderSyncRefusal(
      FolderSyncRefusalCode.unresolvable,
      path: path,
      detail: error.osError?.message ?? error.message,
    );
  }

  final windowsHost = Platform.isWindows;
  if (windowsHost &&
      !windows.managedWindowsFinalPathMatches(
        absolute,
        canonical,
        allowNetworkShare: true,
      )) {
    return FolderSyncRefusal(FolderSyncRefusalCode.unresolvable, path: path);
  }

  FolderSyncRefusal? rootRisk;
  String? verifiedIdentity;
  for (final step in {..._rootChain(canonical), ..._rootChain(absolute)}) {
    final leaf = step == canonical;
    try {
      final unix = windowsHost ? null : posixLstat(step);
      if (unix?.isSymlink == true) continue;
      final facts = windowsHost
          ? windows.inspect(
              step,
              includeApprovedAcl: true,
              allowNetworkShare: true,
              protectFromReparseChanges: true,
            )
          : const ManagedFsPlatform().inspectAcl(
              step,
              allowDirectoryContentGrants: leaf,
            );
      if (!facts.directory) {
        return FolderSyncRefusal(
          FolderSyncRefusalCode.unresolvable,
          path: step,
        );
      }
      final identity = leaf
          ? sha256.convert(utf8.encode(facts.identity)).toString()
          : null;
      if (identity != null) {
        if (expectedIdentity != null && expectedIdentity != identity) {
          return FolderSyncRefusal(
            FolderSyncRefusalCode.pathChanged,
            path: step,
          );
        }
        verifiedIdentity = identity;
      }

      final writeAccess = !facts.otherUsersHaveReadOnlyAccess;
      final foreignAccess = leaf && !facts.ownerOnly;
      if (facts.safeAncestor && !foreignAccess) continue;

      final warning = facts.aclWarning;
      // Only access to the chosen directory's contents can be approved.
      // A changed or redirectable path must still fail the identity check.
      final approvable =
          leaf &&
          warning != null &&
          (facts.safeAncestor ||
              !windowsHost &&
                  facts.ownedByCurrentUser &&
                  facts.unsafeAncestorCause ==
                      ManagedAncestorRefusalCause.unsafePermissions);
      final current = approvable
          ? (
              identity: identity!,
              fingerprint: warning.fingerprint,
              writeAccess: writeAccess,
            )
          : null;
      final refusal = FolderSyncRefusal(
        !facts.safeAncestor || writeAccess
            ? FolderSyncRefusalCode.writableByOtherAccounts
            : FolderSyncRefusalCode.readableByOtherAccounts,
        path: step,
        aclWarning: warning,
        approval: current,
      );
      if (!approvable) return refusal;
      if (approval != current) rootRisk = refusal;
    } on ManagedFsFailure catch (error) {
      final warning = error.aclWarnings.firstOrNull;
      return FolderSyncRefusal(
        warning == null
            ? FolderSyncRefusalCode.permissionsUnreadable
            : FolderSyncRefusalCode.writableByOtherAccounts,
        path: step,
        aclWarning: warning,
      );
    }
  }
  if (verifiedIdentity == null) {
    return FolderSyncRefusal(FolderSyncRefusalCode.unresolvable, path: path);
  }
  if (rootRisk == null) onVerifiedIdentity?.call(verifiedIdentity);
  return rootRisk;
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

  readableByOtherAccounts,

  pathChanged,

  /// The identity changed while the picker was open, so the folder chosen on
  /// one identity's screen would have become a pair of another's.
  ///
  /// Not a refusal to explain: the person is now looking at a different
  /// identity, and a dialog about a folder they picked as someone else would
  /// say more than it should. The caller shows nothing.
  identityChanged,
}

/// A [FolderSyncRefusalCode] together with the facts a person cannot guess.
///
/// [path] is the STEP the refusal is about, which is not always the folder that
/// was picked — a private folder inside a world-writable parent is refused for
/// the parent, and naming the leaf instead would send someone looking at the
/// one directory that is fine.
class FolderSyncRefusal {
  const FolderSyncRefusal(
    this.code, {
    this.path,
    this.detail,
    this.aclWarning,
    this.approval,
  });

  final ManagedStorageAclWarning? aclWarning;
  final FolderSyncRootApproval? approval;

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
  var current = Directory(path);
  final root = p.rootPrefix(path);
  while (true) {
    steps.add(current.path);
    if (p.equals(current.path, root)) return steps;
    final parent = current.parent;
    if (parent.path == current.path) return steps;
    current = parent;
  }
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
