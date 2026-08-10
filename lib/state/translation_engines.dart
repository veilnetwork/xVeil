// Which pairs are on this device, and one open engine per pair.
//
// The layer between "a native library exists" and "this message can be
// translated". Both halves can be absent independently and they call for
// different answers: no library is not fixable by the person holding the
// phone, no model for this pair is.
//
// Engines are cached per pair because opening one costs hundreds of
// milliseconds warm and seconds cold — see TranslateEngine, which keeps each
// in its own isolate.
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:path_provider/path_provider.dart';

import '../core/log.dart';
import '../data/translation_model_store.dart';
import 'translate_ffi.dart';


class TranslationEngines {
  TranslationEngines._(this._root, this._pairs, this._libraryPath);

  final Directory _root;
  final Map<String, Directory> _pairs;

  /// The library resolve() found, remembered so that opening an engine uses
  /// the SAME one. Without this the check and the open could disagree: the
  /// check would pass on an explicitly given path while the open searched the
  /// default locations and found nothing, which is a translation that reports
  /// itself available and then returns null for every message.
  final String? _libraryPath;
  /// The OPENING, not the opened engine.
  ///
  /// Two messages translated at once in the same direction both found an empty
  /// slot and both opened: two isolates, two loaded models of tens of
  /// megabytes, and the first overwritten in the map and leaked for the life
  /// of the process. Caching the future makes the second caller wait for the
  /// first rather than duplicate it.
  final Map<String, Future<TranslateEngine?>> _opening = {};

  /// Where pairs live. The environment override exists so a desktop build can
  /// be pointed at converted models before any of them are published — without
  /// it there is no way to exercise this at all, and an untestable path is one
  /// that gets shipped untested.
  static const rootEnv = 'XVEIL_TRANSLATE_MODELS';

  /// Which directions are usable right now. Sorted, so a log line or a test
  /// reads the same on every machine.
  List<TranslationPair> get installedPairs {
    final ids = _pairs.keys.toList()..sort();
    return [
      for (final id in ids)
        TranslationPair(id.split('-').first, id.split('-').last),
    ];
  }

  bool has(TranslationPair pair) => _pairs.containsKey(pair.id);

  /// Look for pairs under [root], or under the app's own model directory.
  ///
  /// Returns null when translation cannot work at all: no native library, or
  /// no pair installed. Null rather than an empty instance so that the
  /// provider above can say "unavailable" in one expression, and the UI can
  /// stay hidden rather than offering a button that fails.
  static Future<TranslationEngines?> resolve({
    Directory? root,
    String? libraryPath,
  }) async {
    final library = libraryPath ?? translateLibraryRef();
    if (library == null) {
      devLog(() => 'xVeil[translate]: no native library, translation is off');
      return null;
    }
    final dir = root ?? await defaultModelsRoot();
    if (dir == null || !dir.existsSync()) return null;

    final pairs = <String, Directory>{};
    for (final entry in dir.listSync().whereType<Directory>()) {
      final id = entry.path.split(Platform.pathSeparator).last;
      // "ru-en", and nothing else. A stray directory should not become a pair
      // whose name the engine then fails to make sense of.
      if (!RegExp(r'^[a-z]{2,3}-[a-z]{2,3}$').hasMatch(id)) continue;
      if (kPairFiles.every((f) => File('${entry.path}/$f').existsSync())) {
        pairs[id] = entry;
      } else {
        devLog(() => 'xVeil[translate]: $id is incomplete, ignoring it');
      }
    }
    if (pairs.isEmpty) return null;
    devLog(() => 'xVeil[translate]: ${pairs.length} pair(s): ${pairs.keys.join(", ")}');
    return TranslationEngines._(dir, pairs, library);
  }

  /// Where pairs live in a real build: beside the speech model, under the app
  /// support root, in one directory so that removing translation entirely is
  /// removing one tree.
  ///
  /// Without this the feature was dead outside a test: resolve() consulted the
  /// environment variable and nothing else, so a shipped build had no models
  /// directory to find models in. The override stays for pointing a desktop
  /// build at converted pairs before any are published.
  static Future<Directory?> defaultModelsRoot() async {
    final override = Platform.environment[rootEnv];
    if (override != null && override.isNotEmpty) return Directory(override);
    try {
      final support = await getApplicationSupportDirectory();
      return Directory('${support.path}/${TranslationModelStore.dirName}');
    } on Object {
      // No platform channel (a plain unit test, a headless tool). Not an
      // error: it means there is nowhere to look, which resolve() reports as
      // "translation is unavailable".
      return null;
    }
  }

  /// Translate one message into [to].
  ///
  /// [from] is a hint and may be wrong — a sender's tag can lie and a chat can
  /// switch languages mid-thread. When it names no installed pair this returns
  /// null rather than guessing: a translation from the wrong source language
  /// is confidently wrong, which is worse than none, and the caller shows the
  /// original.
  Future<String?> translate(
    String text, {
    required String from,
    required String to,
  }) async {
    if (text.trim().isEmpty) return null;
    final pair = TranslationPair(from, to);
    final dir = _pairs[pair.id];
    if (dir == null) return null;

    final engine = await (_opening[pair.id] ??= () {
      _opens++;
      return TranslateEngine.open(dir.path, libraryPath: _libraryPath);
    }());
    if (engine == null) {
      // Drop the failed attempt so a later message can try again — a model
      // that was mid-copy when the first message arrived should not poison
      // the direction until the app restarts.
      _opening.remove(pair.id);
      devLog(
        () => 'xVeil[translate]: ${pair.id} would not open: '
            '${TranslateEngine.lastOpenError}',
      );
      return null;
    }
    return engine.translate(text);
  }

  /// How many times an engine was actually OPENED.
  ///
  /// Counted at the call, not derived from the map's size: a map entry that
  /// gets overwritten leaves one key behind either way, so a size would read
  /// as 1 whether the dedup worked or not — a counter that measures nothing
  /// and reports a plausible number.
  @visibleForTesting
  int get engineOpenCount => _opens;
  int _opens = 0;

  /// Close every open engine. Each holds an isolate and a loaded model.
  ///
  /// Awaits the openings rather than the engines: one may still be starting,
  /// and killing the map without it would leave an isolate nobody can reach.
  Future<void> dispose() async {
    final pending = _opening.values.toList();
    _opening.clear();
    for (final opening in pending) {
      final engine = await opening;
      await engine?.close();
    }
  }

  @override
  String toString() => 'TranslationEngines(${_root.path}, ${_pairs.length} pairs)';
}
