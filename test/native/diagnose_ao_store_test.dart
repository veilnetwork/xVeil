// One-off diagnostic tool; prints are intentional.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';

/// One-off diagnostic: open the user's container with each password and report
/// what's actually inside. Run with the container at XVEIL_DIAG_STORE.
void main() {
  final skip = ensureHiddenVolumeLoaded() ? null : 'no dylib';
  final path = Platform.environment['XVEIL_DIAG_STORE'] ?? '/tmp/xveil-ao.store';

  test('inspect each password against the real container', () async {
    if (!File(path).existsSync()) {
      print('DIAG: no container at $path');
      return;
    }
    for (final pw in ['111111', '222222', '000000', 'one', 'two', 'master']) {
      final s = HiddenVolumeStorage(
        hvSpaceOpener(path, argon: hv.ArgonPreset.heavy),
        keysOpener: hvKeysSpaceOpener(path),
      );
      try {
        final ok = await s.open(password: pw);
        if (!ok) {
          print('DIAG pw=$pw -> AuthFailed (no space)');
          continue;
        }
        final roster = await s.loadRoster();
        final id = await s.loadIdentity();
        print('DIAG pw=$pw -> OPENED  roster=${roster?.map((e) => e.label).toList()}'
            '  identity=${id?.displayName ?? '(none)'}');
        await s.close();
      } catch (e) {
        print('DIAG pw=$pw -> EXCEPTION $e');
      }
    }
  }, skip: skip);
}
