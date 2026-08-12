import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../api/api_server.dart';
import '../api/blob_sources.dart';
import '../api/group_api_adapter.dart';
import '../api/webhook_pump.dart';
import '../core/ids.dart';

import '../core/cleanup_legs.dart';
import '../data/node/embedded_node.dart';
import '../data/node/node_controller.dart';
import '../data/node/space_discovery_transport.dart';
import '../data/native_libs.dart';
import '../data/serve_source.dart';
import '../data/storage/async_kv_log_store.dart';
import '../data/storage/hidden_volume_storage.dart';
import '../data/transport/bootstrap_invite.dart';
import '../data/transport/relay_key_cache.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../data/transport/veil_mailbox.dart';
import '../data/veil_stack.dart';
import '../domain/chat.dart';
import '../domain/identity.dart';
import '../domain/space_public_feed_transport.dart';
import '../state/group_epoch_service.dart';
import '../state/group_service.dart';
import '../state/mailbox_orchestrator.dart';
import '../state/mailbox_service.dart';
import '../state/messaging_core.dart';
import '../state/ratchet_persistence.dart' show ratchetPersistenceFor;
import 'headless_config.dart';
import 'secret_file.dart';

const _tokensKey = 'api.tokens';
const _webhookKey = 'api.webhook';

/// A real xVeil identity/node/messaging/API stack without Flutter or Riverpod.
/// All durable state remains in the same deniable hidden-volume schema as the
/// GUI app; runtime sockets and the public obfs4 PSK are removed on shutdown.
class HeadlessRuntime {
  HeadlessRuntime._({
    required this.config,
    required this.storage,
    required this.stack,
    required this.messaging,
    required this.groups,
    required this.api,
    required this.tokens,
    this._mailbox,
    this._nodeStatus,
    required this._webhook,
  });

  final HeadlessConfig config;
  final HiddenVolumeStorage storage;
  final RealVeilStack stack;
  final MessagingService messaging;
  final GroupService groups;
  final ApiServer api;
  final List<ApiToken> tokens;

  final MailboxService? _mailbox;
  final StreamSubscription<NodeStatus>? _nodeStatus;
  final WebhookPump _webhook;
  bool _closed = false;

  static Future<HeadlessRuntime> start({
    required HeadlessConfig config,
    required String password,
    bool createIfMissing = false,
    String? identityPhrase,
    String? apiToken,
    List<String> apiFileRoots = const <String>[],
    int? debugMetricsPort,
    VeilMailboxCrypto? groupEpochCryptoOverride,
  }) async {
    if (password.isEmpty) throw ArgumentError('password must not be empty');
    await Directory(config.storePath).parent.create(recursive: true);
    await Directory(config.blobDir).create(recursive: true);

    final storage = HiddenVolumeStorage.async(
      workerSpaceOpener(config.storePath),
    )..useOnDiskTier(Directory(config.blobDir));
    RealVeilStack? stack;
    MessagingService? messaging;
    GroupService? groups;
    ApiServer? api;
    MailboxService? mailbox;
    StreamSubscription<NodeStatus>? nodeStatus;
    WebhookPump? webhookPump;
    try {
      final opened = await storage.open(
        password: password,
        createIfMissing: createIfMissing,
      );
      if (!opened) throw StateError('unable to unlock deniable store');

      String? psk;
      final pskPath = config.obfs4PskFile;
      if (pskPath != null) {
        // Type-checked and bounded, not a bare `readAsString`. Note WHERE this
        // sits: the container is already unlocked and the password is already
        // in memory, so a named pipe here does not fail the start, it hangs it
        // — silently, forever, with the store open. Not routed through
        // [readSecretFile] on purpose: that demands owner-only permissions,
        // which is the wrong ask for a key that ships inside every APK.
        psk = await readSharedSecretFile(pskPath, 'obfs4 PSK');
      }

      stack = await RealVeilStack.startDeniable(
        storage: storage,
        // A BASE. The daemon creates its own directory under it and owns
        // only that: `runtime_dir` used to be chmod-ed and then recursively
        // deleted as given, so `/` or a home directory in the config was
        // re-permissioned on boot and emptied on shutdown (audit C-02).
        runtimeDirBase: config.runtimeDir,
        listenPort: config.listenPort,
        anonymous: config.anonymous,
        bootstrapPeers: config.bootstrapPeers,
        udpReflectors: config.udpReflectors,
        obfs4Psk: psk,
        identityPhrase: identityPhrase,
        debugMetricsPort: debugMetricsPort,
        lib: _veilNativeHandle(),
      );
      final nodeId = await stack.transport.nodeId();
      // The node id comes from the node, full stop (audit XV-06). This used to
      // compare it against a copy kept in the profile record and REFUSE TO
      // START on a mismatch — which every GUI-onboarded profile had, because
      // onboarding wrote a random id there before the node existed. A daemon
      // that will not run on a profile the app happily uses is one profile with
      // two answers; there is only one now, and nothing to compare.
      //
      // The record is still written when absent: its presence is what tells the
      // app's clash guards that this space belongs to an identity and must not
      // have a roster written over it.
      if (await storage.loadProfile() == null) {
        await storage.saveProfile(const UserProfile());
      }

      messaging = MessagingService(
        stack.transport,
        storage,
        anonymous: config.anonymous,
      )
        ..sourceOpener = veilSourceOpener
        // A daemon runs for weeks and restarts like anything else. Without this
        // its ratchet sessions would be rebuilt from scratch on every start,
        // which is the same silent loss the app path exists to close — and a
        // headless peer is the one most likely to be restarted by a supervisor
        // while the other side keeps sending.
        ..ratchet = ratchetPersistenceFor(stack, storage);
      messaging.start();

      final identityToml = await storage.loadNodeConfig();
      if (identityToml == null) {
        throw StateError('running veil node has no deniable identity config');
      }
      final groupNative = _veilNativeHandle();
      final groupProbe = EmbeddedNode.signMessage(
        identityToml,
        Uint8List(0),
        lib: groupNative,
      );
      final groupSigner = NativeGroupSigner(
        identityToml: identityToml,
        selfId: nodeId,
        selfPubKey: groupProbe.publicKey,
        lib: groupNative,
      );
      // The override is an integration-test seam for exercising unrelated
      // public protocols without waiting for cold ML-KEM DHT publication.
      // Production callers always use the live node mailbox crypto below.
      final epochCrypto =
          groupEpochCryptoOverride ??
          (stack.transport is VeilFlutterTransport
              ? (stack.transport as VeilFlutterTransport).mailboxCrypto()
              : LoopbackMailboxCrypto(senderForOpen: nodeId));
      final activePeerTransport = stack.transport;
      groups = GroupService(
        storage,
        groupSigner,
        epochService: GroupEpochService(epochCrypto),
        ourCertVersion: 1,
        send: (peer, groupId, json) =>
            messaging!.sendGroupSnapshot(peer, groupId.hex, json),
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
            messaging!.sendGroupContentRequest(holder, json),
        sendPublicFeedRequest: messaging.sendSpacePublicFeedRequest,
        sendPublicFeedChunk: messaging.sendSpacePublicFeedChunk,
        sendPublicMediaGrantRequest: messaging.sendSpacePublicMediaGrantRequest,
        sendGroupCallFrame: (peer, signal, json) =>
            messaging!.sendGroupCallSignal(peer, signal, json),
        grantContentServe: messaging.grantGroupContentServe,
        grantPublicContentServe: (peer, contentId) =>
            messaging!.grantGroupContentServe(
              peer,
              contentId,
              ttl: kSpacePublicMediaGrantRequestWindow,
            ),
        startContentPull: (holder, contentId) async {
          await messaging!.downloadContent(holder, contentId);
        },
        startContentPullFromAny: (holders, contentId) async {
          await messaging!.downloadGroupContentFromAny(holders, contentId);
        },
        startPublicContentPullFromAny: (holders, contentId) async {
          await messaging!.downloadPublicSpaceContentFromAny(
            holders,
            contentId,
          );
        },
        activePeers: () async => {
          for (final peer in await activePeerTransport.peers())
            if (peer.isActive) peer.nodeId,
        },
        spaceDiscoveryTransport: NativeSpaceDiscoveryTransport(nodeId),
      );
      groups.startSpaceLifecycleMaintenance();
      groups.startScheduledSpacePostMaintenance();
      groups.startPublicSpaceDiscoveryMaintenance();
      _wireGroupIngress(messaging, groups);

      final relays = mailboxRelayCandidates(config.bootstrapPeers);
      if (relays.isEmpty) {
        // The node joins the network from seeds compiled into the native, so a
        // config with no bootstrap_peers still connects and looks healthy —
        // while silently having NO mailbox. Without one it never advertises a
        // KEM key, so nobody can deposit for it: it can start conversations but
        // cannot be reached first, and a contact request sent to it is dropped
        // with nothing to see on either side. Say so where the operator will
        // read it.
        stderr.writeln(
          'xveil: no mailbox relays — set bootstrap_peers in the config. '
          'This node can reach others but CANNOT BE REACHED FIRST: contact '
          'requests sent to it will not arrive.',
        );
      }
      if (stack.transport case final VeilFlutterTransport transport
          when relays.isNotEmpty) {
        mailbox = await transport.buildMailboxService(
          deliver: messaging.deliverInbound,
          relayKeyCache: StorageRelayKeyCache(storage),
          poisonedBlobs: PoisonedBlobRegistry(
            getSetting: storage.getSetting,
            putSetting: storage.putSetting,
          ),
        );
        messaging.attachMailbox(mailbox);
        unawaited(mailbox.start(relays: relays));
      }
      nodeStatus = stack.controller.status().listen((next) {
        if (next.phase == NodePhase.connected) {
          unawaited(messaging!.reconcileOnConnect());
          if (mailbox != null) unawaited(mailbox.start(relays: relays));
        }
      });

      final loadedTokens = await _loadTokens(storage);
      final roots = List<String>.unmodifiable(apiFileRoots);
      if (apiToken != null && apiToken.isNotEmpty) {
        // DECLARATIVE, like the rest of the daemon's flags: the provisioned
        // token's allowed folders are exactly what this start was told, so an
        // operator withdraws one by restarting without it (audit XV-08).
        final index = loadedTokens.indexWhere(
          (t) => _constantTimeEqual(t.token, apiToken),
        );
        if (index < 0) {
          loadedTokens.add(
            ApiToken(
              id: _mintId(),
              name: 'headless',
              token: apiToken,
              readOnly: false,
              fileRoots: roots,
            ),
          );
          await _persistTokens(storage, loadedTokens);
        } else if (!_sameRoots(loadedTokens[index].fileRoots, roots)) {
          loadedTokens[index] = loadedTokens[index].withFileRoots(roots);
          await _persistTokens(storage, loadedTokens);
        }
      } else if (roots.isNotEmpty) {
        throw StateError(
          '--api-file-root names folders for the token supplied by '
          '--api-token-file; pass that too, or drop the roots',
        );
      } else if (loadedTokens.isEmpty) {
        throw StateError(
          'no API token is provisioned; supply --api-token-file',
        );
      }

      // A durable offer made under a token's `fileRoots` may only be reopened
      // while that grant still holds — the record is not its own
      // authorization. Re-asked on every reopen, never cached: the daemon's
      // token list is reloaded from the store, so a revoked root stops
      // answering rather than stopping eventually.
      messaging.servedSourceAuthorizer = (path, roots) async {
        if (await resolveSendableFile(path, roots) == null) return false;
        for (final token in loadedTokens) {
          if (token.fileRoots.isEmpty) continue;
          if (await resolveSendableFile(path, token.fileRoots) != null) {
            return true;
          }
        }
        return false;
      };

      var webhookUrl = await storage.getSetting(_webhookKey);
      if (webhookUrl?.isEmpty ?? false) webhookUrl = null;
      final events = _events(messaging, groups);
      webhookPump = WebhookPump(() => events);
      final groupApi = GroupApiAdapter(
        groups,
        registerContentSource: messaging.registerGroupContentStreaming,
        loadContent: (contentId) => storedBlobSource(storage, contentId),
      );

      final handler = ApiHandler(
        tokens: loadedTokens,
        status: () => {
          'ok': stack!.controller.current.phase == NodePhase.connected,
          'nodeId': nodeId.hex,
          'short': nodeId.short,
          'api': 'v1',
          'host': 'headless',
          'nodePhase': stack.controller.current.phase.name,
          'peerCount': stack.controller.current.peerCount,
        },
        // No lock or identity switch: a headless host has one identity, opened
        // by whoever started it, and "locking" it would mean shutting the
        // daemon down — which is the supervisor's job, not an API call's.
        account: () async => {
          'ok': stack!.controller.current.phase == NodePhase.connected,
          // Whether this node can be reached first. False means no mailbox:
          // see the startup warning.
          'reachableOffline': relays.isNotEmpty,
          'phase': stack.controller.current.phase.name,
          'nodeId': nodeId.hex,
          'short': nodeId.short,
          'isMaster': false,
          'identities': const <String>[],
          'peerCount': stack.controller.current.peerCount,
          'api': 'v1',
          'host': 'headless',
        },
        // The daemon's own invite: without it a running bot can only ever
        // ASK for a contact, never be added by the person running it.
        accountInvite: () async => stack!.myInvite.toUri(),
        contacts: () => _contacts(storage),
        requestContact: (target, greeting) =>
            _requestContact(stack!, messaging!, target, greeting),
        contactAction: (peer, action) =>
            _contactAction(messaging!, peer, action),
        send: (to, body) => _send(messaging!, to, body),
        messages: (peer, limit) => _messages(storage, peer, limit),
        sendFile: (to, path, name, roots) =>
            _sendFile(messaging!, to, path, name, roots),
        loadFile: (fileId) => storedBlobSource(storage, fileId),
        placeCall: (_, _) async => 'calls unavailable in headless mode',
        callState: () => null,
        callAction: (_) async {},
        callsAvailable: false,
        groups: groupApi.list,
        spaces: groupApi.listSpaces,
        spaceMemberships: groupApi.listSpaceMemberships,
        createGroup: groupApi.create,
        createSpace: groupApi.createSpace,
        groupMessages: groupApi.messages,
        sendGroupMessage: groupApi.sendMessage,
        sendGroupFile: groupApi.sendFile,
        fetchGroupFile: groupApi.fetchFile,
        loadGroupFile: groupApi.loadFile,
        groupMembers: groupApi.members,
        groupMemberAction: groupApi.memberAction,
        spaceAccess: groupApi.spaceAccess,
        spaceAccessAction: groupApi.spaceAccessAction,
        spacePolicyAudit: groupApi.policyAudit,
        spaceObservability: groupApi.spaceObservability,
        renameGroup: groupApi.rename,
        leaveGroup: groupApi.leave,
        spaceChannels: groupApi.channels,
        spacePosts: groupApi.posts,
        spacePostDraft: groupApi.postDraft,
        saveSpacePostDraft: groupApi.savePostDraft,
        clearSpacePostDraft: groupApi.clearPostDraft,
        spaceScheduledPosts: groupApi.scheduledPosts,
        scheduleSpacePost: groupApi.schedulePost,
        cancelScheduledSpacePost: groupApi.cancelScheduledPost,
        publishScheduledSpacePostNow: groupApi.publishScheduledPostNow,
        publishSpacePost: groupApi.publishPost,
        editSpacePost: groupApi.editPost,
        deleteSpacePost: groupApi.deletePost,
        setSpacePostPinned: groupApi.setPostPinned,
        reactToSpacePost: groupApi.reactToPost,
        spaceRecommendationCampaigns: (space, includeRevoked) => groupApi
            .recommendationCampaigns(space, includeRevoked: includeRevoked),
        createSpaceRecommendationCampaign:
            groupApi.createRecommendationCampaign,
        revokeSpaceRecommendationCampaign:
            groupApi.revokeRecommendationCampaign,
        shareSpaceRecommendation: groupApi.shareRecommendation,
        spaceRecommendationPolicy: groupApi.recommendationPolicy,
        setSpaceRecommendationPolicy: groupApi.setRecommendationPolicy,
        spaceRecommendationShares: groupApi.recommendationShares,
        revokeSpaceRecommendationShare: groupApi.revokeRecommendationShare,
        spaceFeed: groupApi.feed,
        spaceFeedTypeFilter: groupApi.feedTypeFilter,
        setSpaceFeedTypeFilter: groupApi.setFeedTypeFilter,
        publicSpaceDiscoverySearch: groupApi.searchPublicSpaces,
        publicSpaceDiscoveryResolve: groupApi.resolvePublicSpace,
        publicSpaceSubscriptions: groupApi.publicSubscriptions,
        subscribePublicSpace: groupApi.subscribePublicSpace,
        unsubscribePublicSpace: groupApi.unsubscribePublicSpace,
        spaceSubscription: groupApi.subscription,
        updateSpaceSubscription:
            (
              space, {
              feedEnabled,
              notificationsEnabled,
              commentNotifications,
              hiddenFromRecommendations,
            }) => groupApi.updateSubscription(
              space,
              feedEnabled: feedEnabled,
              notificationsEnabled: notificationsEnabled,
              commentNotifications: commentNotifications,
              hiddenFromRecommendations: hiddenFromRecommendations,
            ),
        setSpaceFeedPostHidden: groupApi.setFeedPostHidden,
        spaceInvites: groupApi.invites,
        decideSpaceInvite: groupApi.decideInvite,
        spaceJoinRequests: groupApi.joinRequests,
        spaceJoinRequestAction: groupApi.joinRequestAction,
        spaceProfile: groupApi.profile,
        updateSpaceDescription: groupApi.updateDescription,
        spaceLifecycle: groupApi.lifecycle,
        setSpaceLifecycle: groupApi.setLifecycle,
        spaceRetention: groupApi.retention,
        setSpaceRetention: groupApi.setRetention,
        spaceChannelRetention: groupApi.channelRetention,
        setSpaceChannelRetention: groupApi.setChannelRetention,
        spaceRules: groupApi.rules,
        publishSpaceRules: groupApi.publishRules,
        acceptSpaceRules: groupApi.acceptRules,
        spaceModerationAudit: groupApi.moderationAudit,
        moderateSpace: groupApi.moderate,
        revokeSpaceModeration: groupApi.revokeModeration,
        spaceModerationAppeals: groupApi.moderationAppeals,
        spaceModerationAppealAction: groupApi.moderationAppealAction,
        spaceAbuseReports: groupApi.abuseReports,
        spaceAbuseReportAction: groupApi.abuseReportAction,
        createSpaceChannel: groupApi.createChannel,
        updateSpaceChannel: groupApi.updateChannel,
        spaceChannelAction: groupApi.channelAction,
        setSpaceChannelMembers: groupApi.setChannelMembers,
        spaceChannelMessages: groupApi.channelMessages,
        sendSpaceChannelMessage: groupApi.sendChannelMessage,
        startGroupCall: (_, _) async => 'group calls unavailable',
        groupCallState: () => null,
        groupCallAction: (_) async => 'group calls unavailable',
        groupCallPosture: (_, _, _) async => 'group calls unavailable',
        groupCallsAvailable: false,
        webhook: () => webhookUrl,
        setWebhook: (url) async {
          webhookUrl = url;
          await storage.putSetting(_webhookKey, url ?? '');
          await webhookPump!.setTarget(url);
        },
      );
      api = ApiServer(handler, events);
      await api.start(config.apiPort);
      await webhookPump.setTarget(webhookUrl);

      return HeadlessRuntime._(
        config: config,
        storage: storage,
        stack: stack,
        messaging: messaging,
        groups: groups,
        api: api,
        tokens: List.unmodifiable(loadedTokens),
        mailbox: mailbox,
        nodeStatus: nodeStatus,
        webhook: webhookPump,
      );
    } catch (_) {
      // Independent legs, same reason as `close()`: this unwinds a boot that
      // already failed, and a second failure here must not leave the rest of
      // the half-built runtime running. The original error is what the caller
      // needs, so every cleanup error is swallowed in favour of it.
      await runCleanupLegs('headless-boot', [
        ('api', () async => api?.stop()),
        ('webhook', () async => webhookPump?.close()),
        ('node-status', () async => nodeStatus?.cancel()),
        ('mailbox', () async => mailbox?.dispose()),
        ('messaging', () async => messaging?.dispose()),
        ('groups', () async => groups?.dispose()),
        ('stack', () async => stack?.dispose()),
        ('storage', storage.close),
      ]);
      rethrow;
    }
  }

  static void _wireGroupIngress(
    MessagingService messaging,
    GroupService groups,
  ) {
    messaging.onGroupEntry = (peer, bundleJson) {
      unawaited(groups.ingestGroupEntry(peer, bundleJson));
    };
    messaging.onSpaceInvite = (peer, inviteJson) async {
      await groups.receiveSpaceInvite(peer, inviteJson);
    };
    messaging.onSpaceInviteDecision = (peer, decisionJson) async {
      await groups.receiveSpaceInviteDecision(peer, decisionJson);
    };
    messaging.onSpaceJoinRequest = groups.receiveSpaceJoinRequest;
    messaging.onSpaceJoinDecision = groups.receiveSpaceJoinDecision;
    messaging.onSpaceModerationAppeal = groups.receiveSpaceModerationAppeal;
    messaging.onSpaceModerationAppealDecision =
        groups.receiveSpaceModerationAppealDecision;
    messaging.onSpaceAbuseReport = groups.receiveSpaceAbuseReport;
    messaging.onSpaceAbuseReportDecision =
        groups.receiveSpaceAbuseReportDecision;
    messaging.onSpaceRecommendation = groups.acceptsSpaceRecommendationCard;
    messaging.onGroupContentRequest = (peer, requestJson) {
      unawaited(groups.handleContentRequest(requestJson));
    };
    messaging.onSpacePublicFeedRequest = groups.handlePublicFeedObjectRequest;
    messaging.onSpacePublicFeedChunk = groups.handlePublicFeedObjectChunk;
    messaging.onSpacePublicMediaGrantRequest =
        groups.handlePublicMediaGrantRequest;
    messaging.onGroupCallSignal = groups.ingestGroupCallFrame;
    messaging.onGroupEntryFromStranger = (peer, bundleJson) {
      unawaited(groups.ingestGroupEntryFromStranger(peer, bundleJson));
    };
    messaging.allowStrangerGroupSync = groups.allowStrangerGroupSync;
    unawaited(groups.nudgeGroupSyncAll());
  }

  static Stream<Map<String, dynamic>> _events(
    MessagingService messaging,
    GroupService groups,
  ) => Stream.multi((controller) {
    final subscriptions = <StreamSubscription<dynamic>>[
      messaging.incoming.listen(
        (notice) => controller.add({
          'type': 'message',
          'from': notice.from.hex,
          'preview': notice.preview,
          'isFile': notice.isFile,
        }),
        onError: controller.addError,
      ),
      groups.incoming.listen(
        (event) => controller.add({
          'type': 'group_message',
          'groupId': event.groupId.hex,
          'from': event.message.author.hex,
          'preview': GroupService.previewOf(event.message),
          'isFile': event.message.attachment != null,
        }),
        onError: controller.addError,
      ),
    ];
    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
  }, isBroadcast: true);

  static Future<List<ApiToken>> _loadTokens(HiddenVolumeStorage storage) async {
    final raw = await storage.getSetting(_tokensKey);
    if (raw == null || raw.isEmpty) return <ApiToken>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw StateError('stored API token list is corrupt');
    return decoded.map(ApiToken.fromJson).whereType<ApiToken>().toList();
  }

  static Future<void> _persistTokens(
    HiddenVolumeStorage storage,
    List<ApiToken> tokens,
  ) => storage.putSetting(
    _tokensKey,
    jsonEncode(tokens.map((t) => t.toJson()).toList()),
  );

  /// Every contact, INCLUDING the ones still waiting on an answer.
  ///
  /// Listing only accepted contacts left a daemon unable to see that somebody
  /// had asked to reach it: the request arrives, but nothing in the API says
  /// so, and accepting needs a node id the operator had no way to learn. A bot
  /// that cannot notice it is being added is a bot nobody can add.
  ///
  /// `status` is carried explicitly so a caller that only wants the ones it
  /// can message still can — it is the same word the app's own projection
  /// uses.
  static Future<List<Map<String, dynamic>>> _contacts(
    HiddenVolumeStorage storage,
  ) async => [
    for (final c in await storage.loadConversations())
      {
        'nodeId': c.peer.nodeId.hex,
        'short': c.peer.nodeId.short,
        if (c.peer.name != null) 'name': c.peer.name,
        'status': c.peer.status.name,
        'canMessage': c.peer.status == ContactStatus.accepted,
      },
  ];

  static Future<String?> _send(
    MessagingService messaging,
    String toHex,
    String body,
  ) async {
    try {
      await messaging.sendText(NodeId.fromHex(toHex), body);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// The headless twin of `ApiServerController._requestContact`, and it carried
  /// the same defect: a bare node id was accepted and answered `ok`, having
  /// handed the node nothing to seal to. One [contactRequestRefusal] decides it
  /// for both, so the two cannot drift into disagreeing about what is
  /// deliverable.
  static Future<String?> _requestContact(
    RealVeilStack stack,
    MessagingService messaging,
    String target,
    String greeting,
  ) async {
    final refusal = contactRequestRefusal(target);
    if (refusal != null) return refusal;
    try {
      final invite = BootstrapInvite.parse(target);
      await stack.addContact(invite);
      await messaging.sendRequest(invite.nodeId, greeting);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  static Future<String?> _contactAction(
    MessagingService messaging,
    String peerHex,
    String action,
  ) async {
    try {
      final peer = NodeId.fromHex(peerHex);
      if (action == 'accept') {
        await messaging.acceptContact(peer);
      } else if (action == 'block') {
        await messaging.blockContact(peer);
      } else {
        return 'unsupported contact action';
      }
      return null;
    } catch (e) {
      return '$e';
    }
  }

  static Future<List<Map<String, dynamic>>> _messages(
    HiddenVolumeStorage storage,
    String peerHex,
    int limit,
  ) async {
    final NodeId peer;
    try {
      peer = NodeId.fromHex(peerHex);
    } catch (_) {
      return const [];
    }
    return [
      for (final m in await storage.loadMessages(peer.hex, limit: limit))
        {
          'id': m.id,
          'body': m.body,
          'direction': m.direction.name,
          'sentAt': m.timestamp.millisecondsSinceEpoch,
          'status': m.status.name,
          if (m.fileName != null) 'fileName': m.fileName,
          if (m.fileId != null) 'fileId': m.fileId,
        },
    ];
  }

  /// The daemon's twin of the GUI controller's send, and the one that matters
  /// most for audit X-02: a headless instance is the case where `fileRoots`
  /// is a real boundary rather than a formality — a service account or a
  /// container with a drop folder, where the process is NOT simply the person
  /// who can already read everything.
  ///
  /// ONE open, for the reason spelled out on [veilOpenSourceForSend]: size and
  /// bytes have to come from the same descriptor or the offer can describe one
  /// file while serving another. [veilOpenPinnedSource] brackets that open with
  /// an identity stamp on either side, so a name swapped ACROSS THE OPEN
  /// refuses before anything is offered (audit X-01). The comparison across the
  /// READ stays detection only — the offer is already out by the time it can
  /// fire.
  ///
  /// What those stamps do NOT close, and what this comment used to claim they
  /// did (audit report11 XV-M3): the window between the API edge's
  /// authorization and this open. Both stamps are taken AFTER that window, so a
  /// swap completed before the first one is seen identically by both and
  /// passes. `lib/state/api_server.dart` says the same thing the right way
  /// round — "what remains is the gap between the API edge's authorization
  /// check and this open, and Dart cannot close it" — and the two comments
  /// disagreed, with this one being the wrong half.
  ///
  /// It matters more here than the wording suggests, because the precondition
  /// is inside the granted root rather than outside it: this entry point is
  /// documented as serving "a service account or a container with a drop
  /// folder", and write access to that folder is exactly what the attack
  /// needs. Closing it properly needs descriptor-relative open, which Dart does
  /// not expose (audit X-02, deferred).
  static Future<String?> _sendFile(
    MessagingService messaging,
    String toHex,
    String path,
    String? name,
    List<String> roots,
  ) async {
    final NodeId peer;
    try {
      peer = NodeId.fromHex(toHex);
    } catch (_) {
      return 'invalid peer';
    }
    final opened = await veilOpenPinnedSource(path);
    if (opened.refusal != null) return opened.refusal;
    final source = opened.source!;
    final before = opened.stamp;
    try {
      final cid = await messaging.sendFileStreaming(
        peer,
        name?.isNotEmpty == true ? name! : File(path).uri.pathSegments.last,
        source.size,
        source.read,
        close: source.close,
        sourcePath: File(path).absolute.path,
        sourceRoots: roots,
      );
      if (cid == null) return 'peer not accepted';
      final after = await veilSourceStamp(path);
      if (before != null && after != null && before != after) {
        return 'source changed while it was being read; the offer may not '
            'describe the file you named';
      }
      return null;
    } catch (e) {
      return '$e';
    }
  }

  static String _mintId() => mintShortId();

  /// Order-sensitive list equality. Hand-rolled because `listEquals` lives in
  /// `package:flutter/foundation.dart`, and this file must stay importable
  /// from the Flutter-free headless entrypoint.
  static bool _sameRoots(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _constantTimeEqual(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static DynamicLibrary _veilNativeHandle() {
    for (final path in nativeLibCandidates(
      'veilclient_ffi',
      envVar: 'VEIL_FFI_DYLIB',
      devSubdir: 'third_party/veil/target/debug',
    )) {
      final file = File(path);
      if (!file.existsSync()) continue;
      return DynamicLibrary.open(file.absolute.path);
    }
    return processLibFor('veilclient_ffi');
  }

  /// Shut everything down, one leg at a time, none of them able to skip the
  /// rest.
  ///
  /// This used to be a straight `await` chain behind a `_closed` flag set on
  /// entry. One throwing leg — an FFI stop on an already-freed handle, a
  /// socket that will not close — abandoned every leg after it, and `_closed`
  /// was already true so a retry returned immediately. The node kept its
  /// ports, the container kept its lock, and nothing would ever come back for
  /// them (audit XV-16).
  ///
  /// Order still matters, so this is sequential rather than parallel: the API
  /// stops accepting before the services it calls go away, and storage closes
  /// last because everything above it writes. What changed is that a failure
  /// no longer cancels the remainder.
  ///
  /// The first error is rethrown once the last leg has run, so a caller still
  /// learns that teardown was not clean — just not at the cost of the teardown.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final failure = await runCleanupLegs('headless', [
      ('api', api.stop),
      ('webhook', _webhook.close),
      ('node-status', () async => _nodeStatus?.cancel()),
      ('mailbox', () async => _mailbox?.dispose()),
      ('messaging', messaging.dispose),
      ('groups', groups.dispose),
      ('stack', stack.dispose),
      // Last, and the one that must run: it releases the container's exclusive
      // lock. A skipped `storage.close()` wedges the next unlock.
      ('storage', storage.close),
    ]);
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
  }
}
