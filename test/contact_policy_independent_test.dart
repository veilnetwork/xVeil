import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/clear_policy.dart';
import 'package:xveil/domain/contact_preferences.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/disappearing_messages.dart';
import 'package:xveil/domain/p2p_policy.dart';
import 'package:xveil/state/contact_preferences_sync.dart';
import 'package:xveil/state/messaging.dart';

NodeId id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));
Future<({HiddenVolumeStorage storage, MessagingService service})> endpoint(
  bool native,
  Contact c, {
  DateTime? now,
  NodeId? self,
}) async {
  Directory? dir;
  late AsyncSpaceOpener open;
  if (native) {
    expect(ensureHiddenVolumeLoaded(), true);
    dir = await Directory.systemTemp.createTemp('xveil-policy-independent-');
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
    final kv = FakeKvLogStore();
    open = ({required password, required bool create}) async =>
        SyncWrappedAsyncKvLogStore(kv);
  }
  final s = HiddenVolumeStorage.async(open);
  expect(await s.open(password: 'fixture', createIfMissing: true), true);
  await s.upsertContact(c);
  final wire = LoopbackTransport(localNodeId: self ?? id(1));
  final service = MessagingService(
    wire,
    s,
    now: now == null ? null : () => now,
  );
  addTearDown(() async {
    await service.dispose();
    await wire.dispose();
    await s.close();
    await dir?.delete(recursive: true);
  });
  return (storage: s, service: service);
}

List<DeviceSyncEvent> eventsOf(PendingContactPreferences row) =>
    contactPreferencesEvents(row);
Future<void> apply(
  MessagingService service,
  DeviceSyncApplyGate gate,
  DeviceSyncEvent e,
) async {
  gate.offer(
    e,
    () => () async {
      if (e.key.startsWith('d:')) {
        final policy = contactPolicyFromEvent(e);
        if (policy != null) {
          await service.applyMirroredContactPolicy(id(2), policy);
        }
        return;
      }
      await service.applyMirroredContact(
        peer: id(2),
        name: e.payload['name'] as String?,
        pinned: e.payload['pin'] == true,
        archived: e.payload['arc'] == true,
        allowPeerDelete: e.payload['apd'] != false,
        clearPolicy: kDefaultClearRequestPolicy,
        disappearing: DisappearingSetting.fromMirrorJson(e.payload),
      );
    },
  );
  await gate.settle();
}

void main() {
  for (final read in [false, true]) {
    test('same identity same policy clock converges read=$read', () {
      DisappearingSetting policy(int n) => DisappearingSetting(
        ttlSeconds: read ? 60 : n,
        hideAfterReadSeconds: read ? n : null,
        setAtMs: 10,
        setBy: id(1).hex,
      );
      final a = policy(60), b = policy(120);
      final ab = DisappearingSetting.winner(a, b),
          ba = DisappearingSetting.winner(b, a);
      expect(ab.ttlSeconds, ba.ttlSeconds);
      expect(ab.hideAfterReadSeconds, ba.hideAfterReadSeconds);
    });
  }
  test('policy ordering agrees across fold, gate and domain tie breaks', () {
    final values = <DisappearingSetting>[
      for (final at in [1, 2])
        for (final by in [id(1).hex, id(3).hex])
          for (final ttl in [null, 60])
            for (final read in [null, 10])
              DisappearingSetting(
                ttlSeconds: ttl,
                hideAfterReadSeconds: read,
                setAtMs: at,
                setBy: by,
              ),
    ];
    DeviceSyncEvent event(DisappearingSetting p) => contactPolicyEvent(id(2), {
      'dtl': p.ttlSeconds,
      'dsa': p.setAtMs,
      'dsb': p.setBy,
      'har': p.hideAfterReadSeconds,
    })!;
    for (final a in values) {
      for (final b in values) {
        expect(
          isNewerDeviceSync(event(a), event(b)),
          DisappearingSetting.compare(a, b) > 0,
        );
        expect(
          DisappearingSetting.compare(
            DisappearingSetting.winner(a, b),
            DisappearingSetting.winner(b, a),
          ),
          0,
        );
      }
    }
    final forward = foldDeviceSync(values.map(event));
    final reverse = foldDeviceSync(values.reversed.map(event));
    expect(forward.values.single.toBody(), reverse.values.single.toBody());
  });
  test('malformed policy row cannot compact away a valid policy', () {
    final valid = contactPolicyEvent(id(2), {
      'dtl': 60,
      'dsa': 100,
      'dsb': id(1).hex,
      'har': null,
    })!;
    for (final payload in [
      {'dtl': -1, 'dsa': 200, 'dsb': id(1).hex},
      {'dtl': 60, 'dsa': 201, 'dsb': id(1).hex},
      {'dtl': 60, 'dsa': 200, 'dsb': id(1).hex, 'har': 0},
    ]) {
      final invalid = DeviceSyncEvent(
        kind: valid.kind,
        key: valid.key,
        tsMs: 200,
        payload: payload,
      );
      expect(contactPolicyFromEvent(invalid), isNull);
      expect(
        foldDeviceSync([invalid, valid]).values.single.toBody(),
        valid.toBody(),
      );
      expect(
        foldDeviceSync([valid, invalid]).values.single.toBody(),
        valid.toBody(),
      );
    }
  });
  test(
    'future policy is preserved structurally but does not apply early',
    () async {
      var now = 1700000000000;
      final at = now + 2 * kDeviceSyncClockSkew.inMilliseconds;
      final future = contactPolicyEvent(id(2), {
        'dtl': 120,
        'dsa': at,
        'dsb': id(1).hex,
      })!;
      expect(
        contactPolicyFromEvent(
          future,
          now: DateTime.fromMillisecondsSinceEpoch(now),
        ),
        isNull,
      );
      final gate = DeviceSyncApplyGate(nowMs: () => now);
      var writes = 0;
      bool offer() => gate.offer(
        future,
        () => () async {
          writes++;
        },
      );
      expect(offer(), false);
      now = at;
      expect(
        contactPolicyFromEvent(
          future,
          now: DateTime.fromMillisecondsSinceEpoch(now),
        ),
        isNotNull,
      );
      expect(offer(), true);
      await gate.settle();
      expect(writes, 1);
    },
  );
  test('unconfigured policy is absent; explicit off retains its revision', () {
    expect(
      contactPreferencesEvents(
        PendingContactPreferences(
          peer: id(2),
          atMs: 1,
          payload: contactPrefsPayload(Contact(nodeId: id(2))),
          token: 't',
        ),
      ),
      hasLength(1),
    );
    final off = contactPolicyEvent(id(2), {
      'dtl': null,
      'dsa': 100,
      'dsb': id(1).hex,
    });
    expect(off, isNotNull);
    expect(off!.tsMs, 100);
    expect(contactPolicyFromEvent(off)!.isOn, false);
  });
  for (final native in [false, true]) {
    test(
      'policy-only merge preserves local fields native=$native',
      () async {
        final e = await endpoint(
          native,
          Contact(
            nodeId: id(2),
            name: 'kept',
            status: ContactStatus.blocked,
            p2pOverride: ContactP2POverride.deny,
            pinned: true,
          ),
        );
        final p = DisappearingSetting(
          ttlSeconds: 60,
          setAtMs: 100,
          setBy: id(1).hex,
        );
        expect(await e.service.applyMirroredContactPolicy(id(9), p), false);
        expect(await e.storage.getContact(id(9)), isNull);
        expect(await e.service.applyMirroredContactPolicy(id(2), p), true);
        final held = (await e.storage.getContact(id(2)))!;
        expect(held.name, 'kept');
        expect(held.pinned, true);
        expect(held.status, ContactStatus.blocked);
        expect(held.p2pOverride, ContactP2POverride.deny);
        expect(
          await e.storage.pendingContactPreferences(),
          isEmpty,
          reason: 'mirror must not echo',
        );
        await e.service.dispose();
        expect(await e.service.applyMirroredContactPolicy(id(2), p), false);
      },
      skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null
          ? 'set XVEIL_HV_DYLIB to a qualified native library'
          : false,
    );

    for (final mode in ['id', 'ack']) {
      test(
        'same-identity policy wire delivery native=$native mode=$mode',
        () async {
          final clock = DateTime.now().toUtc();
          final contact = Contact(
            nodeId: id(2),
            status: ContactStatus.accepted,
          );
          final a = await endpoint(native, contact, now: clock);
          final b = await endpoint(native, contact, now: clock);
          await a.service.setContactDisappearing(id(2), 60);
          await b.service.setContactDisappearing(id(2), 120);
          final first = (await a.storage.pendingOutboxFrames()).single;
          final second = (await b.storage.pendingOutboxFrames()).single;
          if (mode == 'id') {
            expect(
              first.frameId,
              isNot(second.frameId),
              reason:
                  'same clock/identity with different content needs separate delivery identity',
            );
          } else {
            await b.service.deliverInbound(
              InboundMessage(
                src: id(2),
                payload: WireEnvelope.ack(first.frameId).encode(),
                provenance: SenderProvenance.sessionPeer,
              ),
            );
            expect(
              await b.storage.pendingOutboxFrames(),
              hasLength(1),
              reason:
                  'an ACK for the other device policy cannot retire this different policy',
            );
          }
          final c = await endpoint(
            native,
            Contact(nodeId: id(1), status: ContactStatus.accepted),
            self: id(2),
          );
          final order = mode == 'id'
              ? [first, second, second]
              : [second, first, second];
          for (final row in order) {
            await c.service.deliverInbound(
              InboundMessage(
                src: id(1),
                payload: row.wire,
                provenance: SenderProvenance.sessionPeer,
              ),
            );
          }
          expect(
            (await c.storage.getContact(id(1)))!.disappearingTtlSeconds,
            120,
          );
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null
            ? 'set XVEIL_HV_DYLIB to a qualified native library'
            : false,
      );
    }
    for (final folded in [false, true]) {
      test(
        'newer alias cannot hide independent policy native=$native folded=$folded',
        () async {
          final now = DateTime.now().millisecondsSinceEpoch;
          final a = Contact(
            nodeId: id(2),
            name: 'A',
            status: ContactStatus.accepted,
            disappearingTtlSeconds: 60,
            disappearingSetAtMs: now - 200,
            disappearingSetBy: id(1).hex,
          );
          final b = Contact(
            nodeId: id(2),
            name: 'B',
            status: ContactStatus.blocked,
            p2pOverride: ContactP2POverride.deny,
          );
          final rowA = PendingContactPreferences(
            peer: id(2),
            atMs: now - 200,
            payload: contactPrefsPayload(a),
            token: 'A',
          );
          final rowB = PendingContactPreferences(
            peer: id(2),
            atMs: now - 100,
            payload: contactPrefsPayload(b),
            token: 'B',
          );
          final ea = await endpoint(native, a), eb = await endpoint(native, b);
          final ga = DeviceSyncApplyGate(), gb = DeviceSyncApplyGate();
          if (folded) {
            for (final e in foldDeviceSync([
              ...eventsOf(rowA),
              ...eventsOf(rowB),
            ]).values) {
              await apply(ea.service, ga, e);
              await apply(eb.service, gb, e);
            }
          } else {
            for (final e in eventsOf(rowB)) {
              await apply(ea.service, ga, e);
              await apply(eb.service, gb, e);
            }
            for (final e in eventsOf(rowA)) {
              await apply(ea.service, ga, e);
              await apply(eb.service, gb, e);
            }
          }
          expect((await ea.storage.getContact(id(2)))!.name, 'B');
          final held = (await eb.storage.getContact(id(2)))!;
          expect(held.name, 'B');
          expect(held.status, ContactStatus.blocked);
          expect(held.p2pOverride, ContactP2POverride.deny);
          expect(
            held.disappearingTtlSeconds,
            60,
            reason: 'alias clock must not erase a different policy revision',
          );
        },
        skip: native && Platform.environment['XVEIL_HV_DYLIB'] == null
            ? 'set XVEIL_HV_DYLIB to a qualified native library'
            : false,
      );
    }
  }
}
