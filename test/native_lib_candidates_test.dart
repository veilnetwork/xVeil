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

    test('an env override is rejected for being RELATIVE, not for being '
        'missing', () {
      // Audit X-17. The same file, offered twice: once by a relative path and
      // once by an absolute one. It exists both times, so the rejection can
      // only be about absoluteness — a version of this test using a relative
      // path that did not exist would pass against a validator that had lost
      // the absolute check entirely.
      final dir = Directory('build/x17_env_lib_probe')
        ..createSync(recursive: true);
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/libprobe.probe')
        ..writeAsBytesSync(const <int>[0]);
      final relative = 'build/x17_env_lib_probe/libprobe.probe';
      expect(File(relative).existsSync(), isTrue, reason: 'same file, twice');

      expect(
        envLibPath('X', environment: {'X': relative}),
        isNull,
        reason: 'a relative override resolves against whatever directory the '
            'app was launched from, and dlopen runs constructors',
      );
      expect(
        envLibPath('X', environment: {'X': file.absolute.path}),
        file.absolute.path,
        reason: 'and the operator door still opens, or the check above would '
            'be satisfied by a validator that refuses everything',
      );
      expect(envLibPath('X', environment: const {}), isNull);
      expect(envLibPath('X', environment: const {'X': ''}), isNull);
      expect(
        envLibPath('X', environment: {'X': '${file.absolute.path}.gone'}),
        isNull,
      );
    });

    test('openEnvLib refuses the same paths, before opening anything', () {
      // It must not reach `DynamicLibrary.open` at all for a path the
      // validator rejects — which is also why this can be asserted without a
      // real library to hand.
      expect(openEnvLib('X', environment: const {'X': './libveil.so'}), isNull);
      expect(openEnvLib('X', environment: const {}), isNull);
    });

    test('nothing under lib/ opens an env-named library on its own', () {
      // The invariant this file declares held everywhere EXCEPT the two
      // isolate entry points in veil_stack.dart, which read the variable and
      // called `DynamicLibrary.open` on it two lines later. One exception is
      // all it takes, and nothing was watching for the next one.
      //
      // A whole-file check would be wrong: `whisper_ffi.dart` legitimately
      // reads an env var for the speech MODEL, a data file, and separately
      // opens libraries whose paths come from elsewhere. So the check is on
      // PROXIMITY, the same six-line window the raw-exception invariant uses.
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('native_libs.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('DynamicLibrary.open')) continue;
          final from = i - 6 < 0 ? 0 : i - 6;
          final window = lines.sublist(from, i + 1).join('\n');
          if (!window.contains('Platform.environment')) continue;
          offenders.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'these open a library named by the environment without going '
            'through envLibPath/openEnvLib, so the absolute-path rule does '
            'not apply to them:\n${offenders.join('\n')}',
      );
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
