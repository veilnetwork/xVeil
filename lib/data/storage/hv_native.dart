import 'dart:ffi';
import 'dart:io';

import '../native_libs.dart';

bool _loaded = false;

/// Preloads `libhidden_volume_ffi` into the process so the hidden_volume
/// plugin's `DynamicLibrary.process()` symbol lookups resolve on desktop
/// (macOS/Linux), where the plugin ships no native build hook yet.
///
/// Resolution: explicit [dylibPath] override, else $XVEIL_HV_DYLIB, the
/// packaged-app locations, then the `scripts/build-native.sh` dev artifact
/// (see [nativeLibCandidates]). Idempotent; never throws.
bool ensureHiddenVolumeLoaded({String? dylibPath}) {
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
    'hidden_volume_ffi',
    envVar: 'XVEIL_HV_DYLIB',
    devSubdir: 'third_party/hidden-volume/target/debug',
  );
  return _loaded;
}
