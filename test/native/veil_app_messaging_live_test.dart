import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

/// End-to-end through the APP's real messaging pipeline (MessagingService +
/// storage, the same objects the UI uses) over two live peered nodes: A sends,
/// and the message lands in B's storage as an incoming Message. Env-gated:
/// XVEIL_TEST_SOCK_A / XVEIL_TEST_SOCK_B + VEIL_FFI_DYLIB.
SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

ProviderContainer _instance(VeilFlutterTransport t, HiddenVolumeStorage s) =>
    ProviderContainer(overrides: [
      veilTransportProvider.overrideWithValue(t),
      storageProvider.overrideWithValue(s),
    ]);

void main() {
  final sockA = Platform.environment['XVEIL_TEST_SOCK_A'];
  final sockB = Platform.environment['XVEIL_TEST_SOCK_B'];
  final skip = (sockA == null || sockB == null || sockA.isEmpty || sockB.isEmpty)
      ? 'set XVEIL_TEST_SOCK_A + XVEIL_TEST_SOCK_B + VEIL_FFI_DYLIB'
      : false;

  test('A.sendText lands as an incoming Message in B.storage', () async {
    final tA = await VeilFlutterTransport.connect(sockA!);
    final tB = await VeilFlutterTransport.connect(sockB!);
    final sA = HiddenVolumeStorage(_memOpener());
    final sB = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);

    final cA = _instance(tA, sA);
    final cB = _instance(tB, sB);
    addTearDown(() async {
      cA.dispose();
      cB.dispose();
      await tA.dispose();
      await tB.dispose();
    });

    final mA = cA.read(messagingServiceProvider);
    final mB = cB.read(messagingServiceProvider); // both listen
    final aId = await tA.nodeId();
    final bId = await tB.nodeId();

    Future<bool> until(Future<bool> Function() cond) async {
      for (var i = 0; i < 40; i++) {
        if (await cond()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return false;
    }

    // Full consent handshake over the real overlay: request -> accept -> msg.
    await mA.sendRequest(bId, 'hi');
    expect(
        await until(() async =>
            (await sB.getContact(aId))?.status == ContactStatus.pendingIncoming),
        isTrue);

    await mB.acceptContact(aId);
    expect(
        await until(() async =>
            (await sA.getContact(bId))?.status == ContactStatus.accepted),
        isTrue);

    await mA.sendText(bId, 'hello pipeline');
    expect(
        await until(() async => (await sB.loadMessages(aId.hex))
            .any((m) => m.body == 'hello pipeline')),
        isTrue,
        reason: 'B should receive the message after accepting');
  }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
}
