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
import 'package:xveil/state/contact_preferences_sync.dart';
import 'package:xveil/domain/clear_policy.dart';
import 'package:xveil/domain/p2p_policy.dart';

NodeId id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));
Future<({HiddenVolumeStorage storage, AsyncKvLogStore Function() raw})> opened(
  bool native,
) async {
  Directory? dir;
  late AsyncSpaceOpener opener;
  late AsyncKvLogStore raw;
  if (native) {
    expect(ensureHiddenVolumeLoaded(), true);
    dir = await Directory.systemTemp.createTemp('xveil-pref-ledger-');
    final path = '${dir.path}/store.hv';
    HvKvLogStore(
      hv.HvSpace.create(
        path: path,
        password: Uint8List.fromList(utf8.encode('fixture')),
        argon: hv.ArgonPreset.min,
      ),
    ).close();
    opener = workerSpaceOpener(path);
  } else {
    final kv = FakeKvLogStore();
    opener = ({required password, required bool create}) async =>
        SyncWrappedAsyncKvLogStore(kv);
  }
  final storage = HiddenVolumeStorage.async(({
    required password,
    required bool create,
  }) async {
    final value = await opener(password: password, create: create);
    if (value != null) raw = value;
    return value;
  });
  addTearDown(() async {
    await storage.close();
    await dir?.delete(recursive: true);
  });
  expect(await storage.open(password: 'fixture', createIfMissing: true), true);
  await storage.upsertContact(
    Contact(nodeId: id(2), status: ContactStatus.accepted),
  );
  return (storage: storage, raw: () => raw);
}

void main() {
  tearDown(errorJournal.clear);
  for (final native in [false, true]) {
    for (final mode in ['large', 'guard', 'snapshot', 'localOnly', 'remove']) {
      test(
        'durable preference ledger native=$native mode=$mode',
        () async {
          final f = await opened(native), peer = id(2);
          final s = f.storage;
          final wire = LoopbackTransport(localNodeId: id(1));
          final service = MessagingService(wire, s);
          addTearDown(() async {
            await service.dispose();
            await wire.dispose();
          });
          if (mode == 'localOnly') {
            await service.setContactP2POverride(peer, ContactP2POverride.deny);
            expect(await s.pendingContactPreferences(), isEmpty);
            expect(
              await s.updateContactPrefs(id(9), (c) => c, queueForSync: true),
              isNull,
            );
            return;
          }
          await service.setContactName(peer, 'original snapshot');
          final first = (await s.pendingContactPreferences()).single;
          if (mode == 'large') {
            for (var i = 0; i < 20; i++) {
              await service.setContactName(peer, '${'x' * 1880}$i');
            }
            final large = (await s.pendingContactPreferences()).single;
            expect(large.payload['name'], '${'x' * 1880}19');
            expect(await s.acknowledgeContactPreferences(first), false);
            expect(large.atMs, greaterThan(first.atMs));
            await s.close();
            expect(await s.open(password: 'fixture'), true);
            expect(
              (await s.pendingContactPreferences()).single.token,
              large.token,
            );
            await service.setContactName(peer, 'small');
            final dataKeys = (await f.raw().kvKeys(Ns.settings)).where(
              (k) => utf8.decode(k).startsWith('contact.prefs.data.v1:'),
            );
            expect(
              dataKeys,
              hasLength(1),
              reason: 'shrink removes old tail parts',
            );
          } else if (mode == 'guard') {
            await service.setContactName(peer, 'newer');
            var called = false;
            expect(
              await s.updateContactPrefs(peer, (c) {
                called = true;
                return c.copyWith(name: 'stale');
              }, onlyIfLocalPrefsToken: first.token),
              isNull,
            );
            expect(called, false);
            final latest = (await s.pendingContactPreferences()).single;
            expect(await s.acknowledgeContactPreferences(latest), true);
            await s.close();
            expect(await s.open(password: 'fixture'), true);
            expect(
              await s.updateContactPrefs(
                peer,
                (c) => c.copyWith(name: 'newer'),
                onlyIfLocalPrefsToken: latest.token,
              ),
              isNotNull,
            );
            expect(await s.pendingContactPreferences(), isEmpty);
            return;
          } else if (mode == 'snapshot') {
            await service.applyMirroredContact(
              peer: peer,
              name: 'sibling',
              pinned: true,
              archived: false,
              allowPeerDelete: true,
              clearPolicy: kDefaultClearRequestPolicy,
            );
            expect((await s.getContact(peer))!.name, 'sibling');
            expect(
              (await s.pendingContactPreferences()).single.payload['name'],
              'original snapshot',
            );
            expect(
              (await s.pendingContactPreferences()).single.token,
              first.token,
            );
          } else if (mode == 'remove') {
            await s.removeConversation(peer);
            expect(await s.pendingContactPreferences(), isEmpty);
            expect(
              (await f.raw().kvKeys(
                Ns.settings,
              )).where((k) => utf8.decode(k).startsWith('contact.prefs.')),
              isEmpty,
            );
            return;
          }
          final current = (await s.pendingContactPreferences()).single;
          final sent = <String>[];
          final publisher = ContactPreferencesPublisher(
            storage: s,
            isLinked: () async => true,
            isOwnDevice: (_) async => false,
            loadPublished: () async => const [],
            post: (rows) async {
              sent.addAll(rows.map((r) => contactPreferencesEvent(r).toBody()));
              return List.filled(rows.length, true);
            },
          );
          addTearDown(publisher.close);
          expect(await publisher.flush(), true);
          expect(sent, [contactPreferencesEvent(current).toBody()]);
          expect(await s.pendingContactPreferences(), isEmpty);
          expect(
            (await f.raw().kvKeys(Ns.settings)).where(
              (k) => utf8.decode(k).startsWith('contact.prefs.data.v1:'),
            ),
            isEmpty,
          );
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null,
      );
    }
    test(
      'contact preference retains publication after failed callback native=$native',
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
            Contact(nodeId: id(2), status: ContactStatus.accepted),
          );
          service.onContactPrefsChanged = (_) =>
              throw StateError('private publication failure');
          await expectLater(
            service.setContactName(id(2), 'stored preference'),
            throwsStateError,
          );
          expect((await storage.getContact(id(2)))?.name, 'stored preference');
          await service.dispose();
          await storage.close();
          expect(await storage.open(password: 'fixture'), true);
          final keys = await raw.kvKeys(Ns.settings);
          expect(
            keys.where(
              (k) => utf8.decode(k).startsWith('contact.prefs.pending.v1:'),
            ),
            hasLength(1),
            reason:
                'committed preferences need a durable publication obligation',
          );
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
