import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/nickname_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/self_presentation.dart';
import 'support/fake_setting_storage.dart';

final _node = NodeId(Uint8List.fromList(List.filled(32, 7)));

class _App extends AppController {
  @override
  AppState build() => AppState(
    AppPhase.ready,
    identity: Identity(nodeId: _node, displayName: 'old onboarding label'),
  );
}

void main() {
  test(
    'a newly claimed or mirrored name updates the public header live',
    () async {
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(FakeSettingStorage()),
          appControllerProvider.overrideWith(_App.new),
          messagingServiceProvider.overrideWith(
            (ref) => throw StateError('offline'),
          ),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(selfPresentationProvider).label, 'old onboarding label');
      await c
          .read(nicknameControllerProvider.notifier)
          .applyMirroredClaim('{"name":"alice","weight":9}');
      expect(c.read(selfPresentationProvider).label, '@alice');
      expect(c.read(selfPresentationProvider).nodeId, _node.hex);
      await c
          .read(nicknameControllerProvider.notifier)
          .applyMirroredClaim('{"name":"bob","weight":10}');
      expect(c.read(selfPresentationProvider).label, '@bob');
      expect(c.read(selfPresentationProvider).nodeId, _node.hex);
    },
  );
}
