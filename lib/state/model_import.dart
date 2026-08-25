// Installing a model that arrived as a file.
//
// One entry point for both kinds, because the person tapping Install does not
// know or care which kind they were sent — and because the decision must be
// made from the MANIFEST rather than the file name. The name is whatever the
// sender typed; a .veilaudio carrying a language pair is not a broken speech
// model, it is a translation model with a misleading name, and handing it to
// the speech importer would reject it for the wrong reason and tell the person
// something untrue.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/model_provenance.dart';
import '../data/storage/storage.dart';
import '../data/veil_bundle.dart';
import 'translation_model_controller.dart';
import 'whisper_model_controller.dart';

class ModelImportResult {
  const ModelImportResult.ok(this.kind) : error = null, verdict = null;
  const ModelImportResult.failed(this.error, {this.kind}) : verdict = null;

  /// Nothing was installed because the model's provenance is not settled. Not
  /// a failure: the bundle parsed and its bytes are intact, and the person now
  /// has a decision to make that this layer must not make for them.
  const ModelImportResult.needsDecision(
    ProvenanceVerdict this.verdict, {
    this.kind,
  }) : error = null;

  /// What the manifest said it was, when that much could be read.
  final String? kind;
  final String? error;
  final ProvenanceVerdict? verdict;

  bool get succeeded => error == null && verdict == null;

  /// The caller must ask, then call again with `acceptUnverified: true` if the
  /// person accepts the risk.
  bool get needsDecision => verdict != null;
}

/// A bundle written out for the reader, together with the directory it was
/// written into.
///
/// Both, because the two used to be conflated: the caller deleted
/// `file.parent`, on the assumption that the file's parent IS the stage. That
/// holds only while the file's name is one this side chose — and it was the
/// SENDER's name, so `../elsewhere/x.veiltranslate` made `file.parent` an
/// unrelated directory and cleanup removed it recursively (report14 X14-H1).
///
/// [dispose] therefore deletes [directory], which the call that produced it
/// created and nothing else has a handle to.
class StagedBundle {
  const StagedBundle(this.file, this.directory);

  /// Where the bytes are. The leaf is chosen here, never received.
  final File file;

  /// The temp directory this staging created — the only thing cleanup deletes.
  final Directory directory;

  Future<void> dispose() async {
    if (!directory.existsSync()) return;
    await directory.delete(recursive: true);
  }
}

/// How much of a received bundle is held in RAM at once while it is staged.
///
/// One megabyte, because the point is that the number is small and fixed.
const int _stageChunkBytes = 1024 * 1024;

/// Refusals [stageReceivedBundle] can give, so the caller can say which.
enum BundleStageRefusal {
  /// The blob is not in the store — a cleared history, a download that never
  /// finished.
  missing,

  /// Larger than this device is willing to receive.
  tooLarge,
}

class BundleStageResult {
  const BundleStageResult.staged(StagedBundle this.bundle) : refusal = null;
  const BundleStageResult.refused(BundleStageRefusal this.refusal)
    : bundle = null;

  final StagedBundle? bundle;
  final BundleStageRefusal? refusal;
}

/// Copy a received bundle out of the store and onto disk, a chunk at a time.
///
/// STREAMED, and that is the whole reason this exists rather than the caller
/// reading the blob and handing over bytes. Installing used to pull the entire
/// thing into one `Uint8List` and then write a second full copy to the stage:
/// two complete copies of a model in RAM at the peak, against a ceiling of
/// 2 GiB. That ceiling is what the FORMAT arithmetic can be trusted with, not
/// what a phone can hold, and a bundle anywhere near it took the app down
/// rather than being refused (report14 X14-M2).
///
/// Now the peak is [_stageChunkBytes] regardless of the bundle's size, and the
/// size is checked against [kMaxReceivedBundleBytes] BEFORE anything is read —
/// against the store's own record of the stored length, not against a number
/// the sender wrote down.
Future<BundleStageResult> stageReceivedBundle(
  Storage storage,
  String fileKey, {
  int maxBytes = kMaxReceivedBundleBytes,
}) async {
  final size = await storage.fileSize(fileKey);
  if (size == null) {
    return const BundleStageResult.refused(BundleStageRefusal.missing);
  }
  if (size > maxBytes) {
    return const BundleStageResult.refused(BundleStageRefusal.tooLarge);
  }

  final dir = await Directory.systemTemp.createTemp('xveil-bundle');
  // The leaf name is FIXED and internal. Nothing downstream reads it: the kind
  // of model a bundle holds is decided by its manifest, which is the point
  // `installReceivedModel` is built around, and the extension is a label the
  // card shows from the message rather than from this path. A received name
  // therefore has no reason to reach the filesystem, and every reason not to
  // (report14 X14-H1).
  final file = File('${dir.path}/staged.veilbundle');
  final staged = StagedBundle(file, dir);
  final sink = file.openWrite();
  try {
    for (var offset = 0; offset < size; offset += _stageChunkBytes) {
      final want = size - offset < _stageChunkBytes
          ? size - offset
          : _stageChunkBytes;
      final chunk = await storage.readFileRange(fileKey, offset, want);
      if (chunk == null || chunk.isEmpty) {
        // A record that went missing under us. Nothing partial is left behind
        // for the reader to choke on.
        await sink.close();
        await staged.dispose();
        return const BundleStageResult.refused(BundleStageRefusal.missing);
      }
      sink.add(chunk);
      // Let the write drain before the next megabyte is read, or the sink's
      // own buffer becomes the second full copy this exists to avoid.
      await sink.flush();
    }
    await sink.close();
  } catch (_) {
    await sink.close().catchError((_) {});
    await staged.dispose();
    rethrow;
  }
  return BundleStageResult.staged(staged);
}

/// Write [bytes] somewhere the bundle reader can stream them from.
///
/// For callers that ALREADY hold the bytes — a test, or an import from a
/// buffer. A received bundle goes through [stageReceivedBundle] instead, which
/// never holds more than a chunk.
///
/// The caller disposes it. Left in the system temp directory rather than
/// beside the models, so a crash mid-install cannot leave something that looks
/// like a half-installed pair.
///
/// The leaf name is fixed and internal, for the reason given in
/// [stageReceivedBundle].
Future<StagedBundle> materialiseBundle(Uint8List bytes) async {
  final dir = await Directory.systemTemp.createTemp('xveil-bundle');
  final file = File('${dir.path}/staged.veilbundle');
  await file.writeAsBytes(bytes, flush: true);
  return StagedBundle(file, dir);
}

/// The two controllers this needs, behind an interface.
///
/// `Ref` and `WidgetRef` both have `read`, with no common supertype and with
/// the parameter type not publicly exported by Riverpod 3 — so passing either
/// of them, or their `read`, does not compile. Naming the two operations
/// instead keeps this entry point independent of that entirely: a widget, a
/// controller and a test each hand over what they can reach.
abstract interface class ModelInstallTargets {
  Future<bool> installTranslation(String path);
  String? get translationError;
  Future<bool> installSpeech(String path);
  String? get speechError;
}

class _RefTargets implements ModelInstallTargets {
  _RefTargets(this._read);
  final Object Function(Object provider) _read;

  @override
  Future<bool> installTranslation(String path) =>
      (_read(translationModelsControllerProvider.notifier)
              as TranslationModelsController)
          .importBundle(path);

  @override
  String? get translationError =>
      (_read(translationModelsControllerProvider) as TranslationModelsState)
          .error;

  @override
  Future<bool> installSpeech(String path) =>
      (_read(whisperModelControllerProvider.notifier) as WhisperModelController)
          .importBundle(path);

  @override
  String? get speechError =>
      (_read(whisperModelControllerProvider) as WhisperModelState).error;
}

/// From a provider's own Ref.
ModelInstallTargets targetsFromRef(Ref ref) =>
    _RefTargets((p) => ref.read(p as dynamic) as Object);

/// From a widget's WidgetRef.
ModelInstallTargets targetsFromWidgetRef(WidgetRef ref) =>
    _RefTargets((p) => ref.read(p as dynamic) as Object);

/// From a container, which is what a test has.
ModelInstallTargets targetsFromContainer(ProviderContainer container) =>
    _RefTargets((p) => container.read(p as dynamic) as Object);

/// Install a model that arrived from a contact.
///
/// Provenance is settled BEFORE anything is unpacked. The bundle proving its
/// own integrity is not the same question: the manifest is the sender's claim
/// about the sender's own file, so a contact whose copy was tampered with
/// produces a bundle that verifies against itself perfectly. Only the hash
/// pinned in this build can tell the published artifact from a substitute.
///
/// Refuses by default and hands the verdict back, because the answer belongs
/// to the person: they may know the model is fine, they may prefer to ask
/// another contact who offered it, or they may go and fetch it themselves.
/// [acceptUnverified] is how the UI reports that they chose the first, and it
/// exists as an explicit argument rather than a flag on this layer so the
/// choice cannot be made anywhere except at the point a human made it.
Future<ModelImportResult> installReceivedModel(
  File bundle, {
  required ModelInstallTargets into,
  bool acceptUnverified = false,
  Map<String, Map<String, String>>? pinned,
}) async {
  final VeilBundleInfo info;
  try {
    info = await inspectBundle(bundle);
  } on VeilBundleException catch (e) {
    return ModelImportResult.failed(e.message);
  }

  if (!acceptUnverified) {
    final verdict = judgeProvenance(info, pinned: pinned);
    if (!verdict.isVerified) {
      return ModelImportResult.needsDecision(verdict, kind: info.kind);
    }
  }

  switch (info.kind) {
    case kBundleTranslate:
      final ok = await into.installTranslation(bundle.path);
      if (ok) return const ModelImportResult.ok(kBundleTranslate);
      return ModelImportResult.failed(
        into.translationError ?? 'the model could not be installed',
        kind: kBundleTranslate,
      );

    case kBundleSpeech:
      final ok = await into.installSpeech(bundle.path);
      if (ok) return const ModelImportResult.ok(kBundleSpeech);
      return ModelImportResult.failed(
        into.speechError ?? 'the model could not be installed',
        kind: kBundleSpeech,
      );

    default:
      // Unreachable through inspectBundle, which refuses an unknown kind. Kept
      // as a refusal rather than a fallthrough so that adding a third kind and
      // forgetting this switch fails loudly instead of installing nothing and
      // reporting success.
      return ModelImportResult.failed(
        'this build does not know how to install a ${info.kind} model',
        kind: info.kind,
      );
  }
}
