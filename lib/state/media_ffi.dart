import 'package:veil_media/veil_media.dart';

/// Is the call media engine here, and what happens at the call sites when it
/// is not.
///
/// `libveil_media` (`.so`/`.dll`/`.dylib`, or the archive linked into the iOS
/// Runner) is a gitignored prebuilt: a from-source WebRTC plus the veil engine,
/// tens of GB of checkout to produce. A clean clone has none, and since the
/// desktop plugin CMake stopped refusing to configure without one
/// (`veil_media/cmake/veil_media_engine_policy.cmake`), a build that carries no
/// engine is a thing that now exists on purpose.
///
/// What that build did before this file: nothing checked. The plugin opens the
/// library from a lazy top-level `final` and every binding is a lazy lookup off
/// it, so the failure surfaced at the FIRST media call of any kind, as an
/// uncaught `ArgumentError` out of a button handler. Only two paths survived
/// it by accident — the 1:1 and group call state machines wrap their start in a
/// blanket `catch` and reported the miss as "call ended" — and speech to text,
/// which resolves the library path before using it. Recording a voice message
/// or a video note, playing either back, and the video player all threw.
///
/// This is the same shape the project already uses for its other two optional
/// natives: `WhisperTranscriber.nativeReady()` and `openTranslateLibrary()`
/// answer "can this feature work at all", the UI hides the affordance when the
/// answer is no, and nothing offers something that cannot happen.
class VeilMediaNative {
  VeilMediaNative._();

  /// The answer, computed once.
  ///
  /// A library is loaded or it is not, and neither state changes under a
  /// running process: the plugin caches its own `DynamicLibrary` in a top-level
  /// `final`, so asking twice cannot produce two answers anyway. Caching here
  /// keeps [available] cheap enough to call from `build()`.
  static bool? _cached;

  /// Test seam: when non-null, [available] returns it without touching FFI.
  ///
  /// Set by tests that need to assert what a build with NO engine does, on a
  /// machine that has one. This is the same reason `nativeLibCandidates` takes
  /// an explicit `allowDevPaths` — a test that could only observe the ambient
  /// machine would assert the arm that happens to be true here and vouch for
  /// nothing about the arm that ships.
  static bool? debugForceAvailable;

  /// True when the engine can be loaded and called.
  ///
  /// Asks the engine the way every feature asks it — `VeilMediaEngine.version()`
  /// goes through the plugin's own `nativeLib` and its own lookup, which is the
  /// point. A probe that opened the library itself would be a second, parallel
  /// answer to "where is the engine", free to drift from the one that decides
  /// at runtime: it would have to re-derive the macOS Frameworks path, the iOS
  /// static-link case and the Android soname, and be silently wrong the moment
  /// the plugin changed any of them. This cannot disagree with the loader
  /// because it IS the loader.
  ///
  /// `version()` is also the cheapest entry point there is — a string out of a
  /// static, no engine created, no device touched.
  static bool available() {
    final forced = debugForceAvailable;
    if (forced != null) return forced;
    final cached = _cached;
    if (cached != null) return cached;
    var ok = false;
    try {
      VeilMediaEngine.version();
      ok = true;
    } on ArgumentError catch (e) {
      // Absent library, or one too old to have this symbol. Either way there
      // is no working engine here.
      if (!_isEngineMissing(e)) rethrow;
    }
    _cached = ok;
    return ok;
  }

  /// Drop the cached answer. For tests; nothing in the app makes an absent
  /// engine appear.
  static void forgetProbe() => _cached = null;

  /// Run [body], which touches the engine, and answer null when the engine is
  /// not there.
  ///
  /// The belt to [available]'s braces. Every media call site in the app now
  /// asks [available] first, but this is what makes a site that forgets — or
  /// one added later — degrade to the "native returned nothing" path the
  /// callers already handle, instead of throwing out of a tap handler.
  ///
  /// Deliberately narrow. Only the two `ArgumentError`s the FFI layer raises
  /// for a missing library and a missing symbol are swallowed; everything else
  /// is rethrown, because a guard that turned real faults into a silently dead
  /// button would hide the next bug rather than this one.
  static T? guard<T>(T? Function() body) {
    try {
      return body();
    } on ArgumentError catch (e) {
      if (_isEngineMissing(e)) return null;
      rethrow;
    }
  }

  /// Whether [e] is the FFI layer saying the engine is absent or too old.
  ///
  /// Both spellings are real and both mean the same thing here: `dlopen` failed
  /// (no library at all) or `dlsym` failed (a library that predates the symbol,
  /// or the iOS/macOS `DynamicLibrary.process()` fallback resolving against an
  /// image the archive was never linked into).
  static bool _isEngineMissing(ArgumentError e) {
    final said = '${e.message}';
    return said.contains('Failed to load dynamic library') ||
        said.contains('Failed to lookup symbol');
  }
}
