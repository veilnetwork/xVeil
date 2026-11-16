import 'dart:typed_data';

import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../domain/chat.dart';
import '../domain/profile_avatar.dart';

String _callerLabel(Contact? contact, NodeId peer) {
  final name = contact?.name?.trim();
  return name != null && name.isNotEmpty ? name : peer.short;
}

/// Desktop text-only alerts do not need an avatar read or decode.
Future<String> loadCallScreenCallerLabel(Storage storage, NodeId peer) async =>
    _callerLabel(await storage.getContact(peer), peer);

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
  final raw = values[1] as String?;
  return (
    label: _callerLabel(values[0] as Contact?, peer),
    avatar: raw == null ? null : ProfileAvatar.decode(raw)?.bytes,
  );
}
