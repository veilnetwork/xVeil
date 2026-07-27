import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  Future<void> addPair({
    required String localPath,
    String? cloudFolderId,
    required String id,
  }) async {
    final pairs = [...await _store.pairs()];
    // Two pairs on one local folder would fight over the same files with
    // separate bases, and each would read the other's uploads as remote edits.
    if (pairs.any((p) => p.localPath == localPath)) return;
    pairs.add(
      FolderSyncPair(id: id, localPath: localPath, cloudFolderId: cloudFolderId),
    );
    await _store.savePairs(pairs);
    await reload();
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
    await reload();
    try {
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
