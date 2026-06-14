import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/veil_native.dart';

/// Confirms libveilclient_ffi loads into the process (validates the path and
/// that the artifact is a loadable image), so the veil_flutter plugin's
/// process() lookups will resolve on desktop. Skipped when the dylib hasn't
/// been built — run scripts/build-native.sh first.
void main() {
  test('veilclient ffi preloads on desktop', () {
    final loaded = ensureVeilClientLoaded();
    expect(loaded, isTrue);
  },
      skip: ensureVeilClientLoaded()
          ? false
          : 'libveilclient_ffi not built — run scripts/build-native.sh');
}
