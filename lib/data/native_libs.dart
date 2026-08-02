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
///   1. an explicit env override (dev / CI) — ABSOLUTE paths only,
///   2. locations inside a packaged app (next to the executable, the macOS
///      `.app` Frameworks dir, a Linux bundle `lib/` dir),
///   3. the dev artifact produced by `scripts/build-native.sh`, DEBUG ONLY.
///
/// ## Why (3) is debug-only and (1) must be absolute
///
/// Both used to apply in every build mode, and both were relative to the
/// process's working directory: `third_party/veil/target/debug/libveil…`
/// resolves against wherever the app happened to be started from. If the
/// packaged library is missing or fails to open — a partial install, a
/// quarantined bundle — the next candidate was a path an attacker controls by
/// choosing the directory the app launches in, and dlopen runs its
/// constructors. No privilege is needed for that, and nothing is logged.
///
/// The env override stays, because setting another process's environment
/// already implies control that dwarfs this, and operators need it. It is
/// required to be ABSOLUTE so it cannot itself be a CWD-relative path — that
/// would reintroduce the same class through the door left open for operators.
List<String> nativeLibCandidates(
  String base, {
  String? envVar,
  String? devSubdir,
  // Defaults to the build mode. Explicit so a test running under a debug VM
  // can still assert what a RELEASE build offers — a test that branched on the
  // ambient mode asserted the debug arm and silently vouched for nothing.
  bool? allowDevPaths,
}) {
  final file = nativeLibFileName(base);
  final out = <String>[];
  if (envVar != null) {
    final e = Platform.environment[envVar];
    if (e != null && e.isNotEmpty && isAbsoluteLibPath(e)) out.add(e);
  }
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    out.add('$exeDir/$file'); // Windows / Linux: next to the exe
    out.add('$exeDir/../Frameworks/$file'); // macOS .app bundle
    out.add('$exeDir/lib/$file'); // Linux app bundle with executable at root
    out.add('$exeDir/../lib/$file'); // standalone bundle: bin/ + sibling lib/
  } catch (_) {
    // resolvedExecutable can be unavailable in some hosts; skip.
  }
  // Relative to the CWD by construction — see the doc above. Release builds
  // resolve the library from the bundle or not at all.
  if (devSubdir != null && (allowDevPaths ?? nativeLibDevPathsEnabled)) {
    out.add('$devSubdir/$file');
  }
  return out;
}

/// Whether CWD-relative dev artifacts may be dlopen'd.
///
/// True only in a debug/JIT build. Deliberately NOT `kDebugMode`: this file is
/// reachable from the headless daemon, which must not link Flutter at all
/// (`headless_is_flutter_free_test`). The assert trick is the Flutter-free
/// equivalent — asserts are compiled out of release AOT.
final bool nativeLibDevPathsEnabled = () {
  var debug = false;
  assert(() {
    debug = true;
    return true;
  }());
  return debug;
}();

/// Whether [path] is absolute on this platform.
///
/// Windows counts a drive prefix (`C:\…`) and a UNC path (`\\host\share`);
/// a bare leading separator is a drive-relative path there, not an absolute
/// one, so it does not qualify.
bool isAbsoluteLibPath(String path) {
  if (path.isEmpty) return false;
  if (Platform.isWindows) {
    if (path.startsWith(r'\\')) return true;
    return path.length >= 3 &&
        path[1] == ':' &&
        (path[2] == '\\' || path[2] == '/');
  }
  return path.startsWith('/');
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
  for (final path in nativeLibCandidates(
    base,
    envVar: envVar,
    devSubdir: devSubdir,
  )) {
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
DynamicLibrary processLibFor(String base) => Platform.isAndroid
    ? DynamicLibrary.open(nativeLibFileName(base))
    : DynamicLibrary.process();
