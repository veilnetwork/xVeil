import 'dart:ffi';
import 'dart:io';

bool _loaded = false;

/// Preloads `libveilclient_ffi` so the veil_flutter plugin's
/// `DynamicLibrary.process()` lookups resolve on desktop (macOS/Linux), where
/// the plugin ships no native build hook. Same mechanism as the storage side
/// (see hv_native.dart). veil_flutter also honours `VEIL_FFI_DYLIB` itself, so
/// this is belt-and-suspenders. Idempotent; never throws.
bool ensureVeilClientLoaded({String? dylibPath}) {
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

String? _defaultDylibPath() {
  final env = Platform.environment['VEIL_FFI_DYLIB'];
  if (env != null && env.isNotEmpty) return env;
  const base = 'third_party/veil/target/debug';
  if (Platform.isMacOS) return '$base/libveilclient_ffi.dylib';
  if (Platform.isLinux) return '$base/libveilclient_ffi.so';
  if (Platform.isWindows) return '$base/veilclient_ffi.dll';
  return null;
}
