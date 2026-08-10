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

import '../data/veil_bundle.dart';
import 'translation_model_controller.dart';
import 'whisper_model_controller.dart';

class ModelImportResult {
  const ModelImportResult.ok(this.kind) : error = null;
  const ModelImportResult.failed(this.error, {this.kind});

  /// What the manifest said it was, when that much could be read.
  final String? kind;
  final String? error;

  bool get succeeded => error == null;
}

/// Write [bytes] somewhere the bundle reader can stream them from.
///
/// The reader works on a file rather than a buffer on purpose — a pair is tens
/// of megabytes and holding one twice over is a spike a phone notices. A
/// received file comes out of the encrypted store as bytes, so this is the
/// bridge, and it is the only place the whole thing sits in memory.
///
/// The caller deletes it. Left in the system temp directory rather than beside
/// the models, so a crash mid-install cannot leave something that looks like a
/// half-installed pair.
Future<File> materialiseBundle(Uint8List bytes, {String name = 'received'}) async {
  final dir = await Directory.systemTemp.createTemp('xveil-bundle');
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

/// Install a received bundle, whichever kind it turns out to be.
///
/// Returns what happened, in words a person can act on. Never throws: a file
/// somebody sent is not a programming error, and every way it can be wrong is
/// an ordinary outcome here.
Future<ModelImportResult> installReceivedModel(
  File bundle, {
  required Ref ref,
}) async {
  final VeilBundleInfo info;
  try {
    info = await inspectBundle(bundle);
  } on VeilBundleException catch (e) {
    return ModelImportResult.failed(e.message);
  }

  switch (info.kind) {
    case kBundleTranslate:
      final ok = await ref
          .read(translationModelsControllerProvider.notifier)
          .importBundle(bundle.path);
      if (ok) return const ModelImportResult.ok(kBundleTranslate);
      return ModelImportResult.failed(
        ref.read(translationModelsControllerProvider).error ??
            'the model could not be installed',
        kind: kBundleTranslate,
      );

    case kBundleSpeech:
      final ok = await ref
          .read(whisperModelControllerProvider.notifier)
          .importBundle(bundle.path);
      if (ok) return const ModelImportResult.ok(kBundleSpeech);
      return ModelImportResult.failed(
        ref.read(whisperModelControllerProvider).error ??
            'the model could not be installed',
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
