import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/storage/folder_sync_store.dart';
import '../domain/folder_sync.dart';
import 'cloud_service.dart';
import 'folder_sync_adapters.dart';
import 'folder_sync_engine.dart';
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

  FolderSyncStore get _store => ref.read(folderSyncStoreProvider);
  FolderSyncEngine? get _engine => ref.read(folderSyncEngineProvider);

  @override
  List<FolderSyncPairView> build() {
    unawaited(reload());
    return const [];
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
