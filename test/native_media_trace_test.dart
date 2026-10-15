import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/debug/native_media_trace.dart';

String? nativeEnvironment(String name) {
  final get = DynamicLibrary.process()
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Utf8>)
      >('getenv');
  final key = name.toNativeUtf8();
  try {
    final value = get(key);
    return value == nullptr ? null : value.toDartString();
  } finally {
    calloc.free(key);
  }
}

void main() {
  const names = [
    'VEIL_MEDIA_DIAG_PATH',
    'VEIL_MEDIA_RTP_TRACE_LIMIT',
    'VEIL_MEDIA_PLAYOUT_TRACE',
  ];
  Map<String, String?> snapshot() => {
    for (final name in names) name: nativeEnvironment(name),
  };

  test(
    'native getenv sees the options; repeated setup restores original values',
    () {
      final before = snapshot();
      addTearDown(() => configureNativeMediaTrace(null));
      expect(configureNativeMediaTrace('/private/first/native.log'), isTrue);
      expect(snapshot(), {
        names[0]: '/private/first/native.log',
        names[1]: '32768',
        names[2]: '1',
      });
      expect(configureNativeMediaTrace('/private/second/native.log'), isTrue);
      expect(nativeEnvironment(names[0]), '/private/second/native.log');
      expect(configureNativeMediaTrace(null), isTrue);
      expect(snapshot(), before);
      expect(configureNativeMediaTrace(null), isTrue);
      expect(snapshot(), before);
    },
    skip: Platform.isWindows,
  );

  test(
    'invalid path cannot partially change native options',
    () {
      final before = snapshot();
      expect(() => configureNativeMediaTrace(''), throwsArgumentError);
      expect(
        () => configureNativeMediaTrace('bad\x00path'),
        throwsArgumentError,
      );
      expect(snapshot(), before);
    },
    skip: Platform.isWindows,
  );
}
