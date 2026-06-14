import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/native_libs.dart';

void main() {
  test('nativeLibFileName is platform-correct', () {
    final name = nativeLibFileName('veilclient_ffi');
    if (Platform.isWindows) {
      expect(name, 'veilclient_ffi.dll');
    } else if (Platform.isMacOS) {
      expect(name, 'libveilclient_ffi.dylib');
    } else {
      expect(name, 'libveilclient_ffi.so');
    }
  });

  test('env override is tried first; dev artifact last', () {
    final c = nativeLibCandidates(
      'veilclient_ffi',
      envVar: 'PATH', // any set var, just to exercise the env branch
      devSubdir: 'third_party/veil/target/debug',
    );
    final file = nativeLibFileName('veilclient_ffi');
    expect(c.first, Platform.environment['PATH']);
    expect(c.last, 'third_party/veil/target/debug/$file');
    // Includes packaged-app candidates between env and dev.
    expect(c.any((p) => p.contains('Frameworks') || p.endsWith('/$file')),
        isTrue);
  });

  test('no env var, no dev subdir -> only packaged-app candidates', () {
    final c = nativeLibCandidates('hidden_volume_ffi');
    expect(c, isNotEmpty); // resolvedExecutable-relative paths
    expect(c.every((p) => p.contains('hidden_volume_ffi')), isTrue);
  });
}
