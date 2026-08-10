// The near side of libveil_translate: Dart in, translated text out.
//
// Two decisions shape this file.
//
// The engine lives in its OWN long-lived isolate. Opening a model costs
// hundreds of milliseconds warm and seconds cold, so opening one per message
// is not an option; and translating on the main isolate would freeze the UI
// for the length of a decode. So the isolate opens once and then answers
// requests, which also serialises them — the native side takes one call at a
// time by design.
//
// Every symbol is looked up through providesSymbol rather than assumed. A
// build carrying an older libveil_translate must degrade to "translation is
// unavailable", not die at the first lookup: this repository has already
// shipped a native library twelve commits behind its callers, and the failure
// was a dlsym crash at first use.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../data/native_libs.dart';

/// The base name, without the platform's prefix/suffix.
const String kVeilTranslateLib = 'veil_translate';

typedef _OpenC = Pointer<Void> Function(Pointer<Utf8>, Int32, Int32);
typedef _OpenDart = Pointer<Void> Function(Pointer<Utf8>, int, int);
typedef _TranslateC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _TranslateDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _LastErrorC = Pointer<Utf8> Function(Pointer<Void>);
typedef _LastErrorDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);
typedef _VersionC = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();

/// Every entry point this layer calls. Kept as data so the presence check and
/// the lookups cannot drift apart — a check that tests fewer symbols than the
/// code uses is worse than none, because it reports "available" and then
/// crashes.
const List<String> kRequiredSymbols = [
  'veil_translate_open',
  'veil_translate',
  'veil_translate_free',
  'veil_translate_last_error',
  'veil_translate_close',
  'veil_translate_version',
];

/// Opens the library, or null when it is absent or too old.
DynamicLibrary? openTranslateLibrary({String? path}) {
  DynamicLibrary library;
  try {
    library = DynamicLibrary.open(path ?? nativeLibFileName(kVeilTranslateLib));
  } catch (_) {
    return null;
  }
  for (final symbol in kRequiredSymbols) {
    if (!library.providesSymbol(symbol)) return null;
  }
  return library;
}

/// Where the library is, or null. Android resolves by soname — there is no
/// absolute file to stat inside an APK.
String? translateLibraryRef() {
  if (Platform.isAndroid) return nativeLibFileName(kVeilTranslateLib);
  for (final candidate in nativeLibCandidates(kVeilTranslateLib)) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// A request the worker isolate understands.
class _Job {
  const _Job(this.text, this.reply);
  final String text;
  final SendPort reply;
}

/// A model open in its own isolate, answering one translation at a time.
class TranslateEngine {
  TranslateEngine._(this._isolate, this._requests, this.version);

  final Isolate _isolate;
  final SendPort _requests;

  /// Why the last open() returned null, as the native side explained it.
  /// Empty when nothing has failed. Static because a failed open has no
  /// engine to hang it on — and "the engine did not open" with no reason is
  /// how a deployment problem gets filed as "the feature does not work".
  static String lastOpenError = '';

  /// What the native side reports about itself. Useful in a bug report, and
  /// the thing that shows a stale library for what it is.
  final String version;

  bool _closed = false;

  /// Opens [modelDir] — a CTranslate2 model directory that also holds
  /// source.spm and target.spm.
  ///
  /// Returns null if the library is missing, too old, or cannot read the
  /// model. Never throws: an absent engine is an ordinary state here, not an
  /// error to handle at every call site.
  static Future<TranslateEngine?> open(
    String modelDir, {
    int intraThreads = 0,
    int beamSize = 2,
    String? libraryPath,
  }) async {
    final ref = libraryPath ?? translateLibraryRef();
    if (ref == null) return null;

    final ready = ReceivePort();
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _serve,
        _Boot(ready.sendPort, ref, modelDir, intraThreads, beamSize),
        debugName: 'veil_translate',
      );
    } catch (_) {
      ready.close();
      return null;
    }

    final first = await ready.first;
    ready.close();
    if (first is! _Ready) {
      lastOpenError = first is String ? first : 'the engine did not start';
      isolate.kill(priority: Isolate.immediate);
      return null;
    }
    lastOpenError = '';
    return TranslateEngine._(isolate, first.requests, first.version);
  }

  /// Translates one message. Null when the engine could not — the caller shows
  /// the original rather than a wrong answer.
  Future<String?> translate(String text) async {
    if (_closed) return null;
    final reply = ReceivePort();
    _requests.send(_Job(text, reply.sendPort));
    final answer = await reply.first;
    reply.close();
    return answer is String ? answer : null;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

class _Boot {
  const _Boot(this.reply, this.libraryRef, this.modelDir, this.intraThreads, this.beamSize);
  final SendPort reply;
  final String libraryRef;
  final String modelDir;
  final int intraThreads;
  final int beamSize;
}

class _Ready {
  const _Ready(this.requests, this.version);
  final SendPort requests;
  final String version;
}

/// The worker. Opens the library and the model once, then serves.
void _serve(_Boot boot) {
  final library = openTranslateLibrary(path: boot.libraryRef);
  if (library == null) {
    boot.reply.send('libveil_translate is missing or older than this build');
    return;
  }

  final open = library.lookupFunction<_OpenC, _OpenDart>('veil_translate_open');
  final translate = library.lookupFunction<_TranslateC, _TranslateDart>('veil_translate');
  final freeString = library.lookupFunction<_FreeC, _FreeDart>('veil_translate_free');
  final lastError =
      library.lookupFunction<_LastErrorC, _LastErrorDart>('veil_translate_last_error');
  final close = library.lookupFunction<_CloseC, _CloseDart>('veil_translate_close');
  final version = library.lookupFunction<_VersionC, _VersionDart>('veil_translate_version');

  final dirPtr = boot.modelDir.toNativeUtf8();
  final Pointer<Void> engine;
  try {
    engine = open(dirPtr, boot.intraThreads, boot.beamSize);
  } finally {
    calloc.free(dirPtr);
  }
  if (engine == nullptr) {
    boot.reply.send(lastError(nullptr).toDartString());
    return;
  }

  final requests = ReceivePort();
  boot.reply.send(_Ready(requests.sendPort, version().toDartString()));

  requests.listen((message) {
    if (message is! _Job) return;
    final textPtr = message.text.toNativeUtf8();
    try {
      final result = translate(engine, textPtr);
      if (result == nullptr) {
        message.reply.send(null);
        return;
      }
      // Copy before freeing: the pointer belongs to the native allocator and
      // is invalid the moment veil_translate_free returns.
      final answer = result.toDartString();
      freeString(result);
      message.reply.send(answer);
    } catch (_) {
      message.reply.send(null);
    } finally {
      calloc.free(textPtr);
    }
  }, onDone: () => close(engine));
}
