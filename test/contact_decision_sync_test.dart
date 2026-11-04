import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/contact_decision_sync.dart';

NodeId id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));
void main() {
  tearDown(errorJournal.clear);
  for (final native in [false, true]) {
    test(
      'accepted contact retains device publication after failed callback native=$native',
      () async {
        Directory? dir;
        final fake = FakeKvLogStore();
        late AsyncSpaceOpener open;
        if (native) {
          expect(ensureHiddenVolumeLoaded(), true);
          dir = await Directory.systemTemp.createTemp('xveil-contact-sync-');
          final path = '${dir.path}/store.hv';
          HvKvLogStore(
            hv.HvSpace.create(
              path: path,
              password: Uint8List.fromList(utf8.encode('fixture')),
              argon: hv.ArgonPreset.min,
            ),
          ).close();
          open = workerSpaceOpener(path);
        } else {
          open = ({required password, required bool create}) async =>
              SyncWrappedAsyncKvLogStore(fake);
        }
        late AsyncKvLogStore raw;
        final storage = HiddenVolumeStorage.async(({
          required password,
          required bool create,
        }) async {
          final s = await open(password: password, create: create);
          if (s != null) raw = s;
          return s;
        });
        final transport = LoopbackTransport(localNodeId: id(1));
        final service = MessagingService(transport, storage);
        try {
          expect(
            await storage.open(password: 'fixture', createIfMissing: true),
            true,
          );
          await storage.upsertContact(
            Contact(nodeId: id(2), status: ContactStatus.pendingIncoming),
          );
          service.onContactStatusChanged = (_, _) =>
              throw StateError('private publication failure');
          await expectLater(service.acceptContact(id(2)), throwsStateError);
          expect(
            (await storage.getContact(id(2)))?.status,
            ContactStatus.accepted,
          );
          await service.dispose();
          await storage.close();
          expect(await storage.open(password: 'fixture'), true);
          final keys = await raw.kvKeys(Ns.settings);
          final pending = keys.where(
            (k) => utf8.decode(k).startsWith('contact.status.pending.v1:'),
          );
          expect(
            pending,
            hasLength(1),
            reason:
                'a callback must not be the only device publication obligation',
          );
          final decision = (await storage.pendingContactDecisions()).single;
          final handedOff = <String>[];
          final publisher = ContactDecisionPublisher(
            storage: storage,
            isLinked: () async => true,
            isOwnDevice: (_) async => false,
            loadPublished: () async => const [],
            post: (events) async {
              handedOff.addAll(events.map((e) => e.toBody()));
              return List.filled(events.length, true);
            },
          );
          try {
            expect(await publisher.flush(), true);
            expect(handedOff, [contactDecisionEvent(decision).toBody()]);
            expect(await storage.pendingContactDecisions(), isEmpty);
          } finally {
            await publisher.close();
          }
        } finally {
          await service.dispose();
          await transport.dispose();
          await storage.close();
          await dir?.delete(recursive: true);
        }
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
    );
  }
}
