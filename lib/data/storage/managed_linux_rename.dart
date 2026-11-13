import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'managed_fs_contract.dart';

/// Linux UAPI syscall numbers for supported EABI/LP64 targets. Never guess a
/// number for a new architecture: a wrong syscall can have unrelated effects.
int managedLinuxRenameSyscallNumber(Abi abi) => switch (abi) {
  Abi.androidArm || Abi.linuxArm => 382,
  Abi.androidArm64 || Abi.linuxArm64 => 276,
  Abi.androidIA32 || Abi.linuxIA32 => 353,
  Abi.androidX64 || Abi.linuxX64 => 316,
  _ => throw const ManagedFsFailure(ManagedFsFailureKind.unavailable),
};

/// Linux-only no-replace directory publication. Symbol injection is limited to
/// native qualification: production uses the current ABI and process libc.
/// Bionic exports renameat2 only from API 30, although the kernel primitive is
/// older. Its variadic syscall wrapper preserves NOREPLACE on older libc;
/// unsupported kernels/filesystems fail without ordinary rename fallback.
int managedLinuxRenameNoReplace(
  Pointer<Utf8> source,
  Pointer<Utf8> destination, {
  Pointer<Void> Function(String)? lookup,
  Abi? abi,
}) {
  final number = managedLinuxRenameSyscallNumber(abi ?? Abi.current());
  final resolve = lookup ?? DynamicLibrary.process().lookup<Void>;
  Pointer<Void>? wrapper;
  try {
    wrapper = resolve('renameat2');
  } on ArgumentError {
    // Missing libc symbol only. A failed native call must not be retried via
    // another path or downgraded to a replacing/check-then-rename operation.
  }
  if (wrapper != null) {
    final rename = wrapper
        .cast<
          NativeFunction<
            Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32)
          >
        >()
        .asFunction<
          int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
        >();
    return rename(-100, source, -100, destination, 1);
  }
  try {
    // All variadic integers are machine-width long. No split/aligned 64-bit
    // scalar arguments occur on ARM EABI; source/destination are native pointers.
    final syscall = resolve('syscall')
        .cast<
          NativeFunction<
            Long Function(
              Long,
              VarArgs<(Long, Pointer<Utf8>, Long, Pointer<Utf8>, UnsignedLong)>,
            )
          >
        >()
        .asFunction<
          int Function(int, int, Pointer<Utf8>, int, Pointer<Utf8>, int)
        >();
    return syscall(number, -100, source, -100, destination, 1);
  } on ArgumentError {
    throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
  }
}
