// Flutter-free probe for the Windows runtime directory boundary. Build as a
// Dart executable with VEIL_FFI_DYLIB set to the reviewed Veil DLL. The fixture
// sets its parent ACL independently of this implementation.
import 'dart:convert';
import 'dart:io';

import 'package:xveil/data/storage/managed_fs_contract.dart';
import 'package:xveil/data/storage/managed_fs_windows.dart' as windows;
import 'package:xveil/data/transport/veil_native.dart';
import 'package:xveil/data/veil_stack.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.length < 2 || args.length > 3) {
    throw ArgumentError('expected Windows mode and disposable parent');
  }
  if (!ensureVeilClientLoaded()) {
    throw StateError('reviewed Veil DLL did not load');
  }
  final mode = args[0];
  if (![
    'verify-shared',
    'claim',
    'lease',
    'unsafe-claim',
    'unsafe-lease',
    'nested-claim',
    'nested-lease',
    'unsafe-parent-claim',
    'unsafe-parent-lease',
    'unsafe-parents-with-private-fallback',
    'unsafe-parents-with-shared-fallback',
  ].contains(mode)) {
    throw ArgumentError('unexpected probe mode');
  }
  final base = Directory(args[1]);
  final fallback = args.length == 3 ? args[2] : null;
  final sentinel = File('${base.path}/precious.txt')
    ..writeAsStringSync('synthetic unrelated data');
  final occupied = Directory('${base.path}/xveil-rt-17')..createSync();
  final foreign = File('${occupied.path}/foreign.txt')
    ..writeAsStringSync('synthetic occupied child');
  final result = <String, Object?>{'mode': mode};
  RuntimeDirLease? lease;
  String? claimed;
  void check(String label, bool value) {
    result[label] = value;
    if (!value) throw StateError('runtime boundary probe check failed');
  }

  try {
    final privateFallback = mode == 'unsafe-parents-with-private-fallback';
    final sharedFallback = mode == 'unsafe-parents-with-shared-fallback';
    final unsafe = mode.startsWith('unsafe-') && !privateFallback;
    final verifyShared = mode == 'verify-shared';
    final nested =
        mode.startsWith('nested-') ||
        mode.startsWith('unsafe-parent-') ||
        privateFallback ||
        sharedFallback;
    final supplied = nested ? '${base.path}/nested/missing' : base.path;
    var refused = false;
    final attempts = <(int, bool)>[];
    try {
      if (verifyShared) {
        await restrictRuntimeDir(base.path);
      } else if (mode.endsWith('lease')) {
        lease = await RuntimeDirLease.acquire(supplied);
        claimed = lease.path;
      } else {
        claimed = await claimRuntimeDirUnder(
          supplied,
          uniqueSuffix: '17',
          windowsFallbackBase: fallback == null ? null : '${base.path}/local',
          windowsPrivateFallbackBase: fallback == null ? null : () => fallback,
          onWindowsRuntimeAttempt: (candidate, success) =>
              attempts.add((candidate, success)),
        );
      }
    } on RuntimeDirNotPrivate {
      refused = true;
    }
    if (fallback != null) {
      check(
        'profile_and_local_rejected',
        attempts.length == 3 &&
            attempts[0] == (0, false) &&
            attempts[1] == (1, false),
      );
      check(
        'safe_fallback_selected_only',
        attempts.last == (2, privateFallback),
      );
      check(
        'unsafe_ancestors_untouched',
        !Directory('${base.path}/nested').existsSync() &&
            !Directory('${base.path}/local').existsSync(),
      );
      if (privateFallback) {
        final facts = windows.inspect(fallback);
        check(
          'fallback_base_private',
          facts.ownerOnly && facts.ownedByCurrentUser,
        );
      } else {
        check(
          'shared_fallback_not_modified',
          !windows.inspect(fallback).ownerOnly &&
              !Directory('$fallback/xveil-rt-17').existsSync(),
        );
      }
    }
    if (unsafe || verifyShared) {
      check(
        verifyShared ? 'shared_runtime_refused' : 'unsafe_base_refused',
        refused,
      );
      if (verifyShared) {
        check(
          'shared_base_not_tightened',
          !windows.inspect(base.path).ownerOnly,
        );
      }
      if (nested) {
        check(
          'unsafe_parent_unchanged',
          !Directory('${base.path}/nested').existsSync(),
        );
      }
    } else {
      check('stable_nonempty_base_accepted', !refused && claimed != null);
      check('occupied_child_not_adopted', claimed != occupied.path);
      final directory = windows.inspect(claimed!);
      check(
        'child_private',
        directory.ownerOnly && directory.ownedByCurrentUser,
      );
      final capability = File('$claimed/synthetic.token');
      // Veil creates loopback credentials with an explicit private ACL. The
      // Windows token's default owner on CI may be the Administrators group.
      check('capability_created', windows.createPrivateFile(capability.path));
      await capability.writeAsString('synthetic local capability', flush: true);
      final leaf = windows.inspect(capability.path);
      check('capability_private', leaf.ownerOnly && leaf.ownedByCurrentUser);
      await restrictRuntimeDir(claimed);
      check('claimed_marker_present', runtimeDirIsOurs(claimed));
    }
    check(
      'parent_data_unchanged',
      sentinel.readAsStringSync() == 'synthetic unrelated data',
    );
    check(
      'occupied_data_unchanged',
      foreign.readAsStringSync() == 'synthetic occupied child',
    );
    check('occupied_child_unmarked', !runtimeDirIsOurs(occupied.path));
    result['ok'] = true;
  } catch (error) {
    result['ok'] = false;
    result['error_type'] = error.runtimeType.toString();
    if (error is ManagedFsFailure) result['error_kind'] = error.kind.name;
  } finally {
    if (lease != null) {
      final refusal = await lease.release();
      result['lease_released'] = refusal == null;
      if (refusal != null) result['ok'] = false;
    } else if (claimed != null && runtimeDirIsOurs(claimed)) {
      Directory(claimed).deleteSync(recursive: true);
    }
  }
  stdout.writeln(jsonEncode(result));
  if (result['ok'] != true) exitCode = 1;
}
