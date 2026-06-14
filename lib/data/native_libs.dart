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

/// dlopen the first existing candidate so the plugin's
/// `DynamicLibrary.process()` lookups resolve on desktop. Never throws.
bool loadNativeLib(String base, {String? envVar, String? devSubdir}) {
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
