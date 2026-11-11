import 'dart:async';
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
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/profile_avatar.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _HeldStorage extends HiddenVolumeStorage {
  _HeldStorage(super.open) : super.async();
  bool holdContact = false, holdConversations = false;
  String? holdSetting;
  final entered = Completer<void>(), release = Completer<void>();

  Future<void> _wait() async {
    entered.complete();
    await release.future;
  }

  @override
  Future<Contact?> getContact(NodeId peer) async {
    final value = await super.getContact(peer);
    if (holdContact && peer == _id(2)) {
      holdContact = false;
      await _wait();
    }
    return value;
  }

  @override
  Future<String?> getSetting(String key) async {
    final value = await super.getSetting(key);
    if (holdSetting == key) {
      holdSetting = null;
      await _wait();
    }
    return value;
  }

  @override
  Future<List<Conversation>> loadConversations() async {
    final value = await super.loadConversations();
    if (holdConversations) {
      holdConversations = false;
      await _wait();
    }
    return value;
  }
}

class _Wire extends LoopbackTransport {
  _Wire() : super(localNodeId: _id(1));
  final avatars = <WireEnvelope>[];

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final envelope = WireEnvelope.decode(payload);
    if (envelope.kind == WireKind.profileAvatar) avatars.add(envelope);
  }
}

Future<(_HeldStorage, _Wire, MessagingService)> _fixture(bool native) async {
  Directory? dir;
  late AsyncSpaceOpener open;
  if (native) {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    dir = await Directory.systemTemp.createTemp('xveil-avatar-consent-');
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
  final storage = _HeldStorage(open), wire = _Wire();
  expect(
    await storage.open(password: 'fixture', createIfMissing: true),
    isTrue,
  );
  final messaging = MessagingService(wire, storage);
  addTearDown(() async {
    if (!storage.release.isCompleted) storage.release.complete();
    await messaging.dispose();
    await wire.dispose();
    await storage.close();
    await dir?.delete(recursive: true);
  });
  await storage.upsertContact(Contact(nodeId: _id(2)));
  // A legitimate avatar clear is enough to exercise the transport and write
  // boundaries. Image parsing itself is covered in profile_avatar_test.dart.
  await messaging.applySelfAvatar(const ProfileAvatar(10, null).encode());
  return (storage, wire, messaging);
}

Future<void> _receive(MessagingService messaging, String body) =>
    messaging.deliverInbound(
      InboundMessage(
        src: _id(2),
        provenance: SenderProvenance.sessionPeer,
        payload: WireEnvelope(WireKind.profileAvatar, body).encode(),
      ),
    );

void main() {
  for (final native in [
    false,
    if (Platform.environment['XVEIL_AVATAR_NATIVE'] == '1') true,
  ]) {
    group(native ? 'native worker' : 'controlled store', () {
      test('a stale accepted read cannot request a blocked contact', () async {
        final (storage, wire, messaging) = await _fixture(native);
        storage.holdContact = true;
        final request = messaging.requestPeerAvatar(_id(2));
        await storage.entered.future;
        await messaging.blockContact(_id(2));
        storage.release.complete();
        await request;
        expect(wire.avatars, isEmpty);
      });

      test('a reply cannot use consent revoked during avatar load', () async {
        final (storage, wire, messaging) = await _fixture(native);
        storage.holdSetting = kSelfAvatarSetting;
        final reply = _receive(messaging, '?');
        await storage.entered.future;
        await messaging.blockContact(_id(2));
        storage.release.complete();
        await reply;
        expect(wire.avatars, isEmpty);
      });

      test('an announcement rechecks a stale contact list', () async {
        final (storage, wire, messaging) = await _fixture(native);
        storage.holdConversations = true;
        final announce = messaging.announceSelfAvatar();
        await storage.entered.future;
        await messaging.blockContact(_id(2));
        storage.release.complete();
        await announce;
        expect(wire.avatars, isEmpty);
      });

      test('a blocked sender cannot finish a pending avatar update', () async {
        final (storage, _, messaging) = await _fixture(native);
        final key = peerAvatarSetting(_id(2).hex);
        const previous = ProfileAvatar(10, null),
            next = ProfileAvatar(11, null);
        await storage.putSetting(key, previous.encode());
        storage.holdSetting = key;
        final update = _receive(messaging, next.encode());
        await storage.entered.future;
        await messaging.blockContact(_id(2));
        storage.release.complete();
        await update;
        expect(await messaging.loadAvatar(peer: _id(2)), previous.encode());
      });
    });
  }
}
