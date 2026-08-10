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

import '../core/log.dart';
import '../data/translation_model_store.dart';
import 'translate_ffi.dart';

/// The files a directory must hold before it is treated as a pair.
///
/// All five, because four of them plus a missing target.spm is not a partial
/// model, it is a model that opens and translates into nonsense if the missing
/// piece is ever filled in from a different pair. The store checks sizes
/// against a pinned catalogue; this checks presence, which is all that can be
/// known about a directory somebody placed by hand.
const List<String> kPairFiles = [
  'model.bin',
  'config.json',
  'shared_vocabulary.json',
  'source.spm',
  'target.spm',
];

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
  final Map<String, TranslateEngine> _open = {};

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
    final dir = root ?? _rootFromEnvironment();
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

  static Directory? _rootFromEnvironment() {
    final override = Platform.environment[rootEnv];
    if (override != null && override.isNotEmpty) return Directory(override);
    return null;
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

    var engine = _open[pair.id];
    if (engine == null) {
      engine = await TranslateEngine.open(dir.path, libraryPath: _libraryPath);
      if (engine == null) {
        devLog(
          () => 'xVeil[translate]: ${pair.id} would not open: '
              '${TranslateEngine.lastOpenError}',
        );
        return null;
      }
      _open[pair.id] = engine;
    }
    return engine.translate(text);
  }

  /// Close every open engine. Each holds an isolate and a loaded model.
  Future<void> dispose() async {
    for (final engine in _open.values) {
      await engine.close();
    }
    _open.clear();
  }

  @override
  String toString() => 'TranslationEngines(${_root.path}, ${_pairs.length} pairs)';
}
