import 'dart:typed_data';

import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../domain/chat.dart';
import '../domain/profile_avatar.dart';

/// Only locally held presentation data. Never resolve a network name or fetch
/// an image before showing the incoming call; the caller remains pinned by ID.
Future<({String label, Uint8List? avatar})> loadCallScreenCaller(
  Storage storage,
  NodeId peer,
) async {
  final values = await Future.wait<Object?>([
    storage.getContact(peer),
    storage.getSetting(peerAvatarSetting(peer.hex)),
  ]);
  final name = (values[0] as Contact?)?.name?.trim();
  final raw = values[1] as String?;
  return (
    label: name != null && name.isNotEmpty ? name : peer.short,
    avatar: raw == null ? null : ProfileAvatar.decode(raw)?.bytes,
  );
}
