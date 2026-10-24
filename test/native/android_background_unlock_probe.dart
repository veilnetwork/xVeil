// Stand entrypoint only. Install with a separate application ID: this probe
// must never run inside the user's installed package or an existing profile.
// Uses disposable containers/OS-vault entries; no node, call or microphone.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilBackground;
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';

const _package = 'network.veil.xveil.platformprobe';
const _sequences = {
  3: [0, 1, 4, 8],
  4: [0, 1, 5, 10, 15],
  5: [0, 1, 6, 12, 18, 24],
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode || !Platform.isAndroid) {
    throw StateError('Use an isolated Android debug probe package');
  }
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Disposable platform checks'))),
    ),
  );
  final dir = await getApplicationSupportDirectory();
  if (!dir.path.split('/').contains(_package)) {
    throw StateError('Refusing to touch a non-probe application directory');
  }
  final clock = Stopwatch()..start();
  var ticks = 0;
  var writing = false;
  Timer.periodic(const Duration(milliseconds: 500), (_) async {
    ticks++;
    if (writing) return;
    writing = true;
    try {
      final temporary = File('${dir.path}/heartbeat.pending');
      await temporary.writeAsString(
        jsonEncode({
          'ticks': ticks,
          'elapsed_ms': clock.elapsedMilliseconds,
          'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
        }),
      );
      await temporary.rename('${dir.path}/heartbeat.json');
    } finally {
      writing = false;
    }
  });
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 39427);
  var busy = false;
  await for (final request in server) {
    request.response.headers.contentType = ContentType.json;
    if (busy) {
      request.response.statusCode = HttpStatus.conflict;
      request.response.write(jsonEncode({'ok': false, 'busy': true}));
      await request.response.close();
      continue;
    }
    busy = true;
    try {
      final grid = int.tryParse(request.uri.queryParameters['grid'] ?? '3')!;
      if (!_sequences.containsKey(grid)) throw ArgumentError('Invalid grid');
      final vault = QuickUnlockVault(
        const QuickUnlockSecretStore(),
        'disposable-android-grid-$grid',
        LocalScreenAuthentication(),
      );
      Map<String, Object?> result;
      switch (request.uri.path) {
        case '/status':
          result = {
            'ok': true,
            'ticks': ticks,
            'biometric_available': await LocalScreenAuthentication()
                .available(),
          };
        case '/configure':
          final password = base64Encode(
            List.generate(32, (_) => Random.secure().nextInt(256)),
          );
          final storage = HiddenVolumeStorage.async(
            workerSpaceOpener('${dir.path}/fixture-$grid.hv'),
          );
          try {
            if (!await storage.open(
              password: password,
              createIfMissing: true,
            )) {
              throw StateError('Fixture container creation refused');
            }
            await storage.putSetting('fixture-marker', 'grid-$grid');
          } finally {
            await storage.close();
          }
          await vault.configure(
            password: password,
            grid: grid,
            nodes: _sequences[grid],
            system: false,
          );
          result = {'ok': (await vault.options()).grid == grid};
        case '/verify':
          final wrong = List<int>.from(_sequences[grid]!);
          wrong[wrong.length - 1]--;
          final wrongRejected = await vault.openPattern(wrong) == null;
          final password = await vault.openPattern(_sequences[grid]!);
          var opened = false;
          if (password != null) {
            final storage = HiddenVolumeStorage.async(
              workerSpaceOpener('${dir.path}/fixture-$grid.hv'),
            );
            try {
              opened =
                  await storage.open(password: password) &&
                  await storage.getSetting('fixture-marker') == 'grid-$grid';
            } finally {
              await storage.close();
            }
          }
          result = {
            'ok': wrongRejected && opened,
            'wrong_pattern_rejected': wrongRejected,
            'encrypted_container_opened': opened,
          };
        case '/forget':
          await vault.forget();
          final fixture = File('${dir.path}/fixture-$grid.hv');
          if (await fixture.exists()) await fixture.delete();
          result = {'ok': !(await vault.options()).enabled};
        case '/background/start':
          await VeilBackground.start();
          result = {'ok': true};
        case '/background/stop':
          await VeilBackground.stop();
          result = {'ok': true};
        default:
          request.response.statusCode = HttpStatus.notFound;
          result = {'ok': false};
      }
      request.response.write(jsonEncode(result));
    } catch (error) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(
        jsonEncode({'ok': false, 'failure_type': error.runtimeType.toString()}),
      );
    } finally {
      busy = false;
      await request.response.close();
    }
  }
}
