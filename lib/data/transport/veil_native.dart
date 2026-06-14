import 'dart:ffi';
import 'dart:io';

import '../native_libs.dart';

bool _loaded = false;

/// Preloads `libveilclient_ffi` so the veil_flutter plugin's
/// `DynamicLibrary.process()` lookups resolve on desktop. Same mechanism as the
/// storage side (hv_native.dart); veil_flutter also honours `VEIL_FFI_DYLIB`.
/// Idempotent; never throws.
bool ensureVeilClientLoaded({String? dylibPath}) {
  if (_loaded) return true;
  if (dylibPath != null && dylibPath.isNotEmpty) {
    if (!File(dylibPath).existsSync()) return false;
    try {
      DynamicLibrary.open(dylibPath);
      _loaded = true;
      return true;
    } catch (_) {
      return false;
    }
  }
  _loaded = loadNativeLib(
    'veilclient_ffi',
    envVar: 'VEIL_FFI_DYLIB',
    devSubdir: 'third_party/veil/target/debug',
  );
  return _loaded;
}
