import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/profile_avatar.dart';
import 'package:xveil/state/call_screen_caller.dart';

void main() {
  final peer = NodeId.fromHex('1' * 64);
  test(
    'locally saved name and validated avatar are returned without network',
    () async {
      final storage = HiddenVolumeStorage.fromStore(FakeKvLogStore());
      await storage.upsertContact(Contact(nodeId: peer, name: '  Лена  '));
      final jpg = image.encodeJpg(image.Image(width: 16, height: 16));
      await storage.putSetting(
        peerAvatarSetting(peer.hex),
        ProfileAvatar(1000, jpg).encode(),
      );
      final caller = await loadCallScreenCaller(storage, peer);
      expect(caller.label, 'Лена');
      expect(caller.avatar, jpg);
      await storage.close();
    },
  );
  test(
    'absent contact/photo and invalid avatar have honest fallbacks',
    () async {
      final storage = HiddenVolumeStorage.fromStore(FakeKvLogStore());
      var caller = await loadCallScreenCaller(storage, peer);
      expect(caller.label, peer.short);
      expect(caller.avatar, isNull);
      await storage.upsertContact(Contact(nodeId: peer, name: '   '));
      await storage.putSetting(peerAvatarSetting(peer.hex), 'not an avatar');
      caller = await loadCallScreenCaller(storage, peer);
      expect(caller.label, peer.short);
      expect(caller.avatar, isNull);
      await storage.close();
    },
  );
  test(
    'presentation stays in the explicitly captured identity storage',
    () async {
      final a = HiddenVolumeStorage.fromStore(FakeKvLogStore());
      final b = HiddenVolumeStorage.fromStore(FakeKvLogStore());
      await a.upsertContact(Contact(nodeId: peer, name: 'A alias'));
      await b.upsertContact(Contact(nodeId: peer, name: 'B alias'));
      expect((await loadCallScreenCaller(a, peer)).label, 'A alias');
      expect((await loadCallScreenCaller(b, peer)).label, 'B alias');
      await a.close();
      await b.close();
    },
  );
}
