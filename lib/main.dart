import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'data/storage/hidden_volume_storage.dart';
import 'data/storage/hv_kv_log_store.dart';
import 'data/storage/hv_native.dart';
import 'data/transport/veil_native.dart';
import 'data/veil_stack.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ProviderScope(
    overrides: await _bootstrapOverrides(),
    child: const XVeilApp(),
  ));
}

/// Builds provider overrides at launch:
/// - Native hidden-volume storage when available (else the in-memory fake).
/// - The real veil stack ONLY when the opt-in env flags XVEIL_VEIL_CLI +
///   XVEIL_VEIL_CONFIG are set; otherwise the default loopback path is left
///   entirely untouched. Any failure degrades to the fakes rather than
///   blocking launch.
Future<List<Override>> _bootstrapOverrides() async {
  final overrides = <Override>[];

  try {
    if (ensureHiddenVolumeLoaded()) {
      // XVEIL_STORE_PATH lets two instances on one machine use separate
      // containers (dev/demo); otherwise the per-app support dir.
      final override = Platform.environment['XVEIL_STORE_PATH'];
      final dir = await getApplicationSupportDirectory();
      final path = (override != null && override.isNotEmpty)
          ? override
          : '${dir.path}/xveil.store';
      overrides.add(storageProvider.overrideWith((ref) {
        final storage = HiddenVolumeStorage(hvSpaceOpener(path));
        ref.onDispose(storage.close);
        return storage;
      }));
    }
  } catch (_) {
    // Stay on the in-memory store.
  }

  final cli = Platform.environment['XVEIL_VEIL_CLI'];
  final config = Platform.environment['XVEIL_VEIL_CONFIG'];
  if (cli != null && cli.isNotEmpty && config != null && config.isNotEmpty) {
    try {
      if (ensureVeilClientLoaded()) {
        final sock = '${File(config).parent.path}/app.sock';
        final stack = await RealVeilStack.start(
          veilCliPath: cli,
          configPath: config,
          appSocketPath: sock,
        );
        overrides.add(realStackProvider.overrideWithValue(stack));
        // ignore: avoid_print
        print('xVeil[real]: connected, node=${stack.myInvite.nodeId.short}');
      } else {
        // ignore: avoid_print
        print('xVeil[real]: veil dylib failed to load');
      }
    } catch (e) {
      // ignore: avoid_print
      print('xVeil[real]: start failed -> loopback: $e');
    }
  }

  return overrides;
}
