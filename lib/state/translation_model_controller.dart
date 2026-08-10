// Installing and removing translation models: the decisions, without the UI.
//
// A model arrives as one .veiltranslate file — picked from disk, or received
// in a chat. Everything about verifying it lives in veil_bundle.dart;
// what is here is what the app does about the result, and when the engine is
// told to look again.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../data/veil_bundle.dart';
import '../data/translation_model_store.dart';
import 'translation_controller.dart';
import 'translation_engines.dart';

enum TranslationImportPhase { idle, importing, failed }

class TranslationModelsState {
  const TranslationModelsState({
    this.installed = const [],
    this.phase = TranslationImportPhase.idle,
    this.progress,
    this.error,
    this.lastInstalled,
  });

  /// Directions usable right now, sorted.
  final List<TranslationPair> installed;
  final TranslationImportPhase phase;

  /// 0..1 while importing, null otherwise.
  final double? progress;

  /// Why the last import failed, in words a person can act on. Cleared when
  /// the next one starts, so a stale message never sits under a fresh attempt.
  final String? error;

  /// What the last successful import installed — the UI says which direction
  /// just became available, since a person who imported "ru-en" may well have
  /// meant "en-ru".
  final TranslationPair? lastInstalled;

  bool get isImporting => phase == TranslationImportPhase.importing;
  bool get hasAny => installed.isNotEmpty;

  TranslationModelsState copyWith({
    List<TranslationPair>? installed,
    TranslationImportPhase? phase,
    double? progress,
    String? error,
    TranslationPair? lastInstalled,
    bool clearProgress = false,
    bool clearError = false,
  }) =>
      TranslationModelsState(
        installed: installed ?? this.installed,
        phase: phase ?? this.phase,
        progress: clearProgress ? null : (progress ?? this.progress),
        error: clearError ? null : (error ?? this.error),
        lastInstalled: lastInstalled ?? this.lastInstalled,
      );
}

/// How a path to a .veiltranslate is obtained. Injectable for the same reason
/// the root is: a widget test cannot open a system file dialog, and a tile
/// whose only path to being exercised is a human tapping it is a tile nobody
/// exercises.
///
/// Null means the person dismissed the picker, which is not a failure.
final translationBundlePickerProvider = Provider<Future<String?> Function()>(
  (ref) => _pickBundle,
);

Future<String?> _pickBundle() async {
  // No type filter: Android's document picker hides files whose extension it
  // does not recognise, and .veiltranslate is not a type any system knows.
  // Filtering here would leave a person staring at an empty picker.
  final picked = await FilePicker.pickFiles(withData: false);
  // firstOrNull, not single: an empty result list throws, and "the picker
  // returned nothing" is a cancellation, not an error to crash on.
  return picked?.files.firstOrNull?.path;
}

/// Where models live, injectable so a test drives this without a platform
/// channel — the same shape as whisperModelStoreProvider, for the same reason.
final translationModelsRootProvider = Provider<Future<Directory?> Function()>(
  (ref) => TranslationEngines.defaultModelsRoot,
);

class TranslationModelsController extends Notifier<TranslationModelsState> {
  Future<Directory?> Function() get _root => ref.read(translationModelsRootProvider);

  /// Riverpod throws if state is assigned after disposal, and every path here
  /// awaits the filesystem — so a screen closed mid-import would otherwise
  /// take the app with it.
  var _disposed = false;

  @override
  TranslationModelsState build() {
    ref.onDispose(() => _disposed = true);
    // Unawaited on purpose: a settings screen should paint immediately and
    // fill in, rather than wait on a directory listing.
    Future.microtask(refresh);
    return const TranslationModelsState();
  }

  /// Re-read what is on disk. Cheap — names and file presence, no hashing.
  Future<void> refresh() async {
    final dir = await _root();
    if (dir == null || !dir.existsSync()) {
      if (!_disposed) state = state.copyWith(installed: const []);
      return;
    }
    final pairs = <TranslationPair>[];
    for (final entry in dir.listSync().whereType<Directory>()) {
      final id = entry.path.split(Platform.pathSeparator).last;
      if (!RegExp(r'^[a-z]{2,3}-[a-z]{2,3}$').hasMatch(id)) continue;
      // The same all-five rule the engine applies. A directory that would not
      // open must not be listed as installed, or the person removes the wrong
      // thing trying to fix it.
      if (!kPairFiles.every((f) => File('${entry.path}/$f').existsSync())) {
        continue;
      }
      pairs.add(TranslationPair(id.split('-').first, id.split('-').last));
    }
    pairs.sort((a, b) => a.id.compareTo(b.id));
    if (!_disposed) state = state.copyWith(installed: pairs);
  }

  /// Verify and install a .veiltranslate.
  ///
  /// Refuses to run two at once: the second would stage into the same
  /// directory as the first and they would overwrite each other's files.
  Future<bool> importBundle(String path) async {
    if (state.isImporting) return false;
    final dir = await _root();
    if (dir == null) {
      state = state.copyWith(
        phase: TranslationImportPhase.failed,
        error: 'there is nowhere to put models on this device',
        clearProgress: true,
      );
      return false;
    }
    dir.createSync(recursive: true);

    state = state.copyWith(
      phase: TranslationImportPhase.importing,
      progress: 0,
      clearError: true,
    );

    final result = await installBundle(
      File(path),
      modelsRoot: dir,
      onProgress: (p) {
        if (!_disposed && state.isImporting) state = state.copyWith(progress: p);
      },
    );

    if (_disposed) return result.succeeded;
    if (!result.succeeded) {
      devLog(() => 'xVeil[translate]: import failed: ${result.error}');
      state = state.copyWith(
        phase: TranslationImportPhase.failed,
        error: result.error,
        clearProgress: true,
      );
      return false;
    }

    state = state.copyWith(
      phase: TranslationImportPhase.idle,
      lastInstalled: result.pair,
      clearProgress: true,
      clearError: true,
    );
    await refresh();
    _tellTheEngine();
    return true;
  }

  /// Delete one direction and the space it takes.
  Future<void> remove(TranslationPair pair) async {
    final dir = await _root();
    if (dir == null) return;
    final target = Directory('${dir.path}/${pair.id}');
    if (target.existsSync()) target.deleteSync(recursive: true);
    await refresh();
    _tellTheEngine();
  }

  /// Make the engine look again.
  ///
  /// Without this a model installed while the app is running stays invisible
  /// until the next launch — and worse, a REMOVED one stays usable, because
  /// the engine holds it open. Invalidating disposes the old instance, which
  /// closes its isolates.
  void _tellTheEngine() => ref.invalidate(translationEnginesProvider);
}

final translationModelsControllerProvider =
    NotifierProvider<TranslationModelsController, TranslationModelsState>(
  TranslationModelsController.new,
);
