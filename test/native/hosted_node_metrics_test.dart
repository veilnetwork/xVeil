// Opt-in real default hosted boot, synthetic spaces and local native nodes.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/identity/veil_identity.dart';
import 'package:xveil/data/node/bundled_seeds.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/transport/veil_native.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/multi_identity_session.dart';
import '../support/fake_multi_space.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['XVEIL_NATIVE_HOSTED_METRICS'] == '1';
  test(
    'real hosted nodes boot while the single-node metrics port is held',
    () async {
      SharedPreferences.setMockInitialValues({});
      expect(ensureVeilClientLoaded(), isTrue);
      expect(
        kXVeilDebugHookDefine,
        isTrue,
        reason: 'test must exercise the metrics-enabled boot',
      );
      // Hold the historical diagnostic port, not a node's QUIC listener. It
      // must never be a prerequisite for booting any hosted identity.
      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        39997,
      );
      final root = await Directory.systemTemp.createTemp(
        'xveil-hosted-metrics-',
      );
      final backing = FakeMultiSpaceBacking();
      final roster = [
        for (var i = 1; i <= 2; i++)
          RosterEntry(
            label: 'child-$i',
            spaceKeys: Uint8List.fromList(List.filled(64, i)),
          ),
      ];
      final session = MultiIdentitySession(
        SyncWrappedAsyncMultiSpaceBacking(backing),
        runtimeDirBase: root.path,
        listenPortBase: 43000,
      );
      final ports = <int>[];
      try {
        for (final entry in roster) {
          final storage = HiddenVolumeStorage.fromStore(
            MultiSpaceKvLogStore(backing, backing.openSpace(entry.spaceKeys)),
          );
          await storage.saveProfile(UserProfile(displayName: entry.label));
          await setBundledSeedsAllowedInSpace(storage, false);
          await storage.putSetting(kMeetingPointsSettingKey, '[]');
          final phrase = veilGeneratePhrase();
          expect(phrase, isNotNull);
          await RealVeilStack.ensureNodeConfig(storage, identityPhrase: phrase);
        }
        await session.bootAll(roster);
        for (final entry in roster) {
          final stack = session.stackFor(entry.label);
          expect(
            stack,
            isNotNull,
            reason: 'a hosted storage view is not a running node',
          );
          expect(stack!.controller.current.phase, NodePhase.connected);
          expect(stack.myInvite.nodeId.hex, isNot('a0' * 32));
          ports.add(stack.listenPort);
        }
        expect(
          session.stackFor('child-1')!.myInvite.nodeId,
          isNot(session.stackFor('child-2')!.myInvite.nodeId),
        );
      } finally {
        await session.disposeAll();
        await blocker.close();
        expect(session.containerLockReleased, isTrue);
        for (final port in ports) {
          final probe = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            port,
            reuseAddress: false,
          );
          probe.close();
        }
        await root.delete(recursive: true);
      }
    },
    skip: enabled
        ? false
        : 'set XVEIL_NATIVE_HOSTED_METRICS=1 with the pinned SDK and debug-hook define',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
