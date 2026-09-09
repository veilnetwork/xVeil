// A library this process loaded must be reachable through the handle the app
// asks for. That sounds like nothing, and it was the whole of a Linux release
// that could not start.
//
// `dlopen` puts a library in the GLOBAL symbol scope on macOS and in a LOCAL
// one on glibc. Every desktop path here used to preload the library and then
// ask `DynamicLibrary.process()` for its symbols — correct on the machine this
// is developed on, and on Linux an empty answer. xVeil 0.13.53 shipped that
// way: the bundle carried `lib/libveilclient_ffi.so` exporting
// `veil_abi_contract_hash`, the ABI gate asked the process image, got nothing,
// and refused to start before `runApp`.
//
// The guard has to go through the SAME door production does — preload with
// [loadNativeLib], then ask [processLibFor] — because the defect was not in
// either half but in the assumption joining them. A fixture library is built
// here rather than reusing a real one so the test measures the loader on every
// machine instead of measuring whether somebody ran a Rust build first.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/native_libs.dart';

/// A base name nothing else in the process could have loaded.
const _base = 'xveil_scope_probe';
const _symbol = 'xveil_scope_probe_symbol';

String _compiler() {
  for (final c in ['cc', 'gcc', 'clang']) {
    final r = Process.runSync('which', [c]);
    if (r.exitCode == 0) return c;
  }
  // Deliberately not a skip: a skipped test vouches for nothing, and this one
  // guards a failure mode that only appears on the platform CI runs on.
  fail('no C compiler (cc/gcc/clang) to build the fixture library with');
}

void main() {
  test('a library the app preloaded answers through processLibFor', () {
    final dir = Directory.systemTemp.createTempSync('xveil-scope-');
    addTearDown(() {
      debugResetNativeLibHandles();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final src = File('${dir.path}/probe.c')
      ..writeAsStringSync('int $_symbol(void) { return 7; }\n');
    final out = '${dir.path}/${nativeLibFileName(_base)}';
    final built = Process.runSync(_compiler(), [
      '-shared',
      '-fPIC',
      '-o',
      out,
      src.path,
    ]);
    expect(
      built.exitCode,
      0,
      reason: 'could not build the fixture library: ${built.stderr}',
    );

    // The production door: preload by path, then ask for the handle the app
    // resolves its symbols against. `devSubdir` is absolute here, so this does
    // not depend on the working directory the test was started from.
    expect(
      loadNativeLib(_base, devSubdir: dir.path),
      isTrue,
      reason: 'the loader did not open a library that is right there',
    );

    expect(
      processLibFor(_base).providesSymbol(_symbol),
      isTrue,
      reason:
          'the app cannot see a symbol in a library it just loaded. On glibc '
          'dlopen is RTLD_LOCAL, so the process image never had it — this is '
          'the shape that refused the veilclient library at startup on Linux',
    );
  });
}
