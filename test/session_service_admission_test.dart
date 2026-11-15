import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/cloud_document_providers.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging_providers.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/vpn_controller.dart';

final _self = NodeId(Uint8List.fromList(List.filled(32, 1)));
final _other = NodeId(Uint8List.fromList(List.filled(32, 2)));

class _Application extends AppController {
  _Application({this.ready = true, this.phase});
  final bool ready;
  final AppPhase? phase;
  @override
  AppState build() => ready
      ? AppState(phase ?? AppPhase.ready, identity: Identity(nodeId: _self))
      : const AppState(AppPhase.locked);
}

class _Signer extends Fake implements GroupSigner {
  _Signer(this.selfId);
  @override
  final NodeId selfId;
}

class _Notifications extends NotificationService {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> cancelAll() async {
    entered.complete();
    await release.future;
  }
}

class _Vpn extends Fake implements VpnBackend {
  @override
  Future<VpnBackendState> probe() => status();
  @override
  Future<VpnBackendState> status() async =>
      const VpnBackendState(VpnBackendPhase.unsupported);
  @override
  Future<VpnBackendState> stop() => status();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'real lock seals service admission before its notification await',
    () async {
      final notifications = _Notifications();
      final c = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_Application.new),
          notificationServiceProvider.overrideWithValue(notifications),
          vpnBackendProvider.overrideWithValue(_Vpn()),
        ],
      );
      addTearDown(c.dispose);
      final controller = c.read(appControllerProvider.notifier);
      expect(c.read(sessionWorkIdentityProvider), _self);
      final locking = controller.lock();
      await notifications.entered.future;
      try {
        // The ordinary UI state intentionally retains the old identity until
        // cleanup ends; it cannot serve as permission to build another service.
        expect(c.read(appControllerProvider).identity?.nodeId, _self);
        expect(c.read(sessionEndDepthProvider), 1);
        expect(c.read(sessionWorkIdentityProvider), isNull);
      } finally {
        notifications.release.complete();
      }
      await locking;
      expect(c.read(sessionEndDepthProvider), 0);
      expect(c.read(appControllerProvider).phase, AppPhase.locked);
      expect(c.read(sessionWorkIdentityProvider), isNull);
    },
  );

  for (final boundary in ['locked', 'ending', 'preparing', 'recovery']) {
    final ending = boundary == 'ending';
    test(
      'group and document services avoid dependencies while $boundary',
      () async {
        var dependencyReads = 0;
        final c = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(
              () => _Application(
                ready: boundary != 'locked',
                phase: boundary == 'preparing'
                    ? AppPhase.preparingNode
                    : boundary == 'recovery'
                    ? AppPhase.profileErasureRecovery
                    : null,
              ),
            ),
            storageProvider.overrideWith((ref) {
              dependencyReads++;
              throw StateError('synthetic closed storage');
            }),
            cloudDocumentSignerProvider.overrideWith((ref) async => null),
            groupSignerProvider.overrideWith((ref) async => _Signer(_self)),
          ],
        );
        addTearDown(c.dispose);
        // Seed a retained signer even though the current session admits no work.
        await c.read(groupSignerProvider.future);
        if (ending) c.read(sessionEndDepthProvider.notifier).state = 1;
        expect(c.read(groupServiceProvider), isNull);
        expect(c.read(cloudDocumentReplicationServiceProvider), isNull);
        expect(dependencyReads, 0);
      },
    );
  }

  for (final state in ['closed', 'foreign', 'refreshing', 'active']) {
    test('group service handles $state signer/storage boundary', () async {
      final storage = HiddenVolumeStorage(
        ({required password, required create}) => FakeKvLogStore(),
      );
      if (state != 'closed') {
        expect(
          await storage.open(password: 'synthetic', createIfMissing: true),
          isTrue,
        );
      }
      addTearDown(storage.close);
      var messagingReads = 0, refreshing = false;
      final refresh = Completer<void>();
      final signer = _Signer(state == 'foreign' ? _other : _self);
      final c = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_Application.new),
          storageProvider.overrideWithValue(storage),
          cloudDocumentReplicationServiceProvider.overrideWithValue(null),
          groupSignerProvider.overrideWith((ref) async {
            if (refreshing) await refresh.future;
            return signer;
          }),
          messagingServiceProvider.overrideWith((ref) {
            messagingReads++;
            throw StateError('synthetic service construction reached');
          }),
        ],
      );
      addTearDown(c.dispose);
      await c.read(groupSignerProvider.future);
      if (state == 'refreshing') {
        refreshing = true;
        c.invalidate(groupSignerProvider);
        final retained = c.read(groupSignerProvider);
        expect(retained.isLoading, isTrue);
        expect(retained.value, same(signer));
      }
      try {
        if (state == 'active') {
          // Positive control: a current signer/open store reaches ordinary
          // service construction. The tripwire prevents unrelated setup here.
          expect(
            () => c.read(groupServiceProvider),
            throwsA(
              predicate<Object>(
                (e) => e.toString().contains(
                  'synthetic service construction reached',
                ),
              ),
            ),
          );
          expect(messagingReads, 1);
        } else {
          expect(c.read(groupServiceProvider), isNull);
          expect(messagingReads, 0);
        }
      } finally {
        if (!refresh.isCompleted) refresh.complete();
      }
    });
  }
}
