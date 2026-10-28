@TestOn('mac-os || linux')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/data/storage/storage.dart';

void main() {
  late Directory directory;
  late FfiRatchetStateHandle handle;
  late void Function(int) reset;
  late int Function() calls;
  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync('xveil-export-race-');
    final source = File('${directory.path}/fixture.c');
    await source.writeAsString('''
#include <stdint.h>
#include <stddef.h>
#include <string.h>
static int mode, attempts;
void fixture_reset(int value) { mode=value; attempts=0; }
int fixture_calls(void) { return attempts; }
int veil_ratchet_export(void *handle, const uint8_t *key, uint8_t *out,
    size_t capacity, size_t *length, char **error) {
  (void)handle; (void)key; *error=NULL; attempts++;
  if(mode==4 && attempts>1) return $kVeilErrRatchetNoConversation;
  size_t required=mode==0 ? 4096+attempts*68 :
    mode==1 ? $kRatchetMaxStateLen :
    mode==2 ? $kRatchetMaxStateLen+1 :
    mode==3 ? capacity :
    mode==5 ? 1400 : capacity+1;
  *length=required;
  if(mode==3 || required>capacity) return $kVeilErrRatchetBufferTooSmall;
  memset(out,0x5a,required); return 0;
}
''');
    final library =
        '${directory.path}/fixture.${Platform.isMacOS ? 'dylib' : 'so'}';
    final result = await Process.run('cc', [
      '-shared',
      '-fPIC',
      source.path,
      '-o',
      library,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final dl = DynamicLibrary.open(library);
    reset = dl.lookupFunction<Void Function(Int32), void Function(int)>(
      'fixture_reset',
    );
    calls = dl.lookupFunction<Int32 Function(), int Function()>(
      'fixture_calls',
    );
    handle = FfiRatchetStateHandle(nullptr, dl);
  });
  tearDownAll(() => directory.deleteSync(recursive: true));

  test('export tolerates a state growing between native reads', () {
    reset(0);
    final blob = handle.export(Uint8List(kRatchetKeyLen));
    expect(blob, isNotNull);
    expect(blob!.length, greaterThan(4096));
    expect(blob.every((b) => b == 0x5a), isTrue);
    expect(calls(), lessThanOrEqualTo(10));
  });

  test('maximum supported snapshot is exported whole', () {
    reset(1);
    expect(
      handle.export(Uint8List(kRatchetKeyLen)),
      hasLength(kRatchetMaxStateLen),
    );
    expect(calls(), 2);
  });

  test('small snapshot keeps the single-call path', () {
    reset(5);
    expect(handle.export(Uint8List(kRatchetKeyLen)), hasLength(1400));
    expect(calls(), 1);
  });

  test('out-of-contract size is rejected before allocation', () {
    reset(2);
    expect(() => handle.export(Uint8List(kRatchetKeyLen)), throwsStateError);
    expect(calls(), 1);
  });

  test('non-growing short-buffer answer fails without repeated allocation', () {
    reset(3);
    expect(() => handle.export(Uint8List(kRatchetKeyLen)), throwsStateError);
    expect(calls(), 1);
  });

  test('disappearing conversation remains absent', () {
    reset(4);
    expect(handle.export(Uint8List(kRatchetKeyLen)), isNull);
    expect(calls(), 2);
  });

  test(
    'unbounded native growth cannot spin or allocate beyond the ABI cap',
    () {
      reset(6);
      expect(() => handle.export(Uint8List(kRatchetKeyLen)), throwsStateError);
      expect(calls(), lessThanOrEqualTo(10));
    },
  );
}
