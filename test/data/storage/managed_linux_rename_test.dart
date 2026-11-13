import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_fs_contract.dart';
import 'package:xveil/data/storage/managed_linux_rename.dart';

void main() {
  test('Linux UAPI numbers cover only supported EABI/LP64 targets', () {
    final known = {
      Abi.androidArm: 382,
      Abi.linuxArm: 382,
      Abi.androidArm64: 276,
      Abi.linuxArm64: 276,
      Abi.androidIA32: 353,
      Abi.linuxIA32: 353,
      Abi.androidX64: 316,
      Abi.linuxX64: 316,
    };
    for (final abi in Abi.values) {
      if (known.containsKey(abi)) {
        expect(managedLinuxRenameSyscallNumber(abi), known[abi]);
      } else {
        expect(
          () => managedLinuxRenameSyscallNumber(abi),
          throwsA(isA<ManagedFsFailure>()),
        );
      }
    }
  });

  test('unsupported ABI refuses before any native symbol lookup', () {
    var lookedUp = false;
    expect(
      () => managedLinuxRenameNoReplace(
        nullptr.cast<Utf8>(),
        nullptr.cast<Utf8>(),
        abi: Abi.macosArm64,
        lookup: (_) {
          lookedUp = true;
          throw ArgumentError('Synthetic missing symbol');
        },
      ),
      throwsA(isA<ManagedFsFailure>()),
    );
    expect(lookedUp, isFalse);
  });

  test('missing wrapper and syscall refuse without unsafe rename fallback', () {
    final symbols = <String>[];
    expect(
      () => managedLinuxRenameNoReplace(
        nullptr.cast<Utf8>(),
        nullptr.cast<Utf8>(),
        abi: Abi.androidArm64,
        lookup: (symbol) {
          symbols.add(symbol);
          throw ArgumentError('Synthetic missing symbol');
        },
      ),
      throwsA(
        isA<ManagedFsFailure>().having(
          (e) => e.kind,
          'kind',
          ManagedFsFailureKind.unavailable,
        ),
      ),
    );
    expect(symbols, ['renameat2', 'syscall']);
  });

  test('a failed native wrapper is never retried through syscall', () {
    final symbols = <String>[];
    final arguments = <int>[];
    final wrapper =
        NativeCallable<
          Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32)
        >.isolateLocal((
          int oldFd,
          Pointer<Utf8> source,
          int newFd,
          Pointer<Utf8> destination,
          int flags,
        ) {
          arguments.addAll([
            oldFd,
            source.address,
            newFd,
            destination.address,
            flags,
          ]);
          return -1;
        }, exceptionalReturn: -1);
    try {
      expect(
        managedLinuxRenameNoReplace(
          nullptr.cast<Utf8>(),
          nullptr.cast<Utf8>(),
          abi: Abi.androidArm64,
          lookup: (symbol) {
            symbols.add(symbol);
            return wrapper.nativeFunction.cast<Void>();
          },
        ),
        -1,
      );
      expect(symbols, ['renameat2']);
      expect(arguments, [-100, 0, -100, 0, 1]);
    } finally {
      wrapper.close();
    }
  });
}
