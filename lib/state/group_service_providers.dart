import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../data/node/embedded_node.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../data/transport/veil_mailbox.dart';
import '../domain/chat.dart' show MessageDirection;
import '../domain/device_sync.dart';
import '../domain/group_message.dart';
import 'app_controller.dart';
import 'cloud_document_providers.dart';
import 'group_epoch_service.dart';
import 'group_service.dart';
import 'messaging_providers.dart';
import 'providers.dart';

export 'group_service.dart';

/// The group list as a stream: re-emits on every service change signal, so
/// the chats screen rebuilds like any Riverpod-backed surface.
final groupListProvider = StreamProvider<List<GroupListEntry>>((ref) async* {
  final service = ref.watch(groupServiceProvider);
  if (service == null) {
    yield const [];
    return;
  }
  yield await service.listGroups();
  final ticks = StreamController<void>();
  void onTick() {
    if (!ticks.isClosed) ticks.add(null);
  }

  service.changes.addListener(onTick);
  ref.onDispose(() {
    service.changes.removeListener(onTick);
    unawaited(ticks.close());
  });
  await for (final _ in ticks.stream) {
    yield await service.listGroups();
  }
});

/// Builds the real signer from the GUI app's active deniable identity.
final groupSignerProvider = FutureProvider<GroupSigner?>((ref) async {
  final selfId = ref.watch(
    appControllerProvider.select((state) => state.identity?.nodeId),
  );
  if (selfId == null) return null;
  final toml = await ref.read(storageProvider).loadNodeConfig();
  if (toml == null) return null;
  try {
    final result = EmbeddedNode.signMessage(toml, Uint8List(0));
    return NativeGroupSigner(
      identityToml: toml,
      selfId: selfId,
      selfPubKey: result.publicKey,
    );
  } catch (_) {
    return null;
  }
});

/// Flutter/Riverpod host wiring around the shared pure-Dart [GroupService].
final groupServiceProvider = Provider<GroupService?>((ref) {
  // Keep document ingress wired for this unlocked identity even before the
  // document UI exists; pending invites must survive until explicit adopt.
  ref.watch(cloudDocumentReplicationServiceProvider);
  final signer = ref.watch(groupSignerProvider).valueOrNull;
  if (signer == null) return null;
  final messaging = ref.read(messagingServiceProvider);
  final transport = ref.watch(veilTransportProvider);
  final epochCrypto = transport is VeilFlutterTransport
      ? transport.mailboxCrypto()
      : LoopbackMailboxCrypto(senderForOpen: signer.selfId);
  final service = GroupService(
    ref.read(storageProvider),
    signer,
    epochService: GroupEpochService(epochCrypto),
    ourCertVersion: 1,
    send: (peer, groupId, json) =>
        messaging.sendGroupSnapshot(peer, groupId.hex, json),
    sendContentRequest: (holder, json) =>
        messaging.sendGroupContentRequest(holder, json),
    sendGroupCallFrame: (peer, signal, json) =>
        messaging.sendGroupCallSignal(peer, signal, json),
    grantContentServe: messaging.grantGroupContentServe,
    startContentPull: (holder, contentId) async {
      await messaging.downloadContent(holder, contentId);
    },
    startContentPullFromAny: (holders, contentId) async {
      await messaging.downloadGroupContentFromAny(holders, contentId);
    },
  );
  ref.onDispose(() => unawaited(service.dispose()));

  messaging.onGroupEntry = (peer, bundleJson) async {
    await service.ingestGroupEntry(peer, bundleJson);
  };
  messaging.onGroupContentRequest = (peer, requestJson) {
    unawaited(service.handleContentRequest(requestJson));
  };
  messaging.onGroupCallSignal = service.ingestGroupCallFrame;
  messaging.onGroupEntryFromStranger = (peer, bundleJson) {
    unawaited(service.ingestGroupEntryFromStranger(peer, bundleJson));
  };
  messaging.allowStrangerGroupSync = service.allowStrangerGroupSync;
  unawaited(service.nudgeGroupSyncAll());

  // Multi-device mirror emit: bytes remain lazy content references.
  messaging.onMessageStored = (peer, message) {
    if (peer == service.selfId) return;
    unawaited(() async {
      if (await service.isMyDevice(peer)) return;
      final contentId = message.fileContentId ?? message.fileId;
      if (contentId == null) {
        if (message.body.isEmpty) return;
        await service.postDeviceEvent(
          DeviceSyncEvent(
            kind: DeviceSyncKind.msgMirror,
            key: message.id,
            tsMs: message.timestamp.millisecondsSinceEpoch,
            payload: {
              'peer': peer.hex,
              'dir': message.direction.name,
              'body': message.body,
            },
          ),
        );
        return;
      }
      await service.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.msgMirror,
          key: message.id,
          tsMs: message.timestamp.millisecondsSinceEpoch,
          payload: {
            'peer': peer.hex,
            'dir': message.direction.name,
            'body': message.body,
            'cid': contentId,
            'fname': message.fileName,
            'fsize': message.fileSize,
          },
        ),
        attachment: GroupAttachment(
          kind: 'file',
          dataB64: (message.thumb?.isNotEmpty ?? false)
              ? message.thumb!
              : 'AA==',
          w: 1,
          h: 1,
          cid: contentId,
        ),
      );
    }());
  };

  // Multi-device mirror apply: idempotent, content bytes remain opt-in.
  service.deviceIncoming.listen((message) {
    final event = DeviceSyncEvent.fromBody(message.body);
    if (event == null || event.kind != DeviceSyncKind.msgMirror) return;
    final peerHex = event.payload['peer'];
    final body = event.payload['body'];
    final direction = event.payload['dir'] == 'outgoing'
        ? MessageDirection.outgoing
        : MessageDirection.incoming;
    if (peerHex is! String ||
        body is! String ||
        peerHex == service.selfId.hex) {
      return;
    }
    final contentId = event.payload['cid'];
    final fileName = event.payload['fname'];
    final fileSize = event.payload['fsize'];
    final thumb = message.attachment?.dataB64;
    unawaited(
      messaging.applyMirroredMessage(
        peer: NodeId.fromHex(peerHex),
        msgId: event.key,
        direction: direction,
        body: body,
        tsMs: event.tsMs,
        fileContentId: contentId is String && contentId.isNotEmpty
            ? contentId
            : null,
        fileName: fileName is String ? fileName : null,
        fileSize: fileSize is int ? fileSize : null,
        thumb: thumb != null && thumb != 'AA==' ? thumb : null,
      ),
    );
  });
  return service;
});
