import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/node/embedded_node.dart';
import '../data/node/identity_config_fields.dart';
import '../data/node/space_discovery_transport.dart';
import '../data/transport/bootstrap_invite.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../data/transport/veil_mailbox.dart';
import '../domain/chat.dart' show MessageDirection;
import '../domain/device_sync.dart';
import '../domain/group_message.dart';
import '../domain/inline_custom_emoji.dart';
import '../domain/space_public_feed_transport.dart';
import 'app_controller.dart';
import 'cloud_capability_service.dart' show cloudProviderSlotFor;
import 'cloud_document_providers.dart';
import 'group_epoch_service.dart';
import 'group_service.dart';
import 'messaging_core.dart';
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
  final ticks = StreamController<void>();
  void onTick() {
    if (!ticks.isClosed) ticks.add(null);
  }

  // Subscribe before the initial read so a create that lands while this
  // provider starts cannot disappear between listGroups and addListener.
  service.changes.addListener(onTick);
  ref.onDispose(() {
    service.changes.removeListener(onTick);
    unawaited(ticks.close());
  });
  yield await service.listGroups();
  await for (final _ in ticks.stream) {
    yield await service.listGroups();
  }
});

/// Spaces have a separate user-facing surface from group chats.
final spaceListProvider = StreamProvider<List<GroupListEntry>>((ref) async* {
  final service = ref.watch(groupServiceProvider);
  if (service == null) {
    yield const [];
    return;
  }
  final ticks = StreamController<void>();
  void onTick() {
    if (!ticks.isClosed) ticks.add(null);
  }

  // Spaces use the same durable index protocol and need the same startup-race
  // protection, while remaining a separate list from ordinary group chats.
  service.changes.addListener(onTick);
  ref.onDispose(() {
    service.changes.removeListener(onTick);
    unawaited(ticks.close());
  });
  yield await service.listSpaces();
  await for (final _ in ticks.stream) {
    yield await service.listSpaces();
  }
});

/// Read-only public subscriptions are intentionally separate from member
/// Spaces: consumers can render them together, but no UI accidentally gains a
/// [GroupBundle] or membership action by treating them as [GroupListEntry].
final publicSpaceSubscriptionListProvider =
    StreamProvider<List<SpacePublicSubscriptionView>>((ref) async* {
      final service = ref.watch(groupServiceProvider);
      if (service == null) {
        yield const [];
        return;
      }
      final ticks = StreamController<void>();
      void onTick() {
        if (!ticks.isClosed) ticks.add(null);
      }

      service.changes.addListener(onTick);
      ref.onDispose(() {
        service.changes.removeListener(onTick);
        unawaited(ticks.close());
      });
      yield await service.publicSpaceSubscriptions();
      await for (final _ in ticks.stream) {
        yield await service.publicSpaceSubscriptions();
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
  final replication = ref.watch(cloudDocumentReplicationServiceProvider);
  final signer = ref.watch(groupSignerProvider).value;
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
    sendSpaceInvite: messaging.sendSpaceInvite,
    sendSpaceInviteDecision: messaging.sendSpaceInviteDecision,
    sendSpaceJoinRequest: messaging.sendSpaceJoinRequest,
    sendSpaceJoinDecision: messaging.sendSpaceJoinDecision,
    sendSpaceModerationAppeal: messaging.sendSpaceModerationAppeal,
    sendSpaceModerationAppealDecision:
        messaging.sendSpaceModerationAppealDecision,
    sendSpaceAbuseReport: messaging.sendSpaceAbuseReport,
    sendSpaceAbuseReportDecision: messaging.sendSpaceAbuseReportDecision,
    sendSpaceRecommendation: messaging.sendSpaceRecommendation,
    revokeSpaceRecommendation: messaging.revokeSpaceRecommendation,
    sendContentRequest: (holder, json) =>
        messaging.sendGroupContentRequest(holder, json),
    sendContentReceipt: (holder, json) =>
        messaging.sendGroupContentReceipt(holder, json),
    sendPublicFeedRequest: messaging.sendSpacePublicFeedRequest,
    sendPublicFeedChunk: messaging.sendSpacePublicFeedChunk,
    sendPublicMediaGrantRequest: messaging.sendSpacePublicMediaGrantRequest,
    sendGroupCallFrame: (peer, signal, json) =>
        messaging.sendGroupCallSignal(peer, signal, json),
    grantContentServe: messaging.grantGroupContentServe,
    grantPublicContentServe: (peer, contentId) =>
        messaging.grantGroupContentServe(
          peer,
          contentId,
          ttl: kSpacePublicMediaGrantRequestWindow,
        ),
    startContentPull: (holder, contentId) async {
      await messaging.downloadContent(holder, contentId);
    },
    startContentPullFromAny: (holders, contentId) async {
      await messaging.downloadGroupContentFromAny(holders, contentId);
    },
    startPublicContentPullFromAny: (holders, contentId) async {
      await messaging.downloadPublicSpaceContentFromAny(holders, contentId);
    },
    activePeers: () async => {
      for (final peer in await transport.peers())
        if (peer.isActive) peer.nodeId,
    },
    spaceDiscoveryTransport: NativeSpaceDiscoveryTransport(signer.selfId),
  );
  // Member content hosting: give every device of this identity its own
  // provider slot. The host seed and alias come from documentId + epochKey, so
  // they are identical on all of them and the slot is the only thing keeping
  // two sovereign devices from registering as the same provider. The device
  // list only exists here, and the replication service cannot read it back
  // (it is built BEFORE this provider, which watches it), so install it now.
  replication?.memberProviderSlot = () async =>
      cloudProviderSlotFor(service.selfId, await service.deviceMembers());
  service.startSpaceLifecycleMaintenance();
  service.startScheduledSpacePostMaintenance();
  service.startPublicSpaceDiscoveryMaintenance();

  messaging.onGroupEntry = (peer, bundleJson) async {
    await service.ingestGroupEntry(peer, bundleJson);
  };
  messaging.onSpaceInvite = (peer, inviteJson) async {
    await service.receiveSpaceInvite(peer, inviteJson);
  };
  messaging.onSpaceInviteDecision = (peer, decisionJson) async {
    await service.receiveSpaceInviteDecision(peer, decisionJson);
  };
  messaging.onSpaceJoinRequest = service.receiveSpaceJoinRequest;
  messaging.onSpaceJoinDecision = service.receiveSpaceJoinDecision;
  messaging.onSpaceModerationAppeal = service.receiveSpaceModerationAppeal;
  messaging.onSpaceModerationAppealDecision =
      service.receiveSpaceModerationAppealDecision;
  messaging.onSpaceAbuseReport = service.receiveSpaceAbuseReport;
  messaging.onSpaceAbuseReportDecision =
      service.receiveSpaceAbuseReportDecision;
  messaging.onSpaceRecommendation = service.acceptsSpaceRecommendationCard;
  messaging.onGroupContentRequest = (peer, requestJson) {
    unawaited(service.handleContentRequest(requestJson));
  };
  messaging.onGroupContentReceipt = (peer, receiptJson) {
    unawaited(service.handleContentReceipt(peer, receiptJson));
  };
  messaging.onSpacePublicFeedRequest = service.handlePublicFeedObjectRequest;
  messaging.onSpacePublicFeedChunk = service.handlePublicFeedObjectChunk;
  messaging.onSpacePublicMediaGrantRequest =
      service.handlePublicMediaGrantRequest;
  messaging.onGroupContentVerifiedSources =
      service.handleVerifiedContentSources;
  messaging.onGroupCallSignal = service.ingestGroupCallFrame;
  messaging.onGroupEntryFromStranger = (peer, bundleJson) {
    unawaited(service.ingestGroupEntryFromStranger(peer, bundleJson));
  };
  messaging.allowStrangerGroupSync = service.allowStrangerGroupSync;
  // A revoked device stops owing state, so stop holding it for it.
  service.onMemberRevoked = (device) => messaging.dropPendingFramesFor(device);
  messaging.groupBindingsOwner = service;
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
              if (message.customEmoji.isNotEmpty)
                'ce': encodeInlineCustomEmoji(message.customEmoji),
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
        attachment: MediaObject(
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
  final deviceMirror = service.deviceIncoming.listen((message) {
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
    final customEmoji = parseInlineCustomEmoji(body, event.payload['ce']);
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
        customEmoji: customEmoji,
      ),
    );
  });
  ref.onDispose(() {
    // Detach before disposing, and only what is still ours.
    //
    // In all-online the messaging service belongs to one identity and lives for
    // the whole session; THIS provider is rebuilt for the active identity and
    // disposed on every switch. Its callbacks used to stay attached, so the
    // next frame arriving on the old identity's pipeline was handed to a
    // disposed group service: it could still write storage and then throw on a
    // closed controller, with durable frames already acknowledged and
    // deduplicated by then.
    //
    // Guarded by the owner token because dispose order is not something to bet
    // on: if a newer build has already installed its own callbacks on this same
    // service, clearing them here would break the identity that just became
    // active. `_detachGroupBindings` is a no-op in that case.
    _detachGroupBindings(messaging, service);
    unawaited(deviceMirror.cancel());
    unawaited(service.dispose());
  });
  // THIS DEVICE's own transport key, from the NODE CONFIG — the copy that is
  // rewritten when a deniably-booted node is promoted to its real identity.
  // The transport's cached id is the stub's on a promoted node, and a device
  // group that believes it is the stub excludes nobody: measured as a restored
  // device sending every snapshot to itself.
  //
  // Assigned rather than constructed because reading it is asynchronous and
  // this provider is not. Until it lands a device group sends nothing, which is
  // the safe half of the trade — see `snapshotRecipients`.
  unawaited(
    ref
        .read(storageProvider)
        .loadNodeConfig()
        .then((toml) {
          final fields = toml == null ? null : identityConfigFields(toml);
          if (fields == null) return;
          service.myDevice = BootstrapInvite(
            publicKey: fields.publicKey,
            nonce: fields.nonce,
            algo: fields.algo,
          ).nodeId;
        })
        .catchError((Object e) {
          devLog(() => 'xVeil[devices]: own device id unavailable: $e');
        }),
  );
  return service;
});

/// Clear the group-layer callbacks [service] installed on [messaging].
///
/// A no-op unless [service] is still the owner: a newer build may already have
/// rebound this same messaging service to its own group service, and clearing
/// those would silence the identity that just became active.
///
/// Every `messaging.<callback> =` in [groupServiceProvider] has its counterpart
/// here, and `group_bindings_detached_test` fails if one grows without the
/// other — a binding that outlives its service is invisible until a frame
/// arrives for it.
void _detachGroupBindings(MessagingService messaging, GroupService service) {
  if (!identical(messaging.groupBindingsOwner, service)) return;
  messaging.groupBindingsOwner = null;
  messaging.onGroupEntry = null;
  messaging.onSpaceInvite = null;
  messaging.onSpaceInviteDecision = null;
  messaging.onSpaceJoinRequest = null;
  messaging.onSpaceJoinDecision = null;
  messaging.onSpaceModerationAppeal = null;
  messaging.onSpaceModerationAppealDecision = null;
  messaging.onSpaceAbuseReport = null;
  messaging.onSpaceAbuseReportDecision = null;
  messaging.onSpaceRecommendation = null;
  messaging.onGroupContentRequest = null;
  messaging.onGroupContentReceipt = null;
  messaging.onSpacePublicFeedRequest = null;
  messaging.onSpacePublicFeedChunk = null;
  messaging.onSpacePublicMediaGrantRequest = null;
  messaging.onGroupContentVerifiedSources = null;
  messaging.onGroupCallSignal = null;
  messaging.onGroupEntryFromStranger = null;
  messaging.allowStrangerGroupSync = null;
  messaging.onMessageStored = null;
}
