import 'dart:ffi';
import 'dart:io';

bool _loaded = false;

/// Preloads `libhidden_volume_ffi` into the process so the hidden_volume
/// plugin's `DynamicLibrary.process()` symbol lookups resolve on desktop
/// (macOS/Linux), where the plugin ships no native build hook yet.
///
/// `dlopen` makes the cdylib's exported symbols visible to the later
/// `RTLD_DEFAULT`-style process lookup. Idempotent; returns true when the
/// library is available (and false — never throwing — when it is not, so the
/// caller can fall back to the in-memory store).
bool ensureHiddenVolumeLoaded({String? dylibPath}) {
  if (_loaded) return true;
  final path = dylibPath ?? _defaultDylibPath();
  if (path == null || !File(path).existsSync()) return false;
  try {
    DynamicLibrary.open(path);
    _loaded = true;
    return true;
  } catch (_) {
    return false;
  }
}

/// Resolution order: explicit env override, then the debug artifact produced
/// by `scripts/build-native.sh` (relative to the repo root / cwd). Production
/// bundling links the library into the app and never reaches this path.
String? _defaultDylibPath() {
  final env = Platform.environment['XVEIL_HV_DYLIB'];
  if (env != null && env.isNotEmpty) return env;
  const base = 'third_party/hidden-volume/target/debug';
  if (Platform.isMacOS) return '$base/libhidden_volume_ffi.dylib';
  if (Platform.isLinux) return '$base/libhidden_volume_ffi.so';
  if (Platform.isWindows) return '$base/hidden_volume_ffi.dll';
  return null;
}
