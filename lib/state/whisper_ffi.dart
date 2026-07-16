// On-device transcription FFI (voice epic, brick 6): decode a stored voice
// clip to 16kHz PCM (libveil_media) and run whisper.cpp (libveil_whisper) over
// it — all native, all in-process, so audio + text never leave the device.
//
// The heavy whisper pass runs on a worker isolate via Isolate.run. The isolate
// re-opens both native libs by path (symbols are not guaranteed global across
// isolates on every platform), so the transcribe function is fully top-level
// and self-contained — no captured `this`, no unsendable state.

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

import '../data/native_libs.dart';

/// Everything the worker isolate needs to transcribe, all sendable.
class WhisperJob {
  const WhisperJob({
    required this.opus,
    required this.veilMediaLib,
    required this.whisperLib,
    required this.modelPath,
    required this.lang,
  });
  final Uint8List opus;
  final String veilMediaLib;
  final String whisperLib;
  final String modelPath;
  final String lang;
}

typedef _DecodePcm16k = Int32 Function(
    Pointer<Uint8>, Size, Pointer<Pointer<Float>>, Pointer<Int32>);
typedef _DecodePcm16kDart = int Function(
    Pointer<Uint8>, int, Pointer<Pointer<Float>>, Pointer<Int32>);
typedef _FreePcm = Void Function(Pointer<Float>);
typedef _Transcribe = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Float>, Int32, Pointer<Utf8>);
typedef _TranscribeDart = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Float>, int, Pointer<Utf8>);
typedef _FreeString = Void Function(Pointer<Utf8>);

/// Top-level: decode the clip to 16kHz PCM and run whisper. Returns the
/// transcript (possibly empty for silence) or null on a hard failure. Safe to
/// call inside Isolate.run.
String? transcribeVoiceOpus(WhisperJob job) {
  final media = DynamicLibrary.open(job.veilMediaLib);
  final whisper = DynamicLibrary.open(job.whisperLib);
  final decode = media
      .lookupFunction<_DecodePcm16k, _DecodePcm16kDart>(
          'veil_media_decode_pcm16k');
  final freePcm =
      media.lookupFunction<_FreePcm, void Function(Pointer<Float>)>(
          'veil_media_free_pcm');
  final transcribe = whisper
      .lookupFunction<_Transcribe, _TranscribeDart>('veil_whisper_transcribe');
  final freeStr =
      whisper.lookupFunction<_FreeString, void Function(Pointer<Utf8>)>(
          'veil_whisper_free_string');

  final opusBuf = calloc<Uint8>(job.opus.length);
  final outPcm = calloc<Pointer<Float>>();
  final outN = calloc<Int32>();
  final model = job.modelPath.toNativeUtf8();
  final lang = job.lang.toNativeUtf8();
  try {
    opusBuf.asTypedList(job.opus.length).setAll(0, job.opus);
    final rc = decode(opusBuf, job.opus.length, outPcm, outN);
    if (rc != 0 || outPcm.value == nullptr || outN.value <= 0) return null;
    final pcm = outPcm.value;
    try {
      final res = transcribe(model, pcm, outN.value, lang);
      if (res == nullptr) return null;
      final text = res.toDartString();
      freeStr(res);
      return text;
    } finally {
      freePcm(pcm);
    }
  } finally {
    calloc.free(opusBuf);
    calloc.free(outPcm);
    calloc.free(outN);
    calloc.free(model);
    calloc.free(lang);
  }
}

/// Resolves the native lib + model paths and drives [transcribeVoiceOpus] on a
/// worker isolate. Returns null when the native lib or model is unavailable.
class WhisperTranscriber {
  /// Env override for the ggml model file; else it is looked up next to the
  /// app (bundled) or in a dev location.
  static const _modelEnv = 'XVEIL_WHISPER_MODEL';
  static const _modelFile = 'ggml-base-q5_1.bin';

  /// Cached model path resolved by [ensureResolved] (Android needs an async
  /// path_provider lookup — a raw /storage path is blocked by scoped storage).
  static String? _resolvedModel;
  static bool _resolvedOnce = false;

  /// Resolve the model path once. On Android this queries the app-specific
  /// external + support dirs (the only accessible model locations); on Linux
  /// the XDG data dir (getApplicationSupportDirectory) is checked after the
  /// bundle locations; elsewhere it is synchronous so this is a cheap no-op.
  /// Safe to call repeatedly.
  static Future<void> ensureResolved() async {
    if (_resolvedOnce) return;
    _resolvedModel = _syncModelPath();
    if (_resolvedModel == null && Platform.isAndroid) {
      for (final dir in [
        await getExternalStorageDirectory(),
        await getApplicationSupportDirectory(),
      ]) {
        if (dir == null) continue;
        final p = '${dir.path}/$_modelFile';
        if (File(p).existsSync()) {
          _resolvedModel = p;
          break;
        }
      }
    } else if (_resolvedModel == null && Platform.isLinux) {
      // XDG data dir (~/.local/share/<app>) — a user-supplied model that
      // survives app-bundle upgrades.
      try {
        final dir = await getApplicationSupportDirectory();
        final p = '${dir.path}/$_modelFile';
        if (File(p).existsSync()) _resolvedModel = p;
      } catch (_) {
        // No usable data dir — transcription simply stays unavailable.
      }
    }
    _resolvedOnce = true;
  }

  /// The resolved model path, or null if absent. On Android call [ensureResolved]
  /// first (the UI does via [transcriptionAvailableProvider]).
  static String? modelPath() {
    if (_resolvedOnce) return _resolvedModel;
    return _syncModelPath();
  }

  /// Synchronous lookup: env override + desktop bundle/dev locations.
  static String? _syncModelPath() {
    final env = Platform.environment[_modelEnv];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    if (Platform.isAndroid) return null; // resolved async in ensureResolved
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      for (final p in [
        '$exeDir/../Resources/$_modelFile', // macOS .app bundle resources
        '$exeDir/$_modelFile',
        '$exeDir/lib/$_modelFile',
      ]) {
        if (File(p).existsSync()) return p;
      }
    } catch (_) {}
    return null;
  }

  /// A reference to [base] the isolate can DynamicLibrary.open: the bare soname
  /// on Android (the dynamic linker resolves it from the APK's lib dir — there
  /// is no absolute file to stat), else the first existing absolute path.
  static String? _libRef(String base) {
    if (Platform.isAndroid) return nativeLibFileName(base);
    for (final p in nativeLibCandidates(base)) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  static bool _canOpen(String base) {
    try {
      DynamicLibrary.open(nativeLibFileName(base));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Diagnostic: "ok" or the dlopen error string (debug hook only).
  static String debugCanOpen(String base) {
    try {
      DynamicLibrary.open(nativeLibFileName(base));
      return 'ok';
    } catch (e) {
      return '$e';
    }
  }

  /// True when the native libs + a model are present (drives whether the UI
  /// shows a Transcribe affordance).
  static bool available() {
    if (modelPath() == null) return false;
    if (Platform.isAndroid) {
      return _canOpen('veil_media') && _canOpen('veil_whisper');
    }
    return _libRef('veil_media') != null && _libRef('veil_whisper') != null;
  }

  /// Transcribe [opus] (a stored VOICE_OPUS clip). [lang] is a whisper code or
  /// "auto". Null if the native layer/model is missing or the run failed.
  Future<String?> transcribe(Uint8List opus, {String lang = 'auto'}) async {
    final media = _libRef('veil_media');
    final whisper = _libRef('veil_whisper');
    final model = modelPath();
    if (media == null || whisper == null || model == null) return null;
    return Isolate.run(() => transcribeVoiceOpus(WhisperJob(
          opus: opus,
          veilMediaLib: media,
          whisperLib: whisper,
          modelPath: model,
          lang: lang,
        )));
  }
}
