// The binding against the REAL library. A Dart FFI signature is matched by
// NAME, not by type, so a wrong one is memory corruption at call time rather
// than a missing symbol — nothing but calling it proves it right.
//
// It also proves the guarantee end to end: the symlink that is refused and the
// rename that reaches nothing are the two things `dart:io` could not do, and
// they are checked here through the same path the app uses.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/fs_beneath.dart';
import 'package:xveil/data/serve_source.dart';

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final gated = dylib == null || dylib.isEmpty || !File(dylib).existsSync();
  final skip = gated
      ? 'set VEIL_FFI_DYLIB to the debug libveilclient_ffi (see test/e2e/README.md)'
      : false;

  late Directory root;
  late DynamicLibrary lib;

  setUp(() {
    if (gated) return;
    lib = DynamicLibrary.open(dylib);
    root = Directory.systemTemp.createTempSync('xveil-beneath-');
  });
  tearDown(() {
    if (gated) return;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the symbols exist and the signatures are the library\'s', () {
    expect(veilOpenBeneathAvailable(lib: lib), isTrue);
  }, skip: skip);

  test('a real file beneath the root opens and reads', () async {
    Directory('${root.path}/sub').createSync();
    File('${root.path}/sub/f.txt').writeAsStringSync('hello');
    final open = await veilOpenBeneath(root.path, 'sub/f.txt', lib: lib);
    expect(open.supported, isTrue, reason: 'this host cannot do the walk');
    final source = open.source;
    expect(source, isNotNull, reason: 'the ordinary case must work');
    expect(source!.size, 5);
    expect(String.fromCharCodes(await source.read(0, 5)), 'hello');
    // A range, because the app serves them out of order.
    expect(String.fromCharCodes(await source.read(1, 3)), 'ell');
    await source.close();
  }, skip: skip);

  test('a symlink out of the root is refused, not followed', () async {
    final outside = Directory.systemTemp.createTempSync('xveil-outside-');
    addTearDown(() => outside.deleteSync(recursive: true));
    File('${outside.path}/secret.txt').writeAsStringSync('not yours');
    Link('${root.path}/link.txt').createSync('${outside.path}/secret.txt');

    final open = await veilOpenBeneath(root.path, 'link.txt', lib: lib);
    expect(open.supported, isTrue);
    expect(
      open.source,
      isNull,
      reason: 'the strong open followed a symlink out of the granted root',
    );
    // CONTROL: `dart:io` follows it happily, which is the gap this closes.
    expect(
      File('${root.path}/link.txt').readAsStringSync(),
      'not yours',
      reason: 'if dart:io also refused, this test would prove nothing',
    );
  }, skip: skip);

  test('a rename after the open cannot change what is read', () async {
    Directory('${root.path}/a').createSync();
    File('${root.path}/a/f.txt').writeAsStringSync('authorized');
    Directory('${root.path}/evil').createSync();
    File('${root.path}/evil/f.txt').writeAsStringSync('substituted');

    final source = (await veilOpenBeneath(root.path, 'a/f.txt', lib: lib)).source;
    expect(source, isNotNull);
    // The swap, after the open — the window the stamped path cannot close.
    Directory('${root.path}/a').renameSync('${root.path}/gone');
    Directory('${root.path}/evil').renameSync('${root.path}/a');

    expect(
      String.fromCharCodes(await source!.read(0, 10)),
      'authorized',
      reason: 'the read followed the name rather than the descriptor',
    );
    await source.close();
  }, skip: skip);

  test('`..` is refused rather than resolved', () async {
    Directory('${root.path}/sub').createSync();
    File('${root.path}/f.txt').writeAsStringSync('inside');
    final open = await veilOpenBeneath(root.path, 'sub/../f.txt', lib: lib);
    expect(open.supported, isTrue);
    expect(open.source, isNull);
  }, skip: skip);

  // THE WIRING, not just the helper. Removing the strong path from
  // `veilOpenPinnedSource` left every test above green: they call the walk
  // directly, and nothing said the senders go through it.
  group('the open the senders use takes the strong path', () {
    test('a component swapped for a symlink AFTER the check is refused',
        () async {
      // The actual attack, and the first version of this test did not describe
      // it: it passed a symlink path straight in, which the API edge refuses
      // by itself — so it was asking the sender to redo the edge's job.
      //
      // Here the edge does its job on an honest path, and the swap happens in
      // the window the finding is about: between that check and the open.
      final real = Directory('${root.path}/sub')..createSync();
      File('${real.path}/f.txt').writeAsStringSync('authorized');
      final base = Directory(root.path).resolveSymbolicLinksSync();
      final checked = File('$base/sub/f.txt').resolveSymbolicLinksSync();

      final outside = Directory.systemTemp.createTempSync('xveil-outside2-');
      addTearDown(() => outside.deleteSync(recursive: true));
      File('${outside.path}/f.txt').writeAsStringSync('substituted');
      real.renameSync('$base/gone');
      Link('$base/sub').createSync(outside.path);

      final opened = await veilOpenPinnedSource(checked, beneathRoots: [base]);
      if (opened.source != null) {
        final bytes = await opened.source!.read(0, 11);
        await opened.source!.close();
        fail(
          'the sender served through a swapped component: '
          '${String.fromCharCodes(bytes)}',
        );
      }
      // And it SAYS so. Every caller does `opened.source!` on a null refusal,
      // so a refusal that forgets to name itself is a crash rather than a
      // report — and the test that only checked for a missing source could not
      // tell the two apart.
      expect(
        opened.refusal,
        isNotNull,
        reason: 'refused without a reason, which the senders dereference',
      );
    }, skip: skip);

    test('and an ordinary file under the root is still served', () async {
      // The control: a refusal that refuses everything would pass the test
      // above and break the feature.
      final base = Directory(root.path).resolveSymbolicLinksSync();
      File('$base/plain.txt').writeAsStringSync('fine');
      final opened = await veilOpenPinnedSource(
        '$base/plain.txt',
        beneathRoots: [base],
      );
      expect(opened.source, isNotNull, reason: opened.refusal ?? 'refused');
      expect(String.fromCharCodes(await opened.source!.read(0, 4)), 'fine');
      await opened.source!.close();
    }, skip: skip);
  });
}
