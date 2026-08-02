import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/native_libs.dart';

void main() {
  group('nativeLibCandidates', () {
    test('only an absolute env override is accepted', () {
      // The override exists for operators; a RELATIVE one would resolve against
      // the working directory, which is exactly the class the dev-path gate
      // below removes. Letting it back in through the operator door would be
      // the same hole with a longer name.
      if (Platform.isWindows) {
        expect(isAbsoluteLibPath(r'C:\libs\veil.dll'), isTrue);
        expect(isAbsoluteLibPath(r'\\host\share\veil.dll'), isTrue);
        // A bare leading separator is DRIVE-relative on Windows, not absolute.
        expect(isAbsoluteLibPath(r'\libs\veil.dll'), isFalse);
      } else {
        expect(isAbsoluteLibPath('/opt/veil/libveil.so'), isTrue);
        expect(isAbsoluteLibPath('C:/libs/veil.dll'), isFalse);
      }
      expect(isAbsoluteLibPath('target/debug/libveil.so'), isFalse);
      expect(isAbsoluteLibPath('./libveil.so'), isFalse);
      expect(isAbsoluteLibPath('../libveil.so'), isFalse);
      expect(isAbsoluteLibPath(''), isFalse);
    });

    test('a release build does not offer the CWD-relative dev artifact', () {
      // Asserted with the gate passed EXPLICITLY, not read from the ambient
      // build mode: the tests run under a debug VM, so a version of this that
      // branched on the mode only ever exercised the debug arm and would have
      // stayed green with the gate deleted.
      final dev =
          'third_party/veil/target/debug/${nativeLibFileName('veilclient_ffi')}';
      expect(
        nativeLibCandidates(
          'veilclient_ffi',
          devSubdir: 'third_party/veil/target/debug',
          allowDevPaths: false,
        ),
        isNot(contains(dev)),
        reason: 'a release build must not dlopen a path chosen by whoever '
            'picked the working directory',
      );
      expect(
        nativeLibCandidates(
          'veilclient_ffi',
          devSubdir: 'third_party/veil/target/debug',
          allowDevPaths: true,
        ),
        contains(dev),
        reason: 'dev builds still resolve it',
      );
    });

    test('the default gate follows the build mode', () {
      // The wiring between the flag and the ambient mode, checked once.
      final dev =
          'third_party/veil/target/debug/${nativeLibFileName('veilclient_ffi')}';
      expect(
        nativeLibCandidates(
          'veilclient_ffi',
          devSubdir: 'third_party/veil/target/debug',
        ).contains(dev),
        nativeLibDevPathsEnabled,
      );
    });

    test('bundle-relative candidates are always offered', () {
      // The fix must not strip the paths a packaged app actually uses.
      final out = nativeLibCandidates('veilclient_ffi');
      expect(out, isNotEmpty);
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      expect(out.any((p) => p.startsWith(exeDir)), isTrue);
    });

    test('the platform file name shape is unchanged', () {
      final name = nativeLibFileName('veilclient_ffi');
      if (Platform.isWindows) {
        expect(name, 'veilclient_ffi.dll');
      } else if (Platform.isMacOS || Platform.isIOS) {
        expect(name, 'libveilclient_ffi.dylib');
      } else {
        expect(name, 'libveilclient_ffi.so');
      }
    });
  });
}
