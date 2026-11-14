@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/identity_setup_intent.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

class _Node implements NodeController {
  int starts = 0;
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final cut in [
    'before-pair',
    'after-pair',
    'profile',
    'credential',
    'boot',
  ]) {
    test(
      'SIGKILL at $cut preserves an explicit safe creation/replay path',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        SharedPreferences.setMockInitialValues({'onboarded': true});
        final temp = Directory.systemTemp.createTempSync('xveil-setup-crash-');
        addTearDown(() async {
          if (await temp.exists()) await temp.delete(recursive: true);
        });
        final marker = File('${temp.path}/gate');
        final child = await Process.start(
          'dart',
          [
            '--packages=.dart_tool/package_config.json',
            'test/native/support/identity_setup_crash_writer.dart',
            temp.path,
            cut,
            marker.path,
          ],
          environment: {'TMPDIR': '/private/tmp/'},
        );
        final stdoutDone = child.stdout.drain<void>();
        final stderrDone = child.stderr.drain<void>();
        int? status;
        final exited = child.exitCode.then((value) => status = value);
        try {
          final watch = Stopwatch()..start();
          while (!await marker.exists()) {
            if (status != null) {
              fail('owned setup writer exited before its gate ($status)');
            }
            if (watch.elapsed > const Duration(seconds: 60)) {
              fail('owned setup writer did not reach its gate');
            }
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          expect(await marker.readAsString(), 'ready');
        } finally {
          final killed = child.kill(ProcessSignal.sigkill);
          final code = await exited;
          if (marker.existsSync()) {
            expect(killed, isTrue);
            expect(code, -9);
          }
          await Future.wait([stdoutDone, stderrDone]);
        }
        final path = '${temp.path}/hidden.hv';
        final storage = HiddenVolumeStorage(
          hvSpaceOpener(
            path,
            argon: hv.ArgonPreset.min,
            paddingPreset: hv.PaddingPreset.none,
          ),
          keysOpener: hvKeysSpaceOpener(path),
        );
        final node = _Node();
        final app = ProviderContainer(
          overrides: [
            singleSpaceStorageProvider.overrideWithValue(storage),
            nodeControllerProvider.overrideWithValue(node),
          ],
        );
        try {
          final ctrl = app.read(appControllerProvider.notifier);
          await app.read(prefsProvider.future);
          await Future<void>.delayed(Duration.zero);
          await ctrl.unlock('synthetic crash password');
          expect(
            app.read(appControllerProvider).phase,
            AppPhase.identitySetupRecovery,
          );
          expect(node.starts, 0);
          if (cut == 'before-pair') {
            expect(ctrl.canResumeIdentitySetup, isTrue);
            expect(ctrl.canReplayIdentitySetup, isFalse);
            expect(
              await storage.open(password: 'synthetic crash password'),
              isTrue,
            );
            expect(await storage.hasFile(kIdentitySetupJournalFile), isFalse);
            expect(
              await storage.hasFile(kIdentitySetupCredentialFile),
              isFalse,
            );
            expect(await storage.loadProfile(), isNull);
            await storage.close();
          } else {
            expect(ctrl.canReplayIdentitySetup, isTrue);
            expect(ctrl.canResumeIdentitySetup, isFalse);
            expect(
              await ctrl.replayIdentitySetup('synthetic crash password'),
              isTrue,
            );
            expect(app.read(appControllerProvider).phase, AppPhase.ready);
            expect(await storage.loadFile(kSovereignBundleSetting), [1, 2, 3]);
            expect(await storage.loadNodeConfig(), 'synthetic config');
            expect((await storage.loadProfile())!.displayName, 'Preserved');
            expect(await storage.hasFile(kIdentitySetupJournalFile), isFalse);
            expect(node.starts, 1);
          }
        } finally {
          await app.read(appControllerProvider.notifier).lock();
          app.dispose();
          await storage.close();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
