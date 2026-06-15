import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'data/node/embedded_node.dart';
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
        // Wire the keys-opener too so a master space can open its children by
        // their stored SpaceKeys (master mode). Additive: the single-identity
        // flow never calls openWithKeys, so its behaviour is unchanged.
        final storage = HiddenVolumeStorage(
          hvSpaceOpener(path),
          keysOpener: hvKeysSpaceOpener(path),
        );
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
    // Legacy dev path: boot from a pre-made config.toml at launch.
    try {
      if (ensureVeilClientLoaded()) {
        final sock = '${File(config).parent.path}/app.sock';
        // XVEIL_NODE_MODE=embedded runs the node in-process (no subprocess) —
        // requires a node-embedded dylib. Default spawns veil-cli.
        final embedded = Platform.environment['XVEIL_NODE_MODE'] == 'embedded';
        final stack = await RealVeilStack.start(
          veilCliPath: cli,
          configPath: config,
          appSocketPath: sock,
          embedded: embedded,
        );
        overrides.add(realStackProvider.overrideWith((ref) => stack));
        debugPrint('xVeil[real:legacy]: connected, node=${stack.myInvite.nodeId.short}');
      } else {
        debugPrint('xVeil[real]: veil dylib failed to load');
      }
    } catch (e) {
      debugPrint('xVeil[real]: start failed -> loopback: $e');
    }
  } else if (ensureVeilClientLoaded() && embeddedNodeAvailable()) {
    // Deniable path: the node boots IN-PROCESS post-unlock from the identity
    // stored inside the unlocked container (AppController._ensureRealStack),
    // so nothing identity-bearing is ever written to a config.toml. Each
    // instance needs its own listener port (XVEIL_LISTEN_PORT) + sockets dir.
    final runtimeDir = Platform.environment['XVEIL_RUNTIME_DIR'] ??
        '${Directory.systemTemp.path}/xveil-rt-$pid';
    final port =
        int.tryParse(Platform.environment['XVEIL_LISTEN_PORT'] ?? '') ?? 9000;
    overrides.add(deniableBootProvider.overrideWithValue(
        DeniableBootConfig(runtimeDir: runtimeDir, listenPort: port)));
    debugPrint('xVeil[real:deniable]: armed (runtimeDir=$runtimeDir port=$port)');
  }

  return overrides;
}
