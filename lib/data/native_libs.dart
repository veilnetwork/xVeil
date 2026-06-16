import 'dart:ffi';
import 'dart:io';

/// Platform file name for a native lib base (`veilclient_ffi` ->
/// `libveilclient_ffi.dylib` / `.so` / `veilclient_ffi.dll`).
String nativeLibFileName(String base) {
  if (Platform.isWindows) return '$base.dll';
  if (Platform.isMacOS || Platform.isIOS) return 'lib$base.dylib';
  return 'lib$base.so';
}

/// Candidate paths to try, in priority order:
///   1. an explicit env override (dev / CI),
///   2. locations inside a packaged app (next to the executable, the macOS
///      `.app` Frameworks dir, a Linux bundle `lib/` dir),
///   3. the dev artifact produced by `scripts/build-native.sh` (cwd = repo).
List<String> nativeLibCandidates(
  String base, {
  String? envVar,
  String? devSubdir,
}) {
  final file = nativeLibFileName(base);
  final out = <String>[];
  if (envVar != null) {
    final e = Platform.environment[envVar];
    if (e != null && e.isNotEmpty) out.add(e);
  }
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    out.add('$exeDir/$file'); // Windows / Linux: next to the exe
    out.add('$exeDir/../Frameworks/$file'); // macOS .app bundle
    out.add('$exeDir/lib/$file'); // Linux bundle lib dir
  } catch (_) {
    // resolvedExecutable can be unavailable in some hosts; skip.
  }
  if (devSubdir != null) out.add('$devSubdir/$file');
  return out;
}

/// Ensures [base]'s symbols are resolvable for the rest of the process.
///
/// - iOS: Apple forbids third-party dylibs, so the Rust staticlib is linked
///   straight INTO the app image by the plugin podspec (`-force_load`). The
///   symbols already live in the process; there is no file to dlopen, so we
///   just confirm availability.
/// - Android: the per-ABI `.so` ships inside the APK's native-lib dir. It is
///   not auto-loaded, so dlopen it by soname (the dynamic linker resolves it
///   from the app's lib dir); the plugin bindings then use the same image.
/// - Desktop (macOS/Linux/Windows): dlopen the first existing candidate path
///   so the plugin's `DynamicLibrary.process()` lookups resolve. Never throws.
bool loadNativeLib(String base, {String? envVar, String? devSubdir}) {
  if (Platform.isIOS) {
    // Statically linked into the Runner; nothing to load.
    return true;
  }
  if (Platform.isAndroid) {
    try {
      DynamicLibrary.open(nativeLibFileName(base)); // lib<base>.so
      return true;
    } catch (_) {
      return false;
    }
  }
  for (final path in nativeLibCandidates(base, envVar: envVar, devSubdir: devSubdir)) {
    if (!File(path).existsSync()) continue;
    try {
      DynamicLibrary.open(path);
      return true;
    } catch (_) {
      // Try the next candidate.
    }
  }
  return false;
}

/// The `DynamicLibrary` to resolve [base]'s symbols against from app-side FFI
/// (e.g. the embedded-node bindings, which don't go through the plugin's own
/// loader). On Android `DynamicLibrary.open` returns a handle whose symbols are
/// NOT placed in the global (`process()`) scope, so callers must use THIS
/// handle; on iOS/desktop the symbols are process-global. Mirrors how the
/// plugin bindings pick their handle per platform.
DynamicLibrary processLibFor(String base) =>
    Platform.isAndroid ? DynamicLibrary.open(nativeLibFileName(base))
                       : DynamicLibrary.process();
