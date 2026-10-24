import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../domain/profile_avatar.dart';
import 'messaging.dart';

/// Empty key means this identity; other keys are pinned contact node IDs.
final profileAvatarProvider = StreamProvider.autoDispose
    .family<ProfileAvatar?, String>((ref, peerHex) async* {
      final messaging = ref.watch(messagingServiceProvider);
      final peer = peerHex.isEmpty ? null : NodeId.fromHex(peerHex);
      final events = StreamController<void>();
      final sub = messaging.changes.listen(events.add);
      ref.onDispose(() {
        unawaited(sub.cancel());
        unawaited(events.close());
      });
      Future<ProfileAvatar?> load() async {
        final raw = await messaging.loadAvatar(peer: peer);
        return raw == null ? null : ProfileAvatar.decode(raw);
      }

      yield await load();
      if (peer != null) unawaited(messaging.requestPeerAvatar(peer));
      await for (final _ in events.stream) {
        yield await load();
      }
    });
