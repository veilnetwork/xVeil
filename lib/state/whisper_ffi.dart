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
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:path_provider/path_provider.dart';

import '../core/log.dart';
import '../data/native_libs.dart';
import '../data/storage/app_profile.dart';
import 'media_ffi.dart';

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

typedef _DecodePcm16k =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Float>>,
      Pointer<Int32>,
    );
typedef _DecodePcm16kDart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Float>>, Pointer<Int32>);
typedef _FreePcm = Void Function(Pointer<Float>);
typedef _Transcribe =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Float>, Int32, Pointer<Utf8>);
typedef _TranscribeDart =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Float>, int, Pointer<Utf8>);
typedef _FreeString = Void Function(Pointer<Utf8>);

/// Top-level: decode the clip to 16kHz PCM and run whisper. Returns the
/// transcript (possibly empty for silence) or null on a hard failure. Safe to
/// call inside Isolate.run.
String? transcribeVoiceOpus(WhisperJob job) {
  final media = DynamicLibrary.open(job.veilMediaLib);
  final whisper = DynamicLibrary.open(job.whisperLib);
  final decode = media.lookupFunction<_DecodePcm16k, _DecodePcm16kDart>(
    'veil_media_decode_pcm16k',
  );
  final freePcm = media.lookupFunction<_FreePcm, void Function(Pointer<Float>)>(
    'veil_media_free_pcm',
  );
  final transcribe = whisper.lookupFunction<_Transcribe, _TranscribeDart>(
    'veil_whisper_transcribe',
  );
  final freeStr = whisper
      .lookupFunction<_FreeString, void Function(Pointer<Utf8>)>(
        'veil_whisper_free_string',
      );

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
  static const _androidModelChannel = MethodChannel('xveil/whisper_model');

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
      // Production APKs carry the model as an uncompressed Android asset. The
      // native side streams it into noBackupFilesDir, verifies SHA-256, and
      // atomically publishes a real filesystem path for whisper.cpp. Keep the
      // older app-directory probes as a development fallback for adb-pushed
      // models and for a rolling upgrade from pre-bundling builds.
      try {
        final installed = await _androidModelChannel.invokeMethod<String>(
          'ensureInstalled',
        );
        if (installed != null && File(installed).existsSync()) {
          _resolvedModel = installed;
        }
      } on MissingPluginException {
        // Older Android host during hot restart: use the legacy lookup below.
      } on PlatformException {
        // Corrupt/missing dev assets leave transcription unavailable; the
        // release packaging path has already failed closed.
      }
      if (_resolvedModel == null) {
        // External storage is an adb-push location for development, never
        // written by the app, so it stays whole-device like the env override.
        // The support directory is scoped to the profile in the same one place
        // the store writes it. Unscoped, this probe alone would undo the fix:
        // the download would land in the profile and the transcriber would keep
        // opening ANOTHER profile's model, or report one installed to a profile
        // that has none.
        final external = await getExternalStorageDirectory();
        final support = await getApplicationSupportDirectory();
        for (final dir in [
          if (external != null) external.path,
          activeProfileDir(support.path),
        ]) {
          final p = '$dir/$_modelFile';
          if (File(p).existsSync()) {
            _resolvedModel = p;
            break;
          }
        }
      }
    } else if (_resolvedModel == null) {
      // The support directory, on EVERY remaining platform. This is where the
      // on-demand download puts the model, and it is the only place that
      // survives replacing the app bundle.
      //
      // It used to be checked on Linux alone, which was invisible while the
      // model shipped inside the build — the bundle lookup always won first.
      // With the model fetched on demand it meant macOS downloaded 57 MiB and
      // then reported no model at all. Found by putting the file there on a
      // real machine and asking the running app, which is the only way this
      // shows up: it compiles, and every test passes, because the tests own
      // their own directory.
      try {
        final dir = await getApplicationSupportDirectory();
        // The profile's directory, not the support root: the store downloads
        // into the profile, and a probe that looked one level up would answer
        // with a DIFFERENT profile's model — the same crossing that let a wipe
        // in one profile delete another's.
        final p = '${activeProfileDir(dir.path)}/$_modelFile';
        devLog(
          () =>
              'xVeil[whisper]: support-dir probe $p '
              'exists=${File(p).existsSync()}',
        );
        if (File(p).existsSync()) _resolvedModel = p;
      } catch (e) {
        devLog(() => 'xVeil[whisper]: support-dir probe FAILED: $e');
      }
    }
    _resolvedOnce = true;
  }

  /// Drop the cached lookup so the next [ensureResolved] looks again.
  ///
  /// The model can now arrive (or leave) while the app is running, and the
  /// cache is the whole reason resolution is cheap — without this the app
  /// keeps answering "no model" with one sitting right there, until a restart.
  static void forgetResolved() {
    _resolvedOnce = false;
    _resolvedModel = null;
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

  /// True when the native libs are here, whatever the model situation.
  ///
  /// Separate from [available] because the two absences call for different
  /// answers now that the model is fetched on demand: no model is something
  /// the person can fix by tapping Download, no native library is not (there
  /// is no whisper build for this platform, e.g. Linux on arm64), and offering
  /// a 57 MiB download that cannot help would be a lie.
  /// The desktop arm asks TWO questions about veil_media, and it has to.
  ///
  /// [_libRef] answers "is there a file at a path the worker isolate can
  /// reopen", which the isolate genuinely needs — it takes a path, not a
  /// handle. But a file is not an engine: an aarch64 Linux checkout was seen
  /// carrying an x86-64 `libveil_media.so`, which satisfies every existence
  /// check in this project and cannot be dlopen'd on that host. On that
  /// machine this said "native ready" and the UI offered a 57 MiB model
  /// download that could not have helped.
  ///
  /// [VeilMediaNative.available] answers "does it load and export what we
  /// call", by loading it. The Android arm already did that through
  /// [_canOpen]; this is the desktop half of the same question.
  static bool nativeReady() {
    if (Platform.isAndroid) {
      return _canOpen('veil_media') && _canOpen('veil_whisper');
    }
    return _libRef('veil_media') != null &&
        _libRef('veil_whisper') != null &&
        VeilMediaNative.available();
  }

  /// True when the native libs + a model are present (drives whether the UI
  /// shows a Transcribe affordance).
  static bool available() => modelPath() != null && nativeReady();

  /// Transcribe [opus] (a stored VOICE_OPUS clip). [lang] is a whisper code or
  /// "auto". Null if the native layer/model is missing or the run failed.
  Future<String?> transcribe(Uint8List opus, {String lang = 'auto'}) async {
    final media = _libRef('veil_media');
    final whisper = _libRef('veil_whisper');
    final model = modelPath();
    if (media == null || whisper == null || model == null) return null;
    return Isolate.run(
      () => transcribeVoiceOpus(
        WhisperJob(
          opus: opus,
          veilMediaLib: media,
          whisperLib: whisper,
          modelPath: model,
          lang: lang,
        ),
      ),
    );
  }
}
