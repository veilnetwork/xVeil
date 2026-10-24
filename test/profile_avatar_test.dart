import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/profile_avatar.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';
import 'support/fake_setting_storage.dart';

NodeId _id(int v) => NodeId(Uint8List.fromList(List.filled(32, v)));

class _Transport extends LoopbackTransport {
  _Transport() : super(localNodeId: _id(1));
  final sent = <WireEnvelope>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(WireEnvelope.decode(payload));
  }
}

void main() {
  final png = image.encodePng(image.Image(width: 128, height: 128));
  final bytes = encodeAvatarPixels(png)!;

  test(
    'encoded profile fits a real setting cap and strips source metadata',
    () async {
      final noisy = image.Image(width: 128, height: 128);
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          noisy.setPixelRgb(
            x,
            y,
            (x * 71 + y * 13) % 256,
            (x * 11 + y * 41) % 256,
            x ^ y,
          );
        }
      }
      noisy.exif.imageIfd.imageDescription = 'private-original-metadata';
      final avatar = encodeAvatarPixels(image.encodePng(noisy))!;
      expect(avatar.length, lessThanOrEqualTo(kAvatarMaxBytes));
      final record = ProfileAvatar(9007199254740991, avatar).encode();
      await FakeSettingStorage().putSetting(kSelfAvatarSetting, record);
      expect(ProfileAvatar.decode(record), isNotNull);
      expect(
        WireEnvelope(WireKind.profileAvatar, record).encode().length,
        lessThan(6144),
      );
      expect(image.decodeJpg(avatar)!.exif.hasTag(0x010e), isFalse);
    },
  );

  test(
    'bad format, oversized bytes or dimensions never enter the image cache',
    () {
      expect(ProfileAvatar.decode('{"v":1,"at":1,"d":"garbage"}'), isNull);
      final tooBig = image.encodeJpg(image.Image(width: 129, height: 1));
      expect(ProfileAvatar.decode(ProfileAvatar(1, tooBig).encode()), isNull);
      expect(
        ProfileAvatar.decode(ProfileAvatar(1, Uint8List(1400)).encode()),
        isNull,
      );
      expect(ProfileAvatar.decode('{"v":1,"at":-1,"d":null}'), isNull);
    },
  );

  late HiddenVolumeStorage storage;
  late _Transport transport;
  late MessagingService messaging;
  final peer = _id(2);
  setUp(() async {
    final backing = FakeHvContainer();
    storage = HiddenVolumeStorage(backing.passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    transport = _Transport();
    messaging = MessagingService(transport, storage);
  });
  tearDown(() async {
    await messaging.dispose();
    await storage.close();
  });

  Future<void> receive(
    String raw, {
    SenderProvenance proof = SenderProvenance.sessionPeer,
  }) => messaging.deliverInbound(
    InboundMessage(
      src: peer,
      provenance: proof,
      payload: WireEnvelope(WireKind.profileAvatar, raw).encode(),
    ),
  );

  test(
    'only an authenticated accepted contact can set or request a photo',
    () async {
      final raw = ProfileAvatar(1, bytes).encode();
      await messaging.setSelfAvatar(bytes);
      await receive(raw);
      expect(await messaging.loadAvatar(peer: peer), isNull);
      await storage.upsertContact(Contact(nodeId: peer));
      await receive(raw, proof: SenderProvenance.claimed);
      expect(await messaging.loadAvatar(peer: peer), isNull);
      await receive(raw);
      expect(
        ProfileAvatar.decode((await messaging.loadAvatar(peer: peer))!)!.bytes,
        bytes,
      );
      await receive('?');
      await receive('?');
      expect(
        transport.sent.where((f) => f.kind == WireKind.profileAvatar),
        hasLength(1),
      );
      expect(await storage.loadMessages(peer.hex), isEmpty);
    },
  );

  test(
    'a clear survives late old data and blocked contacts cannot update',
    () async {
      await storage.upsertContact(Contact(nodeId: peer));
      await receive(ProfileAvatar(10, bytes).encode());
      await receive(const ProfileAvatar(11, null).encode());
      await receive(ProfileAvatar(10, bytes).encode());
      expect(
        ProfileAvatar.decode((await messaging.loadAvatar(peer: peer))!)!.bytes,
        isNull,
      );
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.blocked),
      );
      await receive(ProfileAvatar(12, bytes).encode());
      await receive('?');
      expect(transport.sent, isEmpty);
      expect(
        ProfileAvatar.decode((await messaging.loadAvatar(peer: peer))!)!.bytes,
        isNull,
      );
    },
  );

  test(
    'self settings transfer independently, including pre-link photo and clear',
    () async {
      final raw = await messaging.setSelfAvatar(bytes);
      final otherBacking = FakeHvContainer();
      final otherStorage = HiddenVolumeStorage(otherBacking.passwordOpener);
      await otherStorage.open(password: 'other', createIfMissing: true);
      final other = MessagingService(_Transport(), otherStorage);
      try {
        await other.applySelfAvatar(raw);
        expect(await other.loadAvatar(), raw);
        final cleared = await messaging.setSelfAvatar(null);
        await other.applySelfAvatar(cleared);
        expect(
          ProfileAvatar.decode((await other.loadAvatar())!)!.bytes,
          isNull,
        );
      } finally {
        await other.dispose();
        await otherStorage.close();
      }
    },
  );
}
