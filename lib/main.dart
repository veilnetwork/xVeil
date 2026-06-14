import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'data/storage/hidden_volume_storage.dart';
import 'data/storage/hv_kv_log_store.dart';
import 'data/storage/hv_native.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ProviderScope(overrides: await _bootstrapOverrides(), child: const XVeilApp()));
}

/// When the native hidden-volume library is available, point [storageProvider]
/// at a real on-disk deniable container; otherwise leave the default in-memory
/// provider in place. Failure to set up native storage degrades to the fake
/// rather than blocking launch.
Future<List<Override>> _bootstrapOverrides() async {
  try {
    if (!ensureHiddenVolumeLoaded()) return const [];
    final dir = await getApplicationSupportDirectory();
    final path = '${dir.path}/xveil.store';
    return [
      storageProvider.overrideWith((ref) {
        final storage = HiddenVolumeStorage(hvSpaceOpener(path));
        ref.onDispose(storage.close);
        return storage;
      }),
    ];
  } catch (_) {
    return const [];
  }
}
