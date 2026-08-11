import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'pinned_download.dart';
import 'storage/app_profile.dart';

/// Translation models, fetched per language pair.
///
/// Unlike the speech model this is not one file but a SET: the weights, the
/// vocabulary, and the two SentencePiece models that turn text into the pieces
/// the weights were trained on. All of them or none — an engine handed a
/// directory with the weights and no target.spm refuses to open, and an engine
/// handed a MISMATCHED pair of .spm files does something worse than refuse: it
/// translates, into nonsense. So "installed" here means every file present and
/// the right size, and a half-finished pair reports as absent.
///
/// One directory per pair under the ACTIVE PROFILE's directory, beside the
/// speech model and for the same reason — see [activeProfileDir], which is the
/// support root itself for the default profile, so an existing install keeps
/// every pair it has.
///
/// These used to sit in the support root, shared by every profile, on the
/// reasoning that a static artifact identical for everyone should not be
/// fetched twice. Here that was worse than for the speech model: a pair is a
/// DIRECTORY NAMED `ru-en`, so the shared location handed every profile the
/// list of languages the person reads — the exact fact a wipe deletes these
/// for — and a wipe inside a throwaway profile deleted the real one's pairs.
///
/// What the download must not do is take whatever bytes arrive. Every file's
/// size and SHA-256 are pinned by whoever describes the pair; anything else is
/// discarded. A model is data, not code, but it is data that decides what the
/// app claims another person said — which is a stronger reason to pin it here
/// than for transcription, where the person at least heard the audio.
class TranslationModelStore {
  TranslationModelStore({
    Future<Directory> Function()? supportDirectory,
    HttpClient Function()? httpClient,
    this.stallTimeout = const Duration(seconds: 30),
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _httpClient = httpClient ?? HttpClient.new;

  final Future<Directory> Function() _supportDirectory;
  final HttpClient Function() _httpClient;

  /// How long a transfer may produce nothing before it is abandoned. See
  /// [fetchPinned] — a mobile connection stops rather than fails.
  final Duration stallTimeout;

  /// Everything lives under this one directory, so removing translation
  /// entirely is removing one tree.
  static const dirName = 'translate';

  /// The one tree every pair lives under, for THIS profile.
  ///
  /// The injected callback answers "where is the APP SUPPORT directory", not
  /// "where are the models" — the profile scoping happens here, so a test
  /// drives the same derivation production does instead of a second one.
  Future<Directory> root() async => Directory(
    '${activeProfileDir((await _supportDirectory()).path, leftBehind: const [dirName])}'
    '/$dirName',
  );

  Future<Directory> directoryFor(TranslationPair pair) async =>
      Directory('${(await root()).path}/${pair.id}');

  /// The installed pair, or null. Cheap: sizes, not hashes — each hash was
  /// verified before its file was given its final name.
  ///
  /// Every file is checked, not just the weights. The weights are what a
  /// person watches download, and they are also the file most likely to be
  /// there when a one-megabyte tokeniser is not.
  Future<Directory?> installed(TranslationModel model) async {
    final dir = await directoryFor(model.pair);
    if (!dir.existsSync()) return null;
    for (final file in model.files) {
      final on = File('${dir.path}/${file.name}');
      if (!on.existsSync() || on.lengthSync() != file.bytes) return null;
    }
    return dir;
  }

  Future<bool> isInstalled(TranslationModel model) async =>
      (await installed(model)) != null;

  /// Which files are still missing or the wrong size. Named rather than
  /// counted: "3 of 5 files" tells a person nothing they can act on, and tells
  /// a bug report even less.
  Future<List<String>> missingFiles(TranslationModel model) async {
    final dir = await directoryFor(model.pair);
    final missing = <String>[];
    for (final file in model.files) {
      final on = File('${dir.path}/${file.name}');
      if (!on.existsSync() || on.lengthSync() != file.bytes) {
        missing.add(file.name);
      }
    }
    return missing;
  }

  /// Delete one pair, including any partial transfer.
  Future<void> remove(TranslationPair pair) async {
    final dir = await directoryFor(pair);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// How many bytes of interrupted attempts are waiting to be resumed.
  Future<int> pendingBytes(TranslationModel model) async {
    final dir = await directoryFor(model.pair);
    if (!dir.existsSync()) return 0;
    var total = 0;
    for (final file in model.files) {
      final part = File('${dir.path}/${file.name}.part');
      if (part.existsSync()) total += part.lengthSync();
    }
    return total;
  }

  /// Fetch every file the pair needs, skipping the ones already correct.
  ///
  /// Progress is reported against the WHOLE pair, not per file: a person
  /// watching five progress bars each reset to zero has no idea how far along
  /// they are. Files already on disk count as complete, so a resumed download
  /// starts where it actually is.
  ///
  /// Stops at the first failure rather than pressing on. The alternative is
  /// downloading a hundred megabytes of weights to accompany a tokeniser that
  /// could not be fetched, and then reporting failure anyway.
  Future<TranslationModelDownload> download(
    TranslationModel model, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
    Uri Function(TranslationModelFile file)? urlFor,
  }) async {
    final dir = await directoryFor(model.pair);
    dir.createSync(recursive: true);

    final total = model.files.fold<int>(0, (sum, f) => sum + f.bytes);
    if (total <= 0) {
      // A pair describing nothing would otherwise divide by zero and report
      // progress as NaN, which renders as an empty bar that never moves.
      return const TranslationModelDownload.failed('the pair describes no files');
    }

    var done = 0;
    for (final file in model.files) {
      final target = File('${dir.path}/${file.name}');
      if (target.existsSync() && target.lengthSync() == file.bytes) {
        done += file.bytes;
        onProgress?.call(done / total);
        continue;
      }

      final soFar = done;
      final result = await fetchPinned(
        target: target,
        artifact: PinnedArtifact(
          url: model.urlFor(file),
          bytes: file.bytes,
          sha256: file.sha256,
        ),
        httpClient: _httpClient,
        stallTimeout: stallTimeout,
        logTag: 'translate/${model.pair.id}',
        isCancelled: isCancelled,
        from: urlFor?.call(file),
        onProgress: (fraction) {
          final overall = (soFar + fraction * file.bytes) / total;
          onProgress?.call(overall > 1 ? 1 : overall);
        },
      );

      if (result.wasCancelled) return const TranslationModelDownload.cancelled();
      if (!result.succeeded) {
        // Name the file. "download failed" on a five-file set leaves nobody
        // able to tell a dead mirror from one bad artifact.
        return TranslationModelDownload.failed('${file.name}: ${result.error}');
      }
      done += file.bytes;
    }
    return TranslationModelDownload.ok(dir.path);
  }
}

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

/// A direction, not a language: ru→en and en→ru are different models.
class TranslationPair {
  const TranslationPair(this.from, this.to);
  final String from;
  final String to;

  /// The directory name, and the thing a person sees in a bug report.
  String get id => '$from-$to';

  @override
  bool operator ==(Object other) =>
      other is TranslationPair && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => id;
}

class TranslationModelFile {
  const TranslationModelFile({
    required this.name,
    required this.bytes,
    required this.sha256,
  });

  /// The name on disk AND in the URL. One name, because two would be a place
  /// for them to disagree.
  final String name;
  final int bytes;
  final String sha256;
}

/// Everything needed to fetch one pair. Passed in rather than hard-coded:
/// there is no catalogue in this file because there are no models published
/// yet, and a pinned hash for an artifact nobody has produced would be a
/// fiction that looks like a check.
class TranslationModel {
  const TranslationModel({
    required this.pair,
    required this.baseUrl,
    required this.files,
  });

  final TranslationPair pair;

  /// The directory the files sit in, without a trailing slash.
  final String baseUrl;
  final List<TranslationModelFile> files;

  String urlFor(TranslationModelFile file) => '$baseUrl/${file.name}';

  int get totalBytes => files.fold(0, (sum, f) => sum + f.bytes);
}

class TranslationModelDownload {
  const TranslationModelDownload.ok(this.path)
    : error = null,
      wasCancelled = false;
  const TranslationModelDownload.failed(this.error)
    : path = null,
      wasCancelled = false;
  const TranslationModelDownload.cancelled()
    : path = null,
      error = null,
      wasCancelled = true;

  final String? path;
  final String? error;
  final bool wasCancelled;

  bool get succeeded => path != null;
}
