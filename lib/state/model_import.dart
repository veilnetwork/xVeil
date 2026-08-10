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
      (_read(whisperModelControllerProvider.notifier)
              as WhisperModelController)
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

Future<ModelImportResult> installReceivedModel(
  File bundle, {
  required ModelInstallTargets into,
}) async {
  final VeilBundleInfo info;
  try {
    info = await inspectBundle(bundle);
  } on VeilBundleException catch (e) {
    return ModelImportResult.failed(e.message);
  }

  switch (info.kind) {
    case kBundleTranslate:
      final ok = await into.installTranslation(bundle.path);
      if (ok) return const ModelImportResult.ok(kBundleTranslate);
      return ModelImportResult.failed(
        into.translationError ??
            'the model could not be installed',
        kind: kBundleTranslate,
      );

    case kBundleSpeech:
      final ok = await into.installSpeech(bundle.path);
      if (ok) return const ModelImportResult.ok(kBundleSpeech);
      return ModelImportResult.failed(
        into.speechError ??
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
