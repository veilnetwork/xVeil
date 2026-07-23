import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../core/ids.dart';
import '../crypto/blake3.dart';
import '../data/node/embedded_node.dart' show BootstrapPeerCfg, EmbeddedNode;
import '../data/storage/file_store.dart' show kMaxStoredFileBytes;
import '../data/storage/storage.dart';
import '../data/transport/veil_transport.dart';
import '../data/transport/wire_envelope.dart';
import '../domain/call_signal.dart';
import '../domain/group_call.dart';
import '../domain/group_content.dart';
import '../domain/chat.dart';
import '../domain/chat_folder.dart';
import '../domain/inline_custom_emoji.dart';
import '../domain/content_manifest.dart';
import '../domain/content_transfer.dart';
import '../data/serve_source.dart';
import '../domain/event.dart';
import '../domain/file_download_policy.dart';
import '../domain/file_transfer.dart';
import '../domain/media_file_name.dart';
import '../domain/p2p_policy.dart';
import '../domain/space_recommendation.dart';
import '../domain/space_join_request.dart';
import 'mailbox_service.dart' show MailboxSink;
import 'sticker_message.dart';
import 'vnote_message.dart';
import 'voice_message.dart';
import 'package:xveil/core/log.dart';

part 'messaging_support.dart';
part 'messaging_local_chat.dart';
part 'messaging_conversation_admin.dart';
part 'messaging_attestation.dart';
part 'messaging_replication.dart';
part 'messaging_group_content.dart';
part 'messaging_contacts.dart';
part 'messaging_peer_sync.dart';
part 'messaging_mutations.dart';
part 'messaging_device_mirror.dart';
part 'messaging_outbox.dart';
part 'messaging_realtime_control.dart';
part 'messaging_mailbox_delivery.dart';
part 'messaging_message_delivery.dart';
part 'messaging_file_transfer.dart';
part 'messaging_content_availability.dart';
part 'messaging_download_resume.dart';
part 'messaging_content_serving.dart';
part 'messaging_content_fetching.dart';
part 'messaging_content_stream_lifecycle.dart';
part 'messaging_content_server.dart';
part 'messaging_content_pull.dart';
part 'messaging_content_publish.dart';
part 'messaging_content_receive.dart';
part 'messaging_inbound_dispatch.dart';

/// Wires the [VeilTransport] inbound stream into [Storage] and exposes a send
/// path. Persists every message, then signals [changes] so the read providers
/// refresh. Intentionally Riverpod-free (no Ref) — it owns a plain broadcast
/// stream, which keeps it testable and avoids invalidating providers from
/// async stream callbacks.
class MessagingService {
  MessagingService(
    this._transport,
    this._storage, {
    this._anonymous = false,
    DateTime Function()? now,
    Duration? contentReRequestInterval,
    Duration? contentPacing,
    int? contentServeBatch,
    bool? plainFileStream,
    Duration? streamPayloadIdleTimeout,
    Duration? streamRangeStallAbandon,
    Duration? streamRangeHedgeAfter,
    int? streamPullMaxAttempts,
    int? streamRangeParallelism,
    int? streamRangeTargetBytes,
    bool? streamRangeEnabled,
    Duration? streamOpenWriteGrace,
    Duration? streamRequestTimeout,
    Future<bool> Function(NodeId peer)? p2pStreamAllowed,
    Future<String?> Function(String path)? videoThumbMaker,
    Future<String?> Function(Uint8List bytes)? imageThumbMaker,
  }) : _now = now ?? DateTime.now,
       _contentReRequestInterval =
           contentReRequestInterval ?? const Duration(seconds: 20),
       _contentPacing = contentPacing ?? _configuredContentPacing(),
       _contentServeBatch = _clampContentServeBatch(
         contentServeBatch ?? _configuredContentServeBatch(),
       ),
       _plainFileStream = plainFileStream ?? _plainFileStreamDartDefine,
       _streamPayloadIdleTimeout =
           streamPayloadIdleTimeout ?? _configuredStreamPayloadIdleTimeout(),
       _streamRangeStallAbandon =
           streamRangeStallAbandon ?? _configuredStreamRangeStallAbandon(),
       _streamRangeHedgeAfter =
           streamRangeHedgeAfter ?? _configuredStreamRangeHedgeAfter(),
       _streamPullMaxAttempts =
           streamPullMaxAttempts ?? _defaultStreamPullMaxAttempts,
       _streamRangeParallelism = _clampStreamRangeParallelism(
         streamRangeParallelism ?? _defaultStreamRangeParallelism,
       ),
       _explicitRangeFanout =
           streamRangeParallelism != null ||
           _streamRangeParallelismDartDefine > 0,
       _streamRangeTargetBytes = _clampStreamRangeTargetBytes(
         streamRangeTargetBytes ?? _defaultStreamRangeTargetBytes,
       ),
       _streamRangeEnabled =
           streamRangeEnabled ?? _streamRangeEnabledDartDefine,
       _streamOpenWriteGrace =
           streamOpenWriteGrace ?? _configuredStreamOpenWriteGrace(),
       _streamRequestTimeout =
           streamRequestTimeout ?? _configuredStreamRequestTimeout(),
       _p2pStreamsEnabled = p2pStreamAllowed != null,
       _p2pStreamAllowed = p2pStreamAllowed ?? _denyP2PStream,
       _videoThumbMaker = videoThumbMaker ?? _noVideoThumb,
       _imageThumbMaker = imageThumbMaker ?? _noImageThumb;

  /// Wall-clock source, injectable so stale-transfer eviction is testable
  /// without real delays. Defaults to [DateTime.now].
  final DateTime Function() _now;

  final VeilTransport _transport;
  final Storage _storage;
  final bool _p2pStreamsEnabled;
  final Future<bool> Function(NodeId peer) _p2pStreamAllowed;
  final Future<String?> Function(String path) _videoThumbMaker;
  final Future<String?> Function(Uint8List bytes) _imageThumbMaker;

  late final _MessagingConversationAdmin _conversationAdmin =
      _MessagingConversationAdmin(this);
  late final _MessagingAttestation _attestation = _MessagingAttestation(this);
  late final _MessagingReplication _replication = _MessagingReplication(this);
  late final _MessagingGroupContent _groupContent = _MessagingGroupContent(
    this,
  );
  late final _MessagingContacts _contacts = _MessagingContacts(this);
  late final _MessagingPeerSync _peerSync = _MessagingPeerSync(this);
  late final _MessagingMutations _mutations = _MessagingMutations(this);
  late final _MessagingDeviceMirror _deviceMirror = _MessagingDeviceMirror(
    this,
  );
  late final _MessagingOutbox _outbox = _MessagingOutbox(this);
  late final _MessagingRealtimeControl _realtimeControl =
      _MessagingRealtimeControl(this);
  final _MessagingMailboxDelivery _mailboxDelivery =
      _MessagingMailboxDelivery();
  late final _MessagingMessageDelivery _messageDelivery =
      _MessagingMessageDelivery(this);
  late final _MessagingFileTransfer _fileTransfer = _MessagingFileTransfer(
    this,
  );
  late final _MessagingContentAvailability _contentAvailability =
      _MessagingContentAvailability(this);
  late final _MessagingDownloadResume _downloadResume =
      _MessagingDownloadResume(this);
  late final _MessagingContentServing _contentServing =
      _MessagingContentServing(this);
  late final _MessagingContentFetching _contentFetching =
      _MessagingContentFetching(this);
  final _MessagingContentStreamLifecycle _contentStreams =
      _MessagingContentStreamLifecycle();

  /// Whether this identity routes over the onion rendezvous (sender-location
  /// hidden). Fixed per identity at boot from its roster `anonymous` flag — an
  /// anonymous identity sends EVERYTHING (messages, acks, accepts, file frames)
  /// anonymously and never over clearnet, so no single frame leaks its network
  /// location. An undeliverable frame stays un-acked and is retried, never
  /// degraded to a clearnet send (see [VeilTransport.send]).
  final bool _anonymous;

  /// This identity's local anonymity posture (per-identity boot flag). The call
  /// negotiator reads it to choose the media path — see [CallSignal] and the
  /// design doc's transport matrix (anon → onion, mixed → relay, direct → P2P).
  bool get isAnonymousIdentity => _anonymous;

  /// Set by the call service to receive inbound [WireKind.callSignal] frames
  /// (offer/answer/reject/cancel/busy/end/renegotiate/transportInfo). Fires only
  /// for accepted contacts; a durable signal is already acked+deduped by the
  /// generic durable-frame gate before this runs. Null when no call service is
  /// attached — the signal is then dropped.
  void Function(NodeId peer, CallSignal signal)? get onCallSignal =>
      _realtimeControl.onCallSignal;

  set onCallSignal(void Function(NodeId peer, CallSignal signal)? callback) {
    _realtimeControl.onCallSignal = callback;
  }

  /// Attached by the P2P endpoint service: an inbound
  /// [WireKind.p2pEndpoints] direct-endpoint exchange ([bodyJson]) from an
  /// accepted [peer]. The service applies the LOCAL P2P policy before dialing
  /// anything or replying with its own endpoints — transport admission here
  /// only guarantees the sender is an accepted contact. Dropped when unset.
  void Function(NodeId peer, String bodyJson)? get onP2PEndpoints =>
      _realtimeControl.onP2PEndpoints;

  set onP2PEndpoints(void Function(NodeId peer, String bodyJson)? callback) {
    _realtimeControl.onP2PEndpoints = callback;
  }

  /// Attached by the group layer: an inbound group snapshot ([bundleJson]) from
  /// an accepted [peer], to ingest idempotently. Dropped when unset.
  void Function(NodeId peer, String bundleJson)? onGroupEntry;

  /// Consent-first Space lifecycle frames. Both are delivered only for an
  /// accepted contact; the Space layer validates sender/target/id and persists
  /// the proposal or applies the decision.
  Future<void> Function(NodeId peer, String inviteJson)? onSpaceInvite;
  Future<void> Function(NodeId peer, String decisionJson)?
  onSpaceInviteDecision;

  /// Capability-bound public Space join frames may cross the contact boundary.
  /// The callbacks return true only after the Space layer has validated and
  /// durably persisted the exact ticket/request, which is the ACK gate.
  Future<bool> Function(NodeId peer, String requestJson)? onSpaceJoinRequest;
  Future<bool> Function(NodeId peer, String decisionJson)? onSpaceJoinDecision;
  Future<bool> Function(NodeId peer, String appealJson)?
  onSpaceModerationAppeal;
  Future<bool> Function(NodeId peer, String decisionJson)?
  onSpaceModerationAppealDecision;

  /// Space-layer admission for a recommendation card. Contact consent and the
  /// receiver-wide opt-out are enforced here; this callback additionally
  /// suppresses cards for a Space already held/joined by the recipient.
  Future<bool> Function(NodeId peer, SpaceRecommendationCard card)?
  onSpaceRecommendation;

  /// Attached by shared-document replication. Both whole and reassembled
  /// frames reach this callback only from accepted contacts; the document
  /// layer then verifies root/control signatures and membership epochs. True
  /// means terminal (applied OR permanently rejected) and permits ACK. False
  /// means local persistence was unavailable, so the durable sender must retry.
  Future<bool> Function(NodeId peer, String frameJson)? onCloudDocumentFrame;

  /// Attached by the group layer: an inbound signed content-fetch request
  /// (groups content path). NOT contact-gated — the signed membership proof
  /// inside IS the authorization, judged by the group layer (silent drop when
  /// unauthorized or unset).
  void Function(NodeId peer, String requestJson)? onGroupContentRequest;

  /// A live-only completion receipt for an earlier signed group content
  /// request. The group layer matches it to bounded RAM state and silently
  /// drops invalid/non-member sources; no ACK or durable record is created.
  void Function(NodeId peer, String receiptJson)? onGroupContentReceipt;

  /// Fired only after a membership-scoped blob is fully hash-verified and
  /// durably stored. [sources] contains the actual stream sources that supplied
  /// verified bytes, not every member that was merely eligible.
  Future<void> Function(String contentId, Set<NodeId> sources)?
  onGroupContentVerifiedSources;

  /// Receives ordinary local 1:1 writes for projection to this identity's
  /// other devices. Mirrored writes never re-fire it.
  void Function(NodeId peer, Message stored)? get onMessageStored =>
      _deviceMirror.onMessageStored;

  set onMessageStored(void Function(NodeId peer, Message stored)? callback) {
    _deviceMirror.onMessageStored = callback;
  }

  /// Idempotently project a message received from another local device.
  Future<bool> applyMirroredMessage({
    required NodeId peer,
    required String msgId,
    required MessageDirection direction,
    required String body,
    required int tsMs,
    String? fileContentId,
    String? fileName,
    int? fileSize,
    String? thumb,
    List<InlineCustomEmoji> customEmoji = const [],
  }) => _deviceMirror.applyMessage(
    peer: peer,
    msgId: msgId,
    direction: direction,
    body: body,
    tsMs: tsMs,
    fileContentId: fileContentId,
    fileName: fileName,
    fileSize: fileSize,
    thumb: thumb,
    customEmoji: customEmoji,
  );

  /// Optional authenticated content source supplied by another local device.
  Future<void> Function(String contentId)? get deviceContentPull =>
      _deviceMirror.deviceContentPull;

  set deviceContentPull(Future<void> Function(String contentId)? callback) {
    _deviceMirror.deviceContentPull = callback;
  }

  /// Receives local sync-worthy contact preference changes.
  void Function(Contact updated)? get onContactPrefsChanged =>
      _deviceMirror.onContactPrefsChanged;

  set onContactPrefsChanged(void Function(Contact updated)? callback) {
    _deviceMirror.onContactPrefsChanged = callback;
  }

  Future<void> _putContactPrefs(Contact contact) =>
      _deviceMirror.putContactPrefs(contact);

  /// Merge mirrored preferences while retaining local relationship/P2P state.
  Future<bool> applyMirroredContact({
    required NodeId peer,
    String? name,
    int? mutedUntilMs,
    NotificationMuteMode notificationMuteMode = NotificationMuteMode.none,
    required bool pinned,
    required bool archived,
    int? retentionDays,
    required bool allowPeerDelete,
  }) => _deviceMirror.applyContact(
    peer: peer,
    name: name,
    mutedUntilMs: mutedUntilMs,
    notificationMuteMode: notificationMuteMode,
    pinned: pinned,
    archived: archived,
    retentionDays: retentionDays,
    allowPeerDelete: allowPeerDelete,
  );

  /// Attached by the group layer: a group snapshot from a NON-contact sender
  /// (scale-free log sync — members need no pairwise contact handshake). The
  /// group layer admits it ONLY into groups it already holds where the sender
  /// is a current member; new-group materialization (an invite) stays
  /// contact-gated. Dropped when unset.
  void Function(NodeId peer, String bundleJson)? onGroupEntryFromStranger;

  /// Asks the group layer whether NON-contact [peer] may sync the group —
  /// the chunk-path admission, checked BEFORE reassembly RAM is spent.
  Future<bool> Function(NodeId peer, String gidHex)? allowStrangerGroupSync;

  /// Epoch-encrypted group-call frame. Deliberately not contact-gated: the
  /// group layer authenticates the sender, current membership, epoch, AEAD,
  /// signature, replay id and TTL before emitting anything to the call FSM.
  Future<bool> Function(NodeId peer, String frameJson)? onGroupCallSignal;

  /// Ship a signed group content-fetch request to [dst] (the content holder)
  /// durably. The group id in the frame key lets the outbox re-drive to a pure
  /// co-member without opening a general stranger-send gate. Live delivery is
  /// detached after persistence so one offline candidate cannot serialize the
  /// request fanout ahead of reachable seeders. Non-contact holders never ACK
  /// this frame (no membership/read oracle); it retires at the signed request's
  /// own ten-minute freshness deadline.
  Future<void> sendGroupContentRequest(NodeId dst, String requestJson) =>
      _groupContent.sendGroupContentRequest(dst, requestJson);

  /// Live-only counterpart to [sendGroupContentRequest]. It intentionally has
  /// no outbox/mailbox fallback and receives no delivery ACK.
  Future<void> sendGroupContentReceipt(NodeId dst, String receiptJson) =>
      _groupContent.sendGroupContentReceipt(dst, receiptJson);

  /// Send one already-signed+epoch-encrypted group-call signal. Lifecycle
  /// transitions are durable for short outage tolerance; heartbeats are live
  /// only so stale liveness work never accumulates in an outbox/mailbox.
  Future<void> sendGroupCallSignal(
    NodeId dst,
    GroupCallSignal signal,
    String frameJson,
  ) => _realtimeControl.sendGroupCallSignal(dst, signal, frameJson);

  /// Allow [peer] to pull membership-authorized group content [cid].
  void grantGroupContentServe(
    NodeId peer,
    String cid, {
    Duration ttl = const Duration(minutes: 10),
  }) => _groupContent.grantGroupContentServe(peer, cid, ttl: ttl);

  bool _groupServeGranted(NodeId peer, String cid) =>
      _groupContent.groupServeGranted(peer, cid);

  void _allowGroupPullSources(
    String cid,
    Iterable<NodeId> peers, {
    Duration ttl = const Duration(minutes: 10),
  }) => _groupContent.allowGroupPullSources(cid, peers, ttl: ttl);

  bool _groupPullSourceAllowed(NodeId peer, String cid) =>
      _groupContent.groupPullSourceAllowed(peer, cid);

  void _clearGroupPullSources(String cid) =>
      _groupContent.clearGroupPullSources(cid);

  Future<String> registerGroupContent(
    Uint8List bytes, {
    required String name,
  }) => _groupContent.registerGroupContent(bytes, name: name);

  Future<String> registerGroupContentStreaming(
    String name,
    int size,
    Future<Uint8List> Function(int offset, int length) read, {
    required Future<void> Function() close,
    String? sourcePath,
  }) => _groupContent.registerGroupContentStreaming(
    name,
    size,
    read,
    close: close,
    sourcePath: sourcePath,
  );

  /// Verified original source for media this identity registered by path.
  /// The content layer re-hashes before exposing it so a changed file cannot
  /// masquerade as the immutable signed content id.
  Future<String?> verifiedGroupContentSourcePath(String contentId) =>
      _groupContent.verifiedSourcePath(contentId);

  List<Map<String, Object>> debugGroupServeGrants() =>
      _groupContent.debugGroupServeGrants();

  /// Ship a group snapshot to [dst] durably, chunking oversized bundles.
  Future<void> sendGroupSnapshot(
    NodeId dst,
    String groupIdHex,
    String bundleJson,
  ) => _replication.sendGroupSnapshot(dst, groupIdHex, bundleJson);

  Future<void> sendSpaceInvite(
    NodeId dst,
    String inviteId,
    String inviteJson,
  ) => sendDurable(
    dst,
    'space-invite:$inviteId',
    WireEnvelope.spaceInvite(inviteJson),
  );

  Future<void> sendSpaceInviteDecision(
    NodeId dst,
    String inviteId,
    String decisionJson,
  ) => sendDurable(
    dst,
    'space-invite-decision:$inviteId',
    WireEnvelope.spaceInviteDecision(decisionJson),
  );

  Future<void> sendSpaceJoinRequest(
    NodeId dst,
    String requestId,
    String requestJson,
  ) => sendDurable(
    dst,
    'space-join-request:$requestId',
    WireEnvelope.spaceJoinRequest(requestJson),
  );

  Future<void> sendSpaceJoinDecision(
    NodeId dst,
    String requestId,
    String decisionJson,
  ) => sendDurable(
    dst,
    'space-join-decision:$requestId',
    WireEnvelope.spaceJoinDecision(decisionJson),
  );

  Future<void> sendSpaceModerationAppeal(
    NodeId dst,
    String appealId,
    String appealJson,
  ) => sendDurable(
    dst,
    'space-moderation-appeal:$appealId',
    WireEnvelope.spaceModerationAppeal(appealJson),
  );

  Future<void> sendSpaceModerationAppealDecision(
    NodeId dst,
    String appealId,
    String decisionJson,
  ) => sendDurable(
    dst,
    'space-moderation-appeal-decision:$appealId',
    WireEnvelope.spaceModerationAppealDecision(decisionJson),
  );

  /// Ship a shared-document invite/snapshot/delta durably.
  Future<void> sendCloudDocumentFrame(
    NodeId dst,
    String documentIdHex,
    String frameJson,
  ) => _replication.sendCloudDocumentFrame(dst, documentIdHex, frameJson);

  Future<void> _ingestStrangerGroupChunk(NodeId src, String body) =>
      _replication.ingestStrangerGroupChunk(src, body);

  void _ingestGroupChunk(
    NodeId src,
    String body, {
    bool fromStranger = false,
  }) => _replication.ingestGroupChunk(src, body, fromStranger: fromStranger);

  Future<void> _ingestCloudDocumentChunk(
    InboundMessage message,
    String body,
    String? frameId,
  ) => _replication.ingestCloudDocumentChunk(message, body, frameId);

  Future<bool> _deliverCloudDocumentFrame(NodeId peer, String frameJson) =>
      _replication.deliverCloudDocumentFrame(peer, frameJson);

  Future<void> _ackTerminalDocumentFrame(
    InboundMessage message,
    String? frameId,
  ) => _replication.ackTerminalDocumentFrame(message, frameId);

  /// Single egress point so every outbound frame honours [_anonymous]. The real
  /// transport routes over an onion circuit when anonymous (and never falls back
  /// to clearnet); the loopback fake ignores the flag.
  /// Live-send [payload] to [dst]. [wantReply] (only meaningful when anonymous)
  /// attaches a one-time reply block so the recipient can ACK over THIS send's
  /// circuit (surfacing as a non-zero [InboundMessage.replyId]) instead of doing
  /// a full resolve + circuit-build of its own — used for chat messages so the
  /// delivery-ACK round-trip is ~halved. Anonymity is unchanged (one-shot block,
  /// not a reused circuit).
  Future<void> _send(NodeId dst, Uint8List payload, {bool wantReply = false}) {
    devLog(
      () =>
          'xVeil[send]: live send dst=${dst.short} anonymous=$_anonymous '
          'wantReply=$wantReply bytes=${payload.length} '
          'transport=${_transport.runtimeType}',
    );
    if (_anonymous && wantReply) {
      return _transport.sendWithReply(dst, payload);
    }
    return _transport.send(dst, payload, anonymous: _anonymous);
  }

  /// Send a delivery ACK for [id] back to the sender of inbound [m]. When [m]
  /// carried a one-time reply path ([InboundMessage.replyId] != 0, set because
  /// the sender used `wantReply`), route the ACK over it — no fresh resolve +
  /// circuit-build — which is the latency win that flips the sender's message to
  /// "delivered" fast. Falls back to a normal anonymous send otherwise.
  ///
  /// [direct] forces the reliable full anonymous send even when a reply path is
  /// available. We set it on RE-receipts of an already-seen message: a repeat
  /// means our previous (reply-path) ACK never reached the sender — the one-time
  /// reply circuit can silently die on a NAT'd/mobile peer — so the second time
  /// we ACK over the durable resolve+circuit path instead of looping forever on
  /// a dead reply path. First receipt → fast reply path; repeat → reliable path.
  Future<void> _ackTo(
    InboundMessage m,
    String id, {
    bool direct = false,
    bool repeat = false,
  }) async {
    final ack = WireEnvelope.ack(id).encode();
    final viaReply = !direct && m.replyId != 0;
    // [timeline] which ACK path we took (reply = fast one-time circuit; direct =
    // durable resolve+circuit). id + path enum only — no body/keys. A repeat
    // (re-delivery of an already-processed frame: sender re-drive, mailbox
    // replica fan-out landing across drain passes) is labeled `re-ack` so the
    // log reads as the EXPECTED duplicate it is, not as reprocessing.
    devLog(
      () =>
          'xVeil[timeline]: ${repeat ? 're-ack' : 'ack'} id=$id '
          'via=${viaReply ? 'reply' : 'direct'} '
          't=${DateTime.now().millisecondsSinceEpoch}',
    );
    if (viaReply) {
      // Fast path: ride the sender's one-time reply circuit. Lowest latency, but
      // the circuit can silently die on a NAT'd/mobile sender — covered by the
      // durable path below on any re-receipt.
      await _transport.sendReply(m.replyId, ack);
      return;
    }
    // Durable path. A live send reaches the sender ONLY over a direct session, so
    // a NAT'd/offline sender never sees the ack and re-sends the message forever
    // — the observed delivery "storm" (hundreds of duplicate INBOUNDs that the
    // receiver dedups but the sender keeps generating because nothing flips the
    // message to "delivered"). The MESSAGE itself reaches a NAT'd peer only
    // because it is DEPOSITED at their mailbox and pushed over rendezvous; the
    // ack was missing that leg. Deposit the ack at the sender's mailbox too so it
    // rides the same push. The mailbox-delivery subsystem dedups by id (at most
    // one deposit per message); fire-and-forget keeps the seal/PUT round-trip
    // off the receive path while the live send covers the online case.
    await _send(m.src, ack);
    _stashInBackground(m.src, 'ack:$id', ack);
  }

  final _changes = StreamController<void>.broadcast();
  // Genuinely-new incoming messages (post-dedup), for the notification layer.
  final _incoming = StreamController<IncomingNotice>.broadcast();
  StreamSubscription<InboundMessage>? _sub;
  StreamSubscription<InboundMessage>? _realtimeSub;
  Timer? _retryTimer;

  /// The one-shot post-unlock settings-GC delay — cancellable so dispose()
  /// (provider teardown, widget tests) retracts it; see [start].
  Timer? _settingsGcTimer;
  bool _flushing = false;

  bool get backgroundStashPaused => _mailboxDelivery.paused;

  set backgroundStashPaused(bool value) {
    _mailboxDelivery.paused = value;
  }

  /// Attach the offline-delivery [MailboxService] after construction (it is
  /// built with [deliverInbound] as its drain sink, so it must exist first).
  void attachMailbox(MailboxSink mailbox) => _mailboxDelivery.attach(mailbox);

  /// The app just returned to the foreground: the user is looking at the
  /// screen, so anything parked at the mailbox relay should surface NOW, not on
  /// the idle back-off (which can be minutes deep after a long background
  /// stint). One debounced drain + a short burst window; a no-op when locked.
  void onAppResumed() => _mailboxDelivery.nudgeDrain();

  /// Route a message recovered from our mailbox through the normal inbound
  /// path — it is a `WireEnvelope`, so [_dispatch] decodes it, applies the
  /// consent gate, stores it, acks, and dedups by id against any live delivery.
  Future<void> deliverInbound(InboundMessage m) => _onInbound(m);

  /// Emits whenever stored conversations/messages change.
  Stream<void> get changes => _changes.stream;

  /// Fires once per genuinely-new incoming message (after the consent gate +
  /// dedup), so the notification layer can alert without re-alerting on a
  /// re-delivery. The active identity's service is the one observed.
  Stream<IncomingNotice> get incoming => _incoming.stream;

  void start() {
    // LIVE transport frames only (the mailbox drain feeds [deliverInbound]
    // directly, not this). A frame from a peer proves it is reachable NOW, so
    // nudge the mailbox to drain promptly: on the desktop→phone path the live
    // rendezvous introduce is often dropped (cookie_unknown) while the sender's
    // other live frames (acks / sync beacons) still land — without the nudge the
    // stashed message surfaces only on the next idle drain (~30 s measured);
    // with it, within the debounce window. Debounced + no-op without a mailbox.
    void receive(InboundMessage m) {
      _mailboxDelivery.nudgeDrain();
      _onInbound(m);
    }

    _sub ??= _transport.messages().listen(receive);
    final transport = _transport;
    if (_realtimeSub == null && transport is RealtimeInboundTransport) {
      _realtimeSub = (transport as RealtimeInboundTransport)
          .realtimeMessages()
          .listen((message) {
            _mailboxDelivery.nudgeDrain();
            _onRealtimeInbound(message);
          });
    }
    _retryTimer ??= Timer.periodic(
      _messageDelivery.retryInterval,
      (_) => _retryFlush(),
    );
    unawaited(_loadFilePolicy()); // this identity's auto-download policy (A1)
    // Serve inbound bulk file streams (S2). The transport-scoped broker keeps
    // exactly one native accept loop across synchronous identity/service
    // replacements, so a disposed service cannot steal the replacement's first
    // stream while its old 2-second accept is still parked.
    if (transport is StreamTransport) {
      final streamTransport = transport as StreamTransport;
      _contentStreams.attach(
        streamTransport,
        acceptP2P: _p2pStreamsEnabled && transport is P2PStreamTransport,
        onAnonymous: _acceptAnonymousContentStream,
        onP2P: _acceptP2PContentStream,
      );
    }
    // Re-drive downloads that were interrupted before the last shutdown.
    unawaited(_startDownloadResumer());
    // Settings-namespace GC, once per unlock and off the hot path: aged stores
    // accumulate per-content bookkeeping keys (legacy msgidx:*, saved:<cid>
    // for messages long deleted) until the namespace's B+ index budget is
    // exhausted and EVERY new file-piece persist dies with
    // HvException.IndexFull — device-observed as downloads failing on a
    // storage that looks nearly empty. Delayed so unlock/scan latency is
    // untouched; failures are non-fatal (the next unlock retries). A
    // CANCELLABLE Timer, not Future.delayed: dispose() must be able to
    // retract the pending delay itself, or every widget test that touches the
    // service dies on "A Timer is still pending" at teardown (the _disposed
    // guard silences the callback but not the timer).
    _settingsGcTimer = Timer(const Duration(seconds: 20), () {
      unawaited(() async {
        if (_disposed) return;
        try {
          final swept = await _storage.sweepSettingsGarbage();
          if (swept > 0) {
            devLog(() => 'xVeil[storage]: settings GC swept $swept dead keys');
          }
        } catch (e) {
          devLog(() => 'xVeil[storage]: settings GC failed: $e');
        }
      }());
    });
  }

  /// Set in [dispose]; stops the stream accept loop.
  bool _disposed = false;

  Future<void> _retryFlush() async {
    if (_flushing) return; // don't stack overlapping flushes
    _flushing = true;
    try {
      await flushOutbox();
    } catch (_) {
      // Transport hiccup — the next tick retries.
    } finally {
      _flushing = false;
    }
  }

  void _nudgeRetries(String peerHex) => _messageDelivery.nudge(peerHex);

  /// Our node (re)connected — reconcile now. Clear the per-peer gap-fill throttle
  /// so the [WireKind.sync] beacon fires IMMEDIATELY for every peer (a reconnect
  /// is exactly when a peer may have missed our events while we were down), then
  /// flush the outbox (which sends the beacons + re-sends un-acked messages).
  Future<void> reconcileOnConnect() async {
    _peerSync.resetSession();
    _fileTransfer.resetSession();
    // A (re)connect is exactly when interrupted downloads become resumable
    // again — reset the failure backoff and probe each pending one.
    _downloadResume.reconcileOnConnect();
    await flushOutbox();
  }

  void _signal() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _emitIncoming(
    NodeId from,
    String preview, {
    required bool isFile,
    String? messageId,
  }) {
    if (!_incoming.isClosed) {
      _incoming.add(
        IncomingNotice(
          from: from,
          preview: preview,
          isFile: isFile,
          messageId: messageId,
        ),
      );
    }
  }

  /// Persist a message and return its id. [id] lets the receiver reuse the
  /// SENDER's id (so re-sends dedup) instead of minting a fresh one.
  /// Our own node-id hex, cached after the first resolve — the event-log author
  /// of every OUTGOING message (R1). The transport exposes it only async, so we
  /// memoise it rather than awaiting a round-trip on every store.
  String? _selfHexCache;
  Future<String> _selfHex() async =>
      _selfHexCache ??= (await _transport.nodeId()).hex;

  // Local-only chat features live in a separate collaborator. Keeping the
  // public methods here preserves MessagingService's API while the collaborator
  // reuses this class's canonical _store/event-log path.
  _MessagingLocalChat? _localChatController;
  _MessagingLocalChat get _localChat =>
      _localChatController ??= _MessagingLocalChat(this);

  Future<Map<String, Map<String, String>>> loadReactions(String convId) =>
      _localChat.loadReactions(convId);

  Future<void> _applyReaction(
    String convId,
    String msgId,
    String reactorHex,
    String emoji,
  ) => _localChat.applyReaction(convId, msgId, reactorHex, emoji);

  Future<void> sendReaction(NodeId peer, String msgId, String emoji) =>
      _localChat.sendReaction(peer, msgId, emoji);

  Future<String> savedSelfHex() => _selfHex();

  Future<void> saveNote(
    String text, {
    String? replyToId,
    String? forwardedFrom,
    List<InlineCustomEmoji> customEmoji = const [],
  }) => _localChat.saveNote(
    text,
    replyToId: replyToId,
    forwardedFrom: forwardedFrom,
    customEmoji: customEmoji,
  );

  Future<void> saveFileNote(
    Uint8List bytes,
    String name, {
    String? sourcePath,
    String? forwardedFrom,
  }) => _localChat.saveFileNote(
    bytes,
    name,
    sourcePath: sourcePath,
    forwardedFrom: forwardedFrom,
  );

  Future<bool> saveFileNoteRef(Message m, {String? forwardedFrom}) =>
      _localChat.saveFileNoteRef(m, forwardedFrom: forwardedFrom);

  Future<Message> _store(
    NodeId peer,
    MessageDirection dir,
    String body,
    MessageStatus status, {
    String? fileId,
    String? fileName,
    int? fileSize,
    String? fileContentId,
    String? thumb,
    List<InlineCustomEmoji> customEmoji = const [],
    String? id,
    DateTime? timestamp,
    int? seq,
    String? replyToId,
    String? forwardedFrom,
    // LOCAL system annotations (the chatDeleted marker): author under OUR OWN
    // event stream even though the row renders as incoming. Attributing it to
    // the peer would make [appendMessage] allocate the next GAP-FREE seq in
    // the PEER's stream — which fills an old gap and sorts the marker into
    // the MIDDLE of the chat (caught in device-verify: idx 21/66 twice).
    bool selfAuthored = false,
  }) async {
    final msgId = id ?? _uuid.v4();
    final stored = await _storage.appendMessage(
      Message(
        id: msgId,
        conversationId: peer.hex,
        direction: dir,
        replyToId: replyToId,
        forwardedFrom: forwardedFrom,
        thumb: thumb,
        customEmoji: customEmoji,
        body: body,
        // Incoming messages carry the SENDER's send time (env.sentAtMs) so the
        // conversation orders by send-order, not the scrambled arrival order.
        timestamp: timestamp ?? DateTime.now(),
        status: status,
        fileId: fileId,
        fileName: fileName,
        fileSize: fileSize,
        fileContentId: fileContentId,
        // Event-log author (R1): the message originator's node id, bound to the
        // AUTHENTICATED side — our own for an outgoing message, the peer (the
        // server-authenticated conversation id) for an incoming one. Never
        // inferred from an in-band wire field.
        author: selfAuthored || dir == MessageDirection.outgoing
            ? await _selfHex()
            : peer.hex,
        // The SENDER's seq when this is a wire-delivered incoming event (keeps
        // the log convergent, R4); null for our own outgoing message → storage
        // allocates the next gap-free value, which the caller puts on the wire.
        seq: seq,
      ),
    );
    // Multi-device mirror tap: after the single write path persists a 1:1 row,
    // let the device-sync bridge mirror it to my other devices. [_store] is the
    // one messaging write path; applyMirroredMessage bypasses it, so a mirrored
    // row never re-mirrors.
    onMessageStored?.call(peer, stored);
    return stored;
  }

  /// The sender's send time off the wire as a DateTime, or null (older sender
  /// without `sentAtMs` → caller falls back to receive time).
  ///
  /// Stored VERBATIM (no receiver-side clamp) so it is byte-identical on both
  /// devices — the basis for the convergent (effective_ts, author, seq) display
  /// order. The old future-clamp made the value receiver-dependent (it used the
  /// receiver's local now), which silently diverged the cross-author interleave
  /// across devices. It also never addressed the real skew concern (R9: a peer
  /// stamping ts=0 to float ABOVE my messages) — that is handled deterministically
  /// by the author-monotone effective_ts FLOOR in loadMessages. A future-stamped
  /// message now simply sorts to the bottom (convergently) on both devices — and
  /// since the floor carries that author's later messages down with it, a fast
  /// clock only buries the SENDER's own stream, never floats it above others.
  DateTime? _wireSentAt(WireEnvelope env) => _wireSentAtMs(env.sentAtMs);

  /// [DateTime] for a wire send-time in ms (the file-meta path has no envelope).
  DateTime? _wireSentAtMs(int? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);

  Future<bool> _hasMessage(NodeId peer, String id) =>
      _mutations.hasMessage(peer, id);

  /// Fires after a local relationship transition, never after a mirrored one.
  void Function(NodeId peer, ContactStatus status)? onContactStatusChanged;

  Future<void> _setStatus(NodeId peer, ContactStatus status) =>
      _contacts.setStatus(peer, status);

  Future<bool> applyMirroredContactStatus(NodeId peer, ContactStatus status) =>
      _contacts.applyMirroredContactStatus(peer, status);

  Future<void> _handleRequestOrReconnect(
    InboundMessage message,
    WireEnvelope envelope,
    ContactStatus? status,
  ) => _contacts.handleRequestOrReconnect(message, envelope, status);

  /// Serializes inbound handling. The stream listener ([start]) does NOT await
  /// our async handler, and [deliverInbound] (mailbox drain) feeds the SAME
  /// path, so without this two frames interleave at their `await` points. That
  /// let concurrent pre-consent intros each read the stored count below the cap
  /// in [_capPreConsentIntros] and both store — busting [kMaxPreConsentIntros]
  /// (an unbounded-greeting hole on a victim's device) — and more generally
  /// raced the consent gate / id-dedup check-then-act sequences. We process at
  /// most one frame at a time. [_handleInbound] is fully try/catch-guarded so
  /// the chained future never rejects and the queue can't be poisoned.
  Future<void> _inboundChain = Future<void>.value();

  Future<void> _onInbound(InboundMessage m) {
    final next = _inboundChain.then((_) => _handleInbound(m));
    _inboundChain = next;
    return next;
  }

  Future<void> _onRealtimeInbound(InboundMessage message) =>
      _realtimeControl.deliverInbound(message);

  Future<void> _handleInbound(InboundMessage m) async {
    devLog(
      () =>
          'xVeil[recv]: INBOUND from=${m.src.short} bytes=${m.payload.length}',
    );
    // The peer answered SOMETHING — return its sync beacon to base cadence.
    _peerSync.noteInbound(m.src);
    _nudgeRetries(m.src.hex);
    // ...and revive any parked downloads that list it as a holder.
    noteInboundFromPeer(m.src);
    try {
      await _dispatch(m);
    } catch (e) {
      // A hostile or corrupt datagram (malformed JSON, missing/ill-typed
      // fields, bad base64) must never throw out of the stream listener and
      // disrupt delivery for everyone else — drop it silently. LOG it so a
      // legit message that fails to parse/store isn't invisibly dropped.
      devLog(() => 'xVeil[recv]: dispatch FAILED from=${m.src.short}: $e');
    }
  }

  Future<void> _ackFrame(InboundMessage message, String frameId) =>
      _outbox.ackFrame(message, frameId);

  /// Send [env] to [peer] durably under [frameId] (see the section comment). The
  /// receiver echoes [frameId] in its ack to retire the frame.
  Future<void> sendDurable(
    NodeId peer,
    String frameId,
    WireEnvelope envelope, {
    Future<void> Function(Uint8List wire)? liveSender,
    bool awaitLive = true,
    bool startLiveBeforeEnqueue = false,
  }) => _outbox.send(
    peer,
    frameId,
    envelope,
    liveSender: liveSender,
    awaitLive: awaitLive,
    startLiveBeforeEnqueue: startLiveBeforeEnqueue,
  );

  /// Send a call control-plane [signal] to [peer]. Ring/accept/reject/cancel/
  /// busy/end/renegotiate go via the durable pipeline — keyed `call:<id>:<type>`
  /// so a dropped frame re-drives and a re-delivery is acked+processed once.
  /// [CallSignalType.health] is the sole best-effort signal: the next heartbeat
  /// supersedes it. A P2P→relay [CallSignalType.transportInfo] transition is
  /// durable because losing it can leave the peers on different media routes;
  /// stale re-delivery after call end is harmlessly ignored by the call-id FSM.
  Future<void> sendCallSignal(NodeId peer, CallSignal signal) =>
      _realtimeControl.sendCallSignal(peer, signal);

  /// Share this device's direct dial endpoints with an accepted contact (P2P
  /// epic). [bodyJson] is the [WireKind.p2pEndpoints] payload built by the
  /// endpoint service, which ALSO enforces the P2P policy before calling this —
  /// here we only re-assert the contact gate. Durable with a live leg, keyed by
  /// [sentAtMs] so a refreshed endpoint set is a NEW frame (the old one may
  /// still be un-acked in the outbox); the receiver treats each frame
  /// idempotently and stale addresses simply fail to dial.
  Future<void> sendP2PEndpoints(
    NodeId peer,
    String bodyJson, {
    required int sentAtMs,
  }) => _realtimeControl.sendP2PEndpoints(peer, bodyJson, sentAtMs: sentAtMs);

  /// Re-drive un-acked durable frames: re-deposit at the mailbox (idempotent via
  /// the stash dedup) and, backed off per frame, re-send live. Called from
  /// [flushOutbox].
  Future<void> _flushOutboxFrames() => _outbox.flush();

  /// A non-contact may ACK only the exact pending group-call frame addressed to
  /// it while it is still a current member of that gid. This is narrower than
  /// the ordinary accepted-contact ACK gate and cannot forge delivery of chat
  /// messages or frames belonging to another peer/group.
  Future<bool> _authorizedGroupCallAck(NodeId peer, String frameId) =>
      _outbox.authorizedGroupCallAck(peer, frameId);

  Future<bool> _authorizedExternalSpaceProposalAck(
    NodeId peer,
    String frameId,
  ) => _outbox.authorizedExternalSpaceProposalAck(peer, frameId);

  /// Locally retire a durable frame (acked, or moot): stop re-driving and
  /// re-stashing it, and drop it from the persistent outbox. [ackOutboxFrame]
  /// is a no-op for an id that is not in the outbox, so this is safe to call
  /// with an ordinary message id too.
  void _retireOutboxFrame(String frameId) => _outbox.retire(frameId);

  // ── Opt-in authorship attestation ─────────────────────────────────────────

  /// Author-side answer to incoming requests. Null means ask every time.
  SignaturePolicy Function()? signaturePolicyResolver;

  /// Prompts emitted under [SignaturePolicy.ask].
  Stream<SignatureAsk> get signatureAsks => _attestation.asks;

  Future<void> requestSignature(NodeId peer, String msgId, String body) =>
      _attestation.request(peer, msgId, body);

  Future<void> _onSignRequest(NodeId src, WireEnvelope envelope) =>
      _attestation.onRequest(src, envelope);

  Future<void> resolveSignatureAsk(SignatureAsk ask, {required bool approve}) =>
      _attestation.resolve(ask, approve: approve);

  Future<void> _onSignResponse(NodeId src, WireEnvelope envelope) =>
      _attestation.onResponse(src, envelope);

  /// Ask [dst] to connect, with an optional [greeting].
  Future<void> sendRequest(NodeId dst, String greeting) =>
      _contacts.sendRequest(dst, greeting);

  Future<void> resendRequest(NodeId dst) => _contacts.resendRequest(dst);

  Future<void> cancelRequest(NodeId peer) => _contacts.cancelRequest(peer);

  Future<void> acceptContact(NodeId peer) => _contacts.acceptContact(peer);

  Future<void> blockContact(NodeId peer) => _contacts.blockContact(peer);

  Future<void> unblockContact(NodeId peer) => _contacts.unblockContact(peer);

  // Local contact preferences, folders, read markers, and destructive chat
  // actions live in _MessagingConversationAdmin. These forwarding methods keep
  // MessagingService's established public API and callback ownership intact.

  Future<void> setContactName(NodeId peer, String? name) =>
      _conversationAdmin.setContactName(peer, name);

  Future<void> setContactMutedUntil(
    NodeId peer,
    DateTime? until, {
    NotificationMuteMode mode = NotificationMuteMode.none,
  }) => _conversationAdmin.setContactMutedUntil(peer, until, mode: mode);

  Future<void> setContactMuted(NodeId peer, bool muted) =>
      setContactMutedUntil(peer, muted ? kMuteForever : null);

  Future<void> setContactArchived(NodeId peer, bool archived) =>
      _conversationAdmin.setContactArchived(peer, archived);

  Future<void> setContactAllowPeerDelete(NodeId peer, bool allow) =>
      _conversationAdmin.setContactAllowPeerDelete(peer, allow);

  Future<void> setContactP2POverride(NodeId peer, ContactP2POverride value) =>
      _conversationAdmin.setContactP2POverride(peer, value);

  Future<void> setContactPinned(NodeId peer, bool pinned) =>
      _conversationAdmin.setContactPinned(peer, pinned);

  Future<void> setContactRetention(NodeId peer, int? days) =>
      _conversationAdmin.setContactRetention(peer, days);

  Future<void> pruneConversation(NodeId peer) =>
      _conversationAdmin.pruneConversation(peer);

  Future<void> deleteConversation(NodeId peer, {bool notifyPeer = false}) =>
      _conversationAdmin.deleteConversation(peer, notifyPeer: notifyPeer);

  Future<List<ChatFolder>> loadFolders() => _conversationAdmin.loadFolders();

  Future<ChatFolder> createFolder(
    String name, {
    List<String> members = const [],
  }) => _conversationAdmin.createFolder(name, members: members);

  Future<void> renameFolder(String folderId, String name) =>
      _conversationAdmin.renameFolder(folderId, name);

  Future<void> deleteFolder(String folderId) =>
      _conversationAdmin.deleteFolder(folderId);

  Future<void> setFolderMembership(
    String folderId,
    String peerHex,
    bool member,
  ) => _conversationAdmin.setFolderMembership(folderId, peerHex, member);

  Future<void> clearConversation(NodeId peer) =>
      _conversationAdmin.clearConversation(peer);

  /// Fires only after a local read marker advances, for device mirroring.
  void Function(String conversationId, int tsMs)? onConversationRead;

  Future<void> markRead(String conversationId) =>
      _conversationAdmin.markRead(conversationId);

  Future<bool> applyMirroredReadMark(String conversationId, int tsMs) =>
      _conversationAdmin.applyMirroredReadMark(conversationId, tsMs);
  Future<void> sendText(
    NodeId dst,
    String text, {
    String? replyToId,
    String? forwardedFrom,
    List<InlineCustomEmoji> customEmoji = const [],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (isSpaceRecommendationMessageBody(trimmed)) return;
    if (!isValidInlineCustomEmoji(trimmed, customEmoji)) return;
    // Consent gate — only free-message an accepted contact.
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) return;
    // One send time, used for BOTH our stored copy and the wire `sentAtMs`, so
    // both ends order this message identically. From the service clock ([_now])
    // so the per-message reconnect give-up age (and tests) share one timeline.
    final sentAt = _now();
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      trimmed,
      MessageStatus.sent,
      timestamp: sentAt,
      replyToId: replyToId,
      forwardedFrom: forwardedFrom,
      customEmoji: customEmoji,
    );
    final id = stored.id;
    _signal();
    // Stays `sent` until the peer acks; the local outbox re-sends un-acked ones
    // on reconnect, so a message written offline goes out when we come back. The
    // event seq travels so the peer folds it under OUR (author, seq) and can spot
    // a gap for gap-fill.
    final wire = WireEnvelope.message(
      trimmed,
      id: id,
      sentAtMs: sentAt.millisecondsSinceEpoch,
      seq: stored.seq,
      replyTo: replyToId,
      forwardedFrom: forwardedFrom,
      customEmoji: customEmoji,
    ).encode();
    // wantReply: embed a one-time reply path so the peer's delivery-ACK comes
    // back over THIS circuit (fast), flipping us to "delivered" without a full
    // resolve+circuit-build round-trip on their side.
    // [timeline] id + send-time only (random uuid + ms clock — no body/keys), so
    // receive-latency vs ACK-latency can be measured per message from the logs.
    devLog(
      () =>
          'xVeil[timeline]: send id=$id '
          't0=${sentAt.millisecondsSinceEpoch} wantReply=true',
    );
    // A user send opens the mailbox burst window: the reply usually comes back
    // as drained mail (the live introduce toward us may be down), so poll fast
    // for a bounded window instead of the idle back-off.
    _mailboxDelivery.noteActivity();
    await _send(dst, wire, wantReply: true);
    // Deposit at the peer's mailbox as a BACKGROUND fallback (don't await): the
    // seal+put is a slow onion round-trip, and blocking the send on it made every
    // message feel laggy even when the live path delivers instantly. If the peer
    // is offline the deposit (or the outbox retry) still gets there.
    _stashInBackground(dst, id, wire);
  }

  /// Send one recommendation card after the caller's explicit recipient
  /// selection. There is intentionally no bulk/broadcast primitive here.
  Future<String?> sendSpaceRecommendation(
    NodeId dst,
    SpaceRecommendationCard card,
  ) async {
    if (!card.isStructurallyValid) return null;
    try {
      final ticket = SpaceJoinCode.parse(card.joinCode);
      if (ticket.spaceId != card.spaceId ||
          ticket.isExpiredAt(_now().millisecondsSinceEpoch)) {
        return null;
      }
    } catch (_) {
      return null;
    }
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) {
      return null;
    }
    final sentAt = _now();
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      encodeSpaceRecommendationMessage(card),
      MessageStatus.sent,
      timestamp: sentAt,
    );
    _signal();
    final wire = WireEnvelope.spaceRecommendation(
      card,
      id: stored.id,
      sentAtMs: sentAt.millisecondsSinceEpoch,
      seq: stored.seq,
    ).encode();
    _mailboxDelivery.noteActivity();
    await _send(dst, wire, wantReply: true);
    _stashInBackground(dst, stored.id, wire);
    return stored.id;
  }

  static const _spaceRecommendationsEnabledSetting =
      'privacy.space_recommendations.enabled.v1';

  Future<SpaceRecommendationRecipientPolicy>
  spaceRecommendationRecipientPolicy() async {
    final raw = await _storage.getSetting(_spaceRecommendationsEnabledSetting);
    if (raw == null || raw.isEmpty || raw == 'true') {
      return const SpaceRecommendationRecipientPolicy();
    }
    if (raw == 'false') {
      return const SpaceRecommendationRecipientPolicy(
        mode: SpaceRecommendationRecipientMode.blockAll,
      );
    }
    try {
      return SpaceRecommendationRecipientPolicy.fromJson(jsonDecode(raw)) ??
          const SpaceRecommendationRecipientPolicy();
    } catch (_) {
      return const SpaceRecommendationRecipientPolicy();
    }
  }

  Future<bool> spaceRecommendationsEnabled() async =>
      (await spaceRecommendationRecipientPolicy()).acceptsCards;

  Future<void> setSpaceRecommendationRecipientPolicy(
    SpaceRecommendationRecipientPolicy policy,
  ) async {
    await _storage.putSetting(
      _spaceRecommendationsEnabledSetting,
      jsonEncode(policy.toJson()),
    );
    _signal();
  }

  Future<void> setSpaceRecommendationsEnabled(bool enabled) =>
      setSpaceRecommendationRecipientPolicy(
        SpaceRecommendationRecipientPolicy(
          mode: enabled
              ? SpaceRecommendationRecipientMode.acceptedContacts
              : SpaceRecommendationRecipientMode.blockAll,
        ),
      );

  /// Retract a typed recommendation from exactly one accepted conversation.
  Future<bool> revokeSpaceRecommendation(NodeId peer, String messageId) =>
      _mutations.revokeSpaceRecommendation(peer, messageId);

  /// Re-send every outgoing text message still awaiting a delivery ack (i.e.
  /// `sent`, not yet `delivered`) to accepted contacts. Driven on node-connect /
  /// app-start so messages composed while offline are delivered on reconnect;
  /// the receiver dedups by id, so re-sending an already-delivered one is safe.
  Future<void> flushOutbox() => _messageDelivery.flush();

  void _sendSyncBestEffort(NodeId peer, {bool force = false}) =>
      _peerSync.sendBestEffort(peer, force: force);

  Future<void> _handlePeerSync(NodeId peer, String body) =>
      _peerSync.handle(peer, body);

  /// Best-effort offline deposit of [wire] (the message envelope) for [peer],
  /// keyed by a stable 32-byte content id derived from the message [id]. No-op
  /// when there is no mailbox side-channel or we already stashed this message.
  void _stashInBackground(NodeId peer, String id, Uint8List wire) =>
      _mailboxDelivery.stashInBackground(peer, id, wire);

  Future<void> _maybeStash(NodeId peer, String id, Uint8List wire) =>
      _mailboxDelivery.maybeStash(peer, id, wire);

  /// Delete a local copy, scrub its plaintext, and stop unreferenced serving.
  Future<void> deleteMessageLocally(String messageId) =>
      _mutations.deleteLocally(messageId);

  /// Durably unsend one of our outgoing messages from both peers.
  Future<void> deleteForEveryone(String messageId) =>
      _mutations.deleteForEveryone(messageId);

  /// Edit one of our outgoing messages and durably propagate the new version.
  Future<void> editOwnMessage(
    String messageId,
    String newBody, {
    List<InlineCustomEmoji> customEmoji = const [],
  }) => _mutations.editOwnMessage(messageId, newBody, customEmoji: customEmoji);

  /// Send a file to [dst] (gated to accepted contacts). Stores a local copy,
  /// records an outgoing file message (filePost, on the seq stream), then streams
  /// the bytes as fileMeta + fileChunk envelopes — the meta carrying the file's
  /// event seq so the receiver folds it convergently and gap-fill can heal it.
  Future<void> sendFile(
    NodeId dst,
    Uint8List bytes,
    String name, {
    String? sourcePath,
  }) => _fileTransfer.send(dst, bytes, name, sourcePath: sourcePath);

  // ── Content layer: decentralized, hash-verified piece transfer (Stage 2) ────
  // Sender: advertise a manifest, then serve requested pieces as paced chunks.
  // Receiver: verify the manifest, request missing pieces, verify each piece on
  // arrival, reassemble + verify the WHOLE, then surface it. Order/loss-tolerant.

  /// Content we SERVE, by contentId — the MANIFEST plus, for a LARGE send, a live
  /// [source] over the user's ORIGINAL file. [_serveChunks] reads each requested
  /// chunk either from [source] (serve-from-source: no copy of the file is kept —
  /// the sender already HAS it, so storing one would just duplicate it, and for a
  /// big file that copy is what overflows the hidden-volume index) or, when
  /// [source] is null (small / in-RAM sends), from the on-disk blob store
  /// ([readFileRange]). Either way only a small manifest sits in RAM.
  /// [servedAt] is refreshed on every advertise/request so an ACTIVE transfer
  /// stays; an idle one is evicted by [_evictServing], which closes its [source].
  Map<String, _ServedContent> get _serving => _contentServing.entries;

  /// A long serve aborts if the receiver hasn't re-requested within this window
  /// (it refreshes [_serving] freshness on every request) — i.e. it abandoned the
  /// download. Comfortably above the receiver's re-request interval so an active
  /// transfer is never cut, but well under the idle [_servingTtl].
  static const _serveAbandonTimeout = Duration(seconds: 50);

  /// Active stream serves by content id. A same-content re-send may arrive while
  /// a large file is already being streamed; in that case we must not replace the
  /// live source/path underneath the running stream. This is especially important
  /// for Android file_picker cache paths, where a second pick of the same file can
  /// invalidate the previous temporary handle.
  Map<String, int> get _activeStreamServes => _contentServing.activeStreams;

  /// Re-opens a serve source for a persisted file path (DURABLE offers): on a
  /// reoffer request after our [_serving] entry is gone (restart / TTL), the
  /// sender re-opens the original file and re-serves. Injected because the
  /// dart:io open lives in the data layer (the service stays io-free). Null ⇒
  /// durable re-serve is off (tests / not wired) — a stale offer then needs a
  /// re-send. Returns null if the path can't be opened (file moved / SAF expired).
  Future<ServeSource?> Function(String path)? get sourceOpener =>
      _contentServing.sourceOpener;
  set sourceOpener(Future<ServeSource?> Function(String path)? value) {
    _contentServing.sourceOpener = value;
  }

  /// Test seam: how many files are currently cached for serving / being fetched
  /// (so a test can assert the RAM caches stay bounded by the eviction logic).
  int get servingCount => _contentServing.count;
  int get fetchingCount => _contentFetching.count;

  /// RAM-only handles for offered-but-not-yet-downloaded files. Full manifests
  /// and compact refs share one bounded registry in [_contentAvailability].
  Map<String, _ContentManifestOffer> get _offered =>
      _contentAvailability.offered;
  Map<String, _ContentManifestRefOffer> get _offeredRefs =>
      _contentAvailability.offeredRefs;

  /// Test seam for the combined full-manifest + compact-ref memory bound.
  int get offeredContentCount => _contentAvailability.offerCount;

  /// Per-identity auto-download policy (size cap + blocked types): which incoming
  /// files download silently vs. surface as an OFFER the user must accept — so a
  /// peer can't silently fill the disk or push an executable unbidden (Phase A1).
  /// Loaded from THIS identity's storage on [start]; the safe default applies
  /// until then (and for a fresh identity). Edited via [setFileDownloadPolicy].
  FileDownloadPolicy _filePolicy = FileDownloadPolicy.defaults;
  static const _kFilePolicySetting = 'file_policy';

  /// This identity's current incoming-file policy (read by the settings UI).
  FileDownloadPolicy get fileDownloadPolicy => _filePolicy;

  /// Apply + persist a new auto-download policy for THIS identity. Takes effect
  /// immediately (the next offer is judged against it) and survives restart.
  Future<void> setFileDownloadPolicy(FileDownloadPolicy policy) async {
    _filePolicy = policy;
    await _storage.putSetting(_kFilePolicySetting, jsonEncode(policy.toJson()));
  }

  /// Load this identity's stored policy (called from [start]); a missing or
  /// corrupt blob leaves the safe default in place.
  Future<void> _loadFilePolicy() async {
    try {
      final raw = await _storage.getSetting(_kFilePolicySetting);
      if (raw != null && raw.isNotEmpty) {
        _filePolicy = FileDownloadPolicy.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      // Unparseable / store hiccup → keep defaults (fail safe, not open).
    }
  }

  /// Fires when a content transfer COMPLETES (all pieces streamed to disk). No
  /// bytes — the blob is on disk under contentId; read it via loadFile /
  /// readFileRange rather than holding the whole file in RAM.
  /// [savedToPath] is set only for an unencrypted download-to-file completion —
  /// the plaintext file's path (so the UI can say where it landed); null for a
  /// normal store (encrypted tier / in-volume).
  final _contentReceived =
      StreamController<
        ({String contentId, String name, String? savedToPath})
      >.broadcast();
  Stream<({String contentId, String name, String? savedToPath})>
  get contentReceived => _contentReceived.stream;

  /// Download progress for an in-flight fetch (verified/total pieces), emitted as
  /// each piece is stored/written — the UI shows it on the file bubble. The final
  /// emit has done == total; a fetch that never starts emits nothing.
  final _contentProgress =
      StreamController<({String contentId, int done, int total})>.broadcast();
  Stream<({String contentId, int done, int total})> get contentProgress =>
      _contentProgress.stream;

  /// Fires when a user download can't proceed — the re-advertise request timed
  /// out (the sender no longer serves the file). The UI clears any empty
  /// destination file and tells the user to ask for a re-send.
  final _contentFailed = StreamController<String>.broadcast();
  Stream<String> get contentDownloadFailed => _contentFailed.stream;

  /// Fires when the user explicitly cancels a content transfer. Kept separate
  /// from [contentDownloadFailed]: cancellation clears progress without showing
  /// the misleading "sender no longer serves this file" error.
  final _contentCancelled = StreamController<String>.broadcast();
  Stream<String> get contentDownloadCancelled => _contentCancelled.stream;

  /// User-cancelled ids stay latched until a fresh explicit download request.
  /// Every stream/datagram retry path consults this set, so aborting one stream
  /// cannot silently fail over to another holder behind the user's back.
  final Set<String> _cancelledDownloads = {};

  /// Re-request cadence for still-missing pieces (injectable for tests).
  final Duration _contentReRequestInterval;
  // Wire chunk per piece. Over the onion path a chunk is ONE auth_deliver message
  // (cap MAX_AUTH_DELIVER_MSG_BYTES 6144, base64+JSON framed) that fragments into
  // ceil(size/≈150 B) cells which must ALL arrive (no per-cell ARQ), so per-chunk
  // delivery is (1-p^redundancy)^cells. 512 B (~6 cells) was tuned for the BUGGY
  // rendezvous era (~50 % cell loss; 4000 B/~27 cells delivered ~2 %). With the
  // rendezvous fix delivery is now high, and a 512 B chunk wastes ~88 % of an
  // auth_deliver — millions of tiny messages for a big file. On a reliable
  // transport push it near the ceiling: 4096 B (base64+JSON ≈ 5.6 KB < 6144) is
  // the practical max, ~8× fewer messages than 512 B. Any chunk the queue/path
  // drops is healed by the chunk-granular re-request (self-correcting — never
  // lossy). Drop it back only if device logs show pieces stalling (per-chunk
  // delivery falling on a lossy path).
  static const _contentChunkBytes = 4096;
  // Per-chunk pacing: feed the local onion circuit builder steadily without
  // overflowing the per-session TX queue (a too-fast burst trips the silent
  // tx_queue drop — now logged as `LIMIT tx_queue`). Many small chunks, so keep
  // it short; tune against the tx_queue / delivery logs. Injectable so tests
  // (which deliver instantly) don't wait real-time per chunk.
  final Duration _contentPacing;

  /// How many not-yet-verified pieces a single re-request covers. Bounds the
  /// re-request size (each piece adds a ceil(chunkCount/8)-byte bitmap) so the
  /// re-request itself stays small enough to survive the lossy path, and focuses
  /// serving on a few pieces at a time so they complete sooner.
  static const _reRequestPieceWindow = 4;

  /// How many content chunks to put on the wire CONCURRENTLY before the next
  /// anti-burst pace. The serve loop used to send one chunk per [_contentPacing]
  /// (20 ms) — so a ~2250-chunk 1 MiB file spent ~45 s purely pacing. Emitting a
  /// small batch at once ("parallel parts") fills the session TX queue closer to
  /// the circuit's drain rate for a ~Nx speedup, while staying under the native
  /// auth-deliver verify queue capacity. Device logs showed batch=6 could
  /// repeatedly fill that queue (`auth-deliver verify queue unavailable`) and
  /// stall large file-save retries near the tail, so the live default is
  /// conservative and tunable with `XVEIL_CONTENT_SERVE_BATCH`.
  final int _contentServeBatch;

  /// Whether explicit plaintext save-to-file should try the fast stream/range
  /// path before the conservative piece fallback. Production defaults to the
  /// Dart define so the datagram path stays the baseline; tests and soaks can
  /// opt in without recompiling the whole app.
  final bool _plainFileStream;

  /// Files larger than this go via the content layer (hash-verified pieces over
  /// the NAT-traversing datagram path) instead of the per-chunk fileMeta push.
  // Keep the legacy fileMeta/fileChunk burst below the native session queue's
  // cell budget. Larger attachments use the paced, hash-verified content path
  // with chunk-granular retries; this includes ordinary camera screenshots.
  static const _contentThreshold = 128 * 1024;

  /// Piece size that keeps the hash-verified unit small for the stream/range
  /// path. Large manifests no longer need to fit one auth-deliver frame: when
  /// the full hash list would exceed the inline cap, we advertise a tiny
  /// manifest-ref and let the receiver fetch the full manifest over a reliable
  /// stream before pulling ranges. Keep up to a few thousand pieces before
  /// widening the piece size so very large files do not produce huge manifests.
  ///
  /// The piece is ALSO capped: it is the RAM-resident unit on every hop
  /// (hashing, verify, per-piece AEAD in the on-disk tier), so letting it
  /// scale unbounded turned "TB file" into "256 MB piece in phone RAM". Past
  /// the cap the piece COUNT grows instead — the ceiling then comes from the
  /// durable manifest (~3.6 MB storeFile cap ≈ 32 K piece hashes), i.e. ~1 TB.
  static int adaptivePieceSize(int size) {
    return ContentManifest.adaptivePieceSize(size);
  }

  /// Offer [bytes] as bare content and return its self-authenticating id.
  Future<String> sendContent(NodeId dst, Uint8List bytes, String name) =>
      _publishContent(dst, bytes, name);

  /// Share an existing content-addressed blob as a new file-post event.
  Future<bool> shareStoredContent(NodeId dst, String contentId) =>
      _shareStoredContent(dst, contentId);

  /// Send an Opus voice message with its duration and waveform sidecar.
  Future<void> sendVoice(
    NodeId dst,
    Uint8List bytes,
    int durationMs,
    List<double> waveform, {
    String? lang,
  }) => _sendVoiceContent(dst, bytes, durationMs, waveform, lang: lang);

  /// Send a round video note with an optional first-frame thumbnail.
  Future<void> sendVideoNote(
    NodeId dst,
    Uint8List bytes,
    int durationMs, {
    String? thumbB64,
  }) => _sendVideoNoteContent(dst, bytes, durationMs, thumbB64: thumbB64);

  /// Send an image sticker through the content-addressed transfer path.
  Future<void> sendSticker(NodeId dst, Uint8List bytes) =>
      _sendStickerContent(dst, bytes);

  /// Send a sticker-pack blob with an optional first-sticker thumbnail.
  Future<void> sendStickerPack(
    NodeId dst,
    Uint8List blob, {
    String? firstThumbB64,
  }) => _sendStickerPackContent(dst, blob, firstThumbB64: firstThumbB64);

  /// Hash and serve a large file directly from its source without copying it.
  ///
  /// Ownership of the source passes to the service; [close] is invoked when it
  /// is rejected, replaced, evicted, or the service is disposed.
  Future<String?> sendFileStreaming(
    NodeId dst,
    String name,
    int size,
    Future<Uint8List> Function(int offset, int length) read, {
    required Future<void> Function() close,
    String? sourcePath,
  }) => _sendFileStreamingContent(
    dst,
    name,
    size,
    read,
    close: close,
    sourcePath: sourcePath,
  );

  /// The user opted to download an OFFERED file into local STORAGE (the encrypted
  /// on-disk tier for a large file, or the hidden volume for a small one). No-op
  /// if we already hold the blob. If the in-memory manifest handle is gone (app
  /// restart — the offer MESSAGE synced via the event log but the one-shot
  /// manifest did not), ask the sender (over [peer]) to re-advertise; the
  /// download then continues automatically when the manifest arrives. The
  /// download choice itself is the §16.5 consent — a large file lands as an
  /// encrypted on-disk blob.
  Future<ContentDownloadResult> downloadContent(
    NodeId peer,
    String contentId,
  ) async {
    if (await _storage.hasFile(contentId)) {
      _signal();
      return ContentDownloadResult.started;
    }
    _cancelledDownloads.remove(contentId);
    devLog(() => 'xVeil[content]: user download ${contentId.substring(0, 12)}');
    // Multi-device: in parallel, ask my OTHER devices for the bytes over the
    // membership pull (no-op unless this cid is a mirrored attachment). The
    // conversation peer may be unreachable — or, for a mirrored OUTGOING
    // file, may never have had the blob at all.
    unawaited(deviceContentPull?.call(contentId));
    _warmStreamPeer(peer);
    // An explicit user retry overrides a terminal "gone" mark — if the bytes
    // are still gone everywhere, the next reoffer round re-marks it.
    unawaited(_clearContentGone(contentId));
    _markContentDownloadStarted(contentId);
    _recordPendingDownload(
      contentId,
      mode: _PendingDownload.modeStore,
      peers: [peer],
    );
    final retryPeers = await _contentSourcePeers(
      preferred: peer,
      contentId: contentId,
    );
    final offered = _offered[contentId];
    if (offered != null &&
        await _pullSwarmStream(peer, contentId, offered.manifest, retryPeers)) {
      return ContentDownloadResult.started;
    }
    final offeredRef = _offeredRefs[contentId];
    if (offeredRef != null &&
        await _beginFetchFromManifestRef(
          _offerRefPeer(offeredRef, preferred: peer),
          contentId,
          offeredRef.ref,
          null,
          null,
        )) {
      return ContentDownloadResult.started;
    }
    // Legacy reliable STREAM fallback for encrypted/in-store downloads: it can
    // resume across known sources after a partial payload. Keep this path, but
    // do not pre-probe the manifest here; the probe consumes a stream open and
    // can mask the very first failure that this fallback is meant to survive.
    if (await _pullStream(peer, contentId, null, retryPeers: retryPeers)) {
      return ContentDownloadResult.started;
    }
    // Datagram fallback (transport has no streams — e.g. a loopback fake).
    if (offered == null) {
      return _requestReofferFromAny(retryPeers, contentId, null);
    }
    await _beginFetch(_offerPeer(offered, preferred: peer), offered.manifest);
    return ContentDownloadResult.started;
  }

  /// Swarm/group download primitive: fetch [contentId] from the first eligible
  /// source that can actually serve it (an accepted contact, or a peer scoped
  /// to this cid by [downloadGroupContentFromAny]). This is deliberately
  /// content-addressed — any holder of the verified blob can seed the same
  /// bytes, so a group/torrent layer can pass current members instead of
  /// depending on the original sender staying online.
  ///
  /// The normal one-peer [downloadContent] path starts the pull and returns
  /// immediately for UI responsiveness. This method awaits each stream attempt
  /// to a terminal result before trying the next source, so a dead/non-seeding
  /// peer does not strand the transfer when another eligible peer has the blob.
  Future<ContentDownloadResult> downloadGroupContentFromAny(
    Iterable<NodeId> currentMembers,
    String contentId,
  ) {
    final sources = _uniquePeers(currentMembers);
    if (sources.isEmpty) {
      return Future.value(ContentDownloadResult.noOffer);
    }
    // GroupService has already checked that self/currentMembers belong to the
    // folded group and that cid is referenced by a validated group message,
    // then sent every candidate a signed membership request. Keep this scoped
    // to (peer,cid,TTL): it must never turn group membership into a generic
    // read/probe capability.
    _allowGroupPullSources(contentId, sources);
    return downloadContentFromAny(sources, contentId);
  }

  Future<ContentDownloadResult> downloadContentFromAny(
    Iterable<NodeId> peers,
    String contentId, {
    bool userInitiated = true,
  }) async {
    if (await _storage.hasFile(contentId)) {
      _signal();
      return ContentDownloadResult.started;
    }
    if (userInitiated) {
      _cancelledDownloads.remove(contentId);
    } else if (_cancelledDownloads.contains(contentId)) {
      return ContentDownloadResult.noOffer;
    }
    final offered = _offered[contentId];
    final offeredRef = _offeredRefs[contentId];
    final storedSources = await _storedContentSourcePeers(contentId);
    final sources = _filterGoneSources(
      contentId,
      _uniquePeers([
        ...peers,
        if (offered != null) ...offered.peers.values,
        if (offeredRef != null) ...offeredRef.peers.values,
        ...storedSources,
      ]),
    );
    final seen = <String>{};
    var attempted = 0;
    _markContentDownloadStarted(contentId);
    _recordPendingDownload(
      contentId,
      mode: _PendingDownload.modeStore,
      peers: sources,
    );
    if (offered != null) {
      // A fresh advertisement identifies peers that actually answered with
      // this content. Start the range swarm from those holders only; mixing
      // every merely-eligible group member back in here would put offline
      // non-holders ahead of the live announcer and recreate the timeout the
      // holder hint is meant to avoid. The blind candidate loop below remains
      // the compatibility fallback if every advertised holder fails.
      final advertisedSources = _uniquePeers(offered.peers.values);
      if (advertisedSources.isNotEmpty &&
          await _pullSwarmPiecesToCompletion(
            advertisedSources,
            offered.manifest,
          )) {
        return ContentDownloadResult.started;
      }
    }
    if (offeredRef != null &&
        sources.isNotEmpty &&
        await _beginFetchFromManifestRef(
          _offerRefPeer(offeredRef, preferred: sources.first),
          contentId,
          offeredRef.ref,
          null,
          null,
        )) {
      return ContentDownloadResult.started;
    }
    // No live offer survived (the common group-reseed case after a requester
    // restart). Probe every authorized candidate in parallel for the manifest
    // instead of spending one full native stream-open timeout per offline or
    // non-holding member. The probe asks for one payload byte, validates the
    // content-addressed manifest, and closes; the first real holder wins.
    final discovered = await _raceManifestHeaders(sources, contentId);
    if (discovered != null) {
      seen.add(discovered.$1.hex);
      attempted++;
      _rememberOfferedManifest(discovered.$1, discovered.$2);
      devLog(
        () =>
            'xVeil[content]: swarm manifest race '
            '${contentId.substring(0, 12)} won by ${discovered.$1.short}',
      );
      final ok = await _pullStreamToCompletion(discovered.$1, contentId);
      if (ok == true || await _storage.hasFile(contentId)) {
        return ContentDownloadResult.started;
      }
    }
    for (final peer in sources) {
      if (!seen.add(peer.hex)) continue;
      if (!await _eligiblePullSource(peer, contentId)) continue;
      attempted++;
      devLog(
        () =>
            'xVeil[content]: swarm download '
            '${contentId.substring(0, 12)} trying ${peer.short}',
      );
      final ok = await _pullStreamToCompletion(peer, contentId);
      if (ok == true || await _storage.hasFile(contentId)) {
        return ContentDownloadResult.started;
      }
      devLog(
        () =>
            'xVeil[content]: swarm source failed '
            '${contentId.substring(0, 12)} <- ${peer.short}',
      );
    }
    devLog(
      () =>
          'xVeil[content]: swarm download failed '
          '${contentId.substring(0, 12)} sources=$attempted',
    );
    if (!_contentFailed.isClosed) _contentFailed.add(contentId);
    return ContentDownloadResult.noOffer;
  }

  /// The user opted to download an OFFERED file UNENCRYPTED, straight to a
  /// plaintext file they picked. [write]/[close] is the file sink (created in the
  /// UI); each verified piece is written at its byte offset, nothing is kept in
  /// the app. On completion the file is closed and a [contentReceived] event
  /// fires carrying [savedPath]. If the manifest handle is gone, the sender is
  /// asked to re-advertise (the sink is held until it arrives or times out).
  Future<ContentDownloadResult> downloadContentToFile(
    NodeId peer,
    String contentId,
    String savedPath, {
    required Future<void> Function(int offset, Uint8List bytes) write,
    required Future<void> Function() close,
  }) async {
    _cancelledDownloads.remove(contentId);
    final sink = (write: write, close: close, read: null);
    _fetchSavePath[contentId] = savedPath;
    devLog(
      () =>
          'xVeil[content]: user download-to-file (unencrypted) '
          '${contentId.substring(0, 12)} -> $savedPath',
    );
    _warmStreamPeer(peer);
    unawaited(_clearContentGone(contentId));
    _markContentDownloadStarted(contentId);
    if (await _storage.hasFile(contentId)) {
      return await _exportStoredContentToSink(contentId, sink, savedPath)
          ? ContentDownloadResult.started
          : ContentDownloadResult.noOffer;
    }
    _recordPendingDownload(
      contentId,
      mode: _PendingDownload.modeFile,
      savedPath: savedPath,
      peers: [peer],
    );
    final retryPeers = await _contentSourcePeers(
      preferred: peer,
      contentId: contentId,
    );
    final offered = _offered[contentId];
    if (offered != null) {
      if (_plainFileStream &&
          await _pullSwarmStreamToFile(
            _offerPeer(offered, preferred: peer),
            contentId,
            offered.manifest,
            retryPeers,
            sink,
            savedPath,
          )) {
        return ContentDownloadResult.started;
      }
      await _beginFetch(
        _offerPeer(offered, preferred: peer),
        offered.manifest,
        sink: sink,
      );
      return ContentDownloadResult.started;
    }
    final offeredRef = _offeredRefs[contentId];
    if (offeredRef != null &&
        await _beginFetchFromManifestRef(
          _offerRefPeer(offeredRef, preferred: peer),
          contentId,
          offeredRef.ref,
          sink,
          savedPath,
        )) {
      return ContentDownloadResult.started;
    }
    // The caller knows the sender and content id, but the one-shot manifest/ref
    // announcement may have been lost. Probe the manifest from a reliable stream
    // and then use the parallel range/swarm path before parking a plaintext save
    // behind the lossy reoffer control path.
    if (await _beginFetchFromStreamManifest(
      peer,
      contentId,
      sink,
      savedPath: savedPath,
      peers: retryPeers,
    )) {
      return ContentDownloadResult.started;
    }
    return _requestReofferFromAny(retryPeers, contentId, sink);
  }

  /// Swarm/group variant of [downloadContentToFile]: write verified plaintext
  /// bytes to [savedPath] from the first known holder that can serve [contentId].
  ///
  /// This is used by debug/soak automation and the future group/torrent layer:
  /// the caller may pass all accepted holders it knows about, while the service
  /// augments that list with live offers and persisted incoming file-offer
  /// messages. The app storage remains empty; successful completion only records
  /// [savedPath] as an external plaintext destination.
  Future<ContentDownloadResult> downloadContentToFileFromAny(
    Iterable<NodeId> peers,
    String contentId,
    String savedPath, {
    required Future<void> Function(int offset, Uint8List bytes) write,
    required Future<void> Function() close,
    // Non-null on a RESUME: reads pieces back off disk so the swarm skips the
    // ones already written (see [_FetchSink.read]).
    Future<Uint8List?> Function(int offset, int length)? read,
    bool userInitiated = true,
  }) async {
    if (userInitiated) {
      _cancelledDownloads.remove(contentId);
    } else if (_cancelledDownloads.contains(contentId)) {
      return ContentDownloadResult.noOffer;
    }
    final sink = (write: write, close: close, read: read);
    _fetchSavePath[contentId] = savedPath;
    devLog(
      () =>
          'xVeil[content]: user download-to-file-any (unencrypted) '
          '${contentId.substring(0, 12)} -> $savedPath',
    );
    _markContentDownloadStarted(contentId);
    if (await _storage.hasFile(contentId)) {
      return await _exportStoredContentToSink(contentId, sink, savedPath)
          ? ContentDownloadResult.started
          : ContentDownloadResult.noOffer;
    }
    final offered = _offered[contentId];
    final offeredRef = _offeredRefs[contentId];
    final sources = _filterGoneSources(
      contentId,
      _uniquePeers([
        ...peers,
        if (offered != null) ...offered.peers.values,
        if (offeredRef != null) ...offeredRef.peers.values,
        ...await _storedContentSourcePeers(contentId),
      ]),
    );
    _recordPendingDownload(
      contentId,
      mode: _PendingDownload.modeFile,
      savedPath: savedPath,
      peers: sources,
    );
    if (offered != null) {
      if (sources.isEmpty && offered.peers.isEmpty) {
        return _requestReofferFromAny(sources, contentId, sink);
      }
      final preferred = sources.isNotEmpty
          ? sources.first
          : offered.peers.values.first;
      if (_plainFileStream &&
          await _pullSwarmStreamToFile(
            preferred,
            contentId,
            offered.manifest,
            sources,
            sink,
            savedPath,
          )) {
        return ContentDownloadResult.started;
      }
      await _beginFetch(
        _offerPeer(offered, preferred: preferred),
        offered.manifest,
        sink: sink,
      );
      return ContentDownloadResult.started;
    }
    if (offeredRef != null) {
      if (sources.isNotEmpty &&
          await _beginFetchFromManifestRef(
            _offerRefPeer(offeredRef, preferred: sources.first),
            contentId,
            offeredRef.ref,
            sink,
            savedPath,
          )) {
        return ContentDownloadResult.started;
      }
    }
    if (sources.isNotEmpty &&
        await _beginFetchFromStreamManifest(
          sources.first,
          contentId,
          sink,
          savedPath: savedPath,
          peers: sources,
        )) {
      return ContentDownloadResult.started;
    }
    return _requestReofferFromAny(sources, contentId, sink);
  }

  /// Surface user intent immediately. The stream path may spend seconds opening
  /// an anonymous circuit before the manifest / first verified piece arrives;
  /// without this, the file bubble looks like the tap was ignored.
  void _markContentDownloadStarted(String contentId) {
    if (!_contentProgress.isClosed) {
      _contentProgress.add((contentId: contentId, done: 0, total: 1));
    }
  }

  /// Cancel an in-flight or parked user download. Returns the plaintext target
  /// path, when this was a download-to-file, so the UI can delete partial clear
  /// bytes (the transport/storage core deliberately has no dart:io access).
  Future<String?> cancelContentDownload(String contentId) =>
      _downloadResume.cancel(contentId);

  // ------------------------------------------------------------------------
  // AUTO-RESUME of interrupted downloads (torrent-like).
  //
  // Every explicit download request (the four public entry points) writes a
  // durable record into the settings KV. The record survives restarts; it is
  // cleared only when the content completes (contentReceived / blob present /
  // plaintext savedPath recorded). A driver re-issues the download:
  //   - on service start (post-unlock), staggered;
  //   - on node (re)connect (reconcileOnConnect);
  //   - when an offer/manifest for a pending content id arrives (sender came
  //     back online);
  //   - after each contentDownloadFailed, with exponential backoff.
  // The encrypted tier resumes at PIECE granularity for free (verified pieces
  // persist in the blob store and the swarm skips them). A plain-file download
  // resumes at the received offset within a session; across a restart it
  // restarts from byte 0 into the same destination (the file sink keeps no
  // durable piece bookkeeping — and on sandboxed macOS the NSSavePanel grant
  // does not survive the restart anyway, in which case the record is dropped).

  /// Tunable delays (tests shrink these; production keeps the defaults).
  Duration get downloadResumeStartDelay => _downloadResume.startDelay;
  set downloadResumeStartDelay(Duration value) {
    _downloadResume.startDelay = value;
  }

  Duration get downloadResumeBackoffBase => _downloadResume.backoffBase;
  set downloadResumeBackoffBase(Duration value) {
    _downloadResume.backoffBase = value;
  }

  Duration get downloadResumeBackoffCap => _downloadResume.backoffCap;
  set downloadResumeBackoffCap(Duration value) {
    _downloadResume.backoffCap = value;
  }

  Duration get downloadResumeLiveGrace => _downloadResume.liveGrace;
  set downloadResumeLiveGrace(Duration value) {
    _downloadResume.liveGrace = value;
  }

  /// Cancel every durable auto-resume: stop the timers, forget the parked
  /// set + attempt counters, and wipe the persisted registry. Used by the
  /// bench purge hook to clear zombie pulls (a dead ephemeral holder never
  /// answers content-GONE, so they otherwise linger the whole 14-day window).
  /// Returns how many pending downloads were dropped.
  Future<int> clearPendingDownloads() => _downloadResume.clearPending();

  /// Pending-download records that should auto-resume (test/UI introspection).
  Future<List<String>> pendingAutoResumeContentIds() =>
      _downloadResume.pendingContentIds();

  /// contentIds with a durable auto-resume record right now (queued / retrying
  /// in the background — the sender may be offline). Distinct from
  /// [contentProgress], which fires only while a pull is ACTIVELY moving bytes;
  /// a parked resume shows no progress, so the UI would otherwise look idle.
  /// The UI shows "resuming…" when a cid is here but has no live progress.
  Stream<Set<String>> get contentResuming => _downloadResume.resuming;

  void _recordPendingDownload(
    String contentId, {
    required String mode,
    String? savedPath,
    required Iterable<NodeId> peers,
  }) => _downloadResume.record(
    contentId,
    mode: mode,
    savedPath: savedPath,
    peers: peers,
  );

  /// Per-content count of pull executions currently in flight (sequential
  /// [_runPull] / the range swarm). The auto-resume driver consults it so it
  /// never stacks a second concurrent pull onto a live one — a duplicate
  /// wastes bandwidth and makes the shared progress channel oscillate.
  void _pullStarted(String contentId) => _downloadResume.pullStarted(contentId);

  void _pullEnded(String contentId) => _downloadResume.pullEnded(contentId);

  /// Persist [m] once if a durable pending download exists for it — offers
  /// often arrive as manifest-REFS, so the full manifest only becomes known
  /// mid-pull (stream header / ref resolve); this is what makes a
  /// piece-granular resume possible after a restart.
  Future<void> _persistManifestIfPending(ContentManifest manifest) =>
      _downloadResume.persistManifestIfPending(manifest);

  Future<ContentManifest?> _loadPersistedManifest(String contentId) =>
      _downloadResume.loadPersistedManifest(contentId);

  /// Re-bind a cid-level serve manifest to the latest live filePost for this
  /// particular peer. A single cloud blob may be shared to several contacts;
  /// using whichever msgId last occupied `_serving[cid]` would make a reoffer
  /// surface the wrong recipient's event.
  Future<ContentManifest> _manifestForPeerOffer(
    NodeId peer,
    ContentManifest manifest,
  ) async {
    try {
      final messages = await _storage.loadMessages(peer.hex);
      for (final message in messages.reversed) {
        final cid = message.fileContentId ?? message.fileId;
        if (message.direction != MessageDirection.outgoing ||
            cid != manifest.contentId) {
          continue;
        }
        return manifest.withEvent(
          msgId: message.id,
          author: message.author,
          seq: message.seq,
          ts: message.timestamp.millisecondsSinceEpoch,
          thumbB64: message.thumb,
        );
      }
    } catch (_) {}
    return manifest;
  }

  void _completePendingDownload(String contentId) =>
      _downloadResume.complete(contentId);

  Future<void> _startDownloadResumer() => _downloadResume.start();

  /// Best-effort pre-warm of the outbound stream path toward [peer] (see
  /// [StreamTransport.warmStreamPeer]). Fire-and-forget: never blocks the
  /// caller and never throws.
  void _warmStreamPeer(NodeId peer) => _downloadResume.warmPeer(peer);

  /// An offer/manifest for a durable-pending content id arrived — the sender
  /// is provably online, resume soon (the short delay lets an already-running
  /// pull surface progress, which the liveness check then respects).
  Future<void> _resumeOnOfferSignal(
    String contentId, {
    ContentManifest? manifest,
  }) => _downloadResume.onOffer(contentId, manifest: manifest);

  /// Any inbound traffic from [peer] proves it is online: revive every PARKED
  /// pending download that lists it as a holder. Cheap no-op on the hot path
  /// when nothing is parked (the common case).
  void noteInboundFromPeer(NodeId peer) => _downloadResume.noteInbound(peer);

  /// Sink opener used to re-drive plain-file downloads (injectable for tests;
  /// dart:io stays in the data layer). [resume]=true reopens WITHOUT truncating
  /// and exposes a reader so already-written pieces are hash-verified + skipped.
  Future<VeilPlainFileSink?> Function(String path, {bool resume})
  get plainFileSinkOpener => _downloadResume.plainFileSinkOpener;
  set plainFileSinkOpener(
    Future<VeilPlainFileSink?> Function(String path, {bool resume}) value,
  ) {
    _downloadResume.plainFileSinkOpener = value;
  }

  /// Destination paths for in-flight unencrypted-to-file downloads (so the
  /// completion event can report where the plaintext file landed).
  final Map<String, String> _fetchSavePath = {};

  /// The plaintext path an UNENCRYPTED download of [contentId] was saved to —
  /// the UI OPENS it on tap instead of re-offering (it isn't in the app store).
  /// Null if it was never downloaded unencrypted.
  Future<String?> contentSavedPath(String contentId) =>
      _storage.getSetting('saved:$contentId');

  Future<bool> _exportStoredContentToSink(
    String contentId,
    _FetchSink sink,
    String savedPath,
  ) async {
    final short = contentId.substring(0, 12);
    if (!await _storage.hasFile(contentId)) return false;
    try {
      final mfBytes = await _storage.loadFile('mf:$contentId');
      if (mfBytes != null) {
        final manifest = ContentManifest.fromJson(
          jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
        );
        if (manifest == null || manifest.contentId != contentId) {
          throw StateError('stored manifest does not bind content id');
        }
        devLog(
          () =>
              'xVeil[content]: exporting stored $short '
              '(${manifest.size}B) -> $savedPath',
        );
        const chunkSize = 1024 * 1024;
        var offset = 0;
        while (offset < manifest.size) {
          var want = manifest.size - offset;
          if (want > chunkSize) want = chunkSize;
          final bytes = await _storage.readFileRange(contentId, offset, want);
          if (bytes == null || bytes.length != want) {
            throw StateError('stored range missing at $offset+$want');
          }
          await sink.write(offset, bytes);
          offset += want;
          if (!_contentProgress.isClosed) {
            _contentProgress.add((
              contentId: contentId,
              done: offset,
              total: manifest.size,
            ));
          }
        }
        await sink.close();
        await _storage.putSetting('saved:$contentId', savedPath);
        _fetchSavePath.remove(contentId);
        if (!_contentReceived.isClosed) {
          _contentReceived.add((
            contentId: contentId,
            name: manifest.name,
            savedToPath: savedPath,
          ));
        }
        devLog(
          () =>
              'xVeil[content]: COMPLETE $short '
              '(${manifest.size}B) exported to $savedPath',
        );
        return true;
      }

      // Legacy/small-file fallback: old stores may have the blob but no
      // persisted stream manifest. This can hold the file in RAM, so the normal
      // streamed-manifest path above remains the preferred one.
      final bytes = await _storage.loadFile(contentId);
      if (bytes == null) return false;
      devLog(
        () =>
            'xVeil[content]: exporting stored $short '
            '(${bytes.length}B, no manifest) -> $savedPath',
      );
      await sink.write(0, bytes);
      await sink.close();
      await _storage.putSetting('saved:$contentId', savedPath);
      _fetchSavePath.remove(contentId);
      if (!_contentProgress.isClosed) {
        _contentProgress.add((
          contentId: contentId,
          done: bytes.length,
          total: bytes.length,
        ));
      }
      if (!_contentReceived.isClosed) {
        _contentReceived.add((
          contentId: contentId,
          name: contentId,
          savedToPath: savedPath,
        ));
      }
      _clearGroupPullSources(contentId);
      return true;
    } catch (e) {
      devLog(() => 'xVeil[content]: export stored $short failed: $e');
      try {
        await sink.close();
      } catch (_) {}
      _fetchSavePath.remove(contentId);
      if (!_contentFailed.isClosed) _contentFailed.add(contentId);
      return false;
    }
  }

  Future<bool> _consumeParkedPlainFileSave(String contentId) async {
    if (!_contentAvailability.hasPending(contentId)) return false;
    final sink = _contentAvailability.takePending(contentId);
    if (sink == null) return false;
    final savedPath = _fetchSavePath[contentId];
    if (savedPath == null) {
      try {
        await sink.close();
      } catch (_) {}
      return true;
    }
    await _exportStoredContentToSink(contentId, sink, savedPath);
    return true;
  }

  /// Ask all known candidate holders to re-advertise [contentId] (we have an
  /// offer message but not the live manifest) and park the download until one
  /// manifest arrives. A timeout frees a parked file sink (so a RandomAccessFile
  /// handle isn't leaked if nobody can serve — then the user must re-send).
  ContentDownloadResult _requestReofferFromAny(
    Iterable<NodeId> peers,
    String contentId,
    _FetchSink? sink,
  ) => _contentAvailability.requestReofferFromAny(peers, contentId, sink);

  /// Ask [peer] to re-advertise [contentId] without parking or starting a
  /// download. Used by headless/test waiters that know the content id from the
  /// sender's /send_file result and only need the one-shot manifest to
  /// materialise as an OFFER in storage before they trigger an explicit save.
  Future<bool> requestContentReoffer(NodeId peer, String contentId) =>
      _contentAvailability.requestContentReoffer(peer, contentId);

  /// Debug/soak helper: materialise a lost one-shot content offer by fetching
  /// only the manifest over a reliable stream. The normal app path still relies
  /// on the advertised manifest/ref and reoffer semantics; headless tests know
  /// the content id from `/send_file`, so they can safely ask the sender for the
  /// manifest directly and surface the same offer the datagram would have stored.
  Future<bool> resolveContentOfferViaStream(NodeId peer, String contentId) =>
      _contentAvailability.resolveContentOfferViaStream(peer, contentId);

  /// A peer asked us to re-advertise [contentId] (their manifest handle is gone).
  /// Re-send the manifest if we are still serving it (refreshing its TTL), or —
  /// DURABLE offer — re-open the persisted source file and re-serve from the
  /// persisted manifest (so an offer survives our restart / the serve TTL). Fails
  /// quietly (→ receiver times out → re-send) if there is no durable record, no
  /// opener, or the file is gone.
  Future<void> _onContentReoffer(NodeId peer, String contentId) =>
      _contentAvailability.onContentReoffer(peer, contentId);

  /// True when every known holder of [contentId] said GONE — persisted, so the
  /// chat bubble can render "ask the sender to re-send" across restarts.
  Future<bool> isContentUnavailable(String contentId) =>
      _contentAvailability.isContentUnavailable(contentId);

  List<NodeId> _filterGoneSources(String contentId, Iterable<NodeId> peers) =>
      _contentAvailability.filterGoneSources(contentId, peers);

  Future<void> _onContentGone(NodeId peer, String contentId) =>
      _contentAvailability.onContentGone(peer, contentId);

  /// A fresh offer/manifest proves the content is obtainable again (the sender
  /// re-sent it) — clear the terminal mark and this session's gone set.
  Future<void> _clearContentGone(String contentId) =>
      _contentAvailability.clearContentGone(contentId);

  /// Content ids with a [_serveChunks] loop currently running — only ONE serve
  /// per content at a time. A serve-from-source [RandomAccessFile] is a single
  /// cursor, so two concurrent serves thrash it ("An async operation is currently
  /// pending", and almost every read fails → the transfer crawls). A request that
  /// lands mid-serve is skipped; the receiver's re-request loop re-asks for
  /// whatever is still missing once the current serve finishes.
  final Set<String> _servingNow = {};

  // ── Stream-based bulk transfer (S2/S3) ──────────────────────────────────────
  // Large files ride veil's RELIABLE, window-flow-controlled stream instead of
  // fire-and-forget datagrams + manual re-request: the transport's congestion
  // control fills the circuit without overflowing the tx_queue (the datagram path
  // blasted ~6:1 → ~80% drops). Wire: the receiver opens a stream and writes the
  // 32-byte contentId; the sender replies [u32 manifest-len][manifest JSON][file
  // bytes…] then closes (EOF). The receiver checks the manifest binds the
  // REQUESTED cid (cid binds manifest binds pieces → a malicious sender can't
  // substitute), then verifies each piece as it reassembles from the byte stream.
  // Request frame: [cid 32][offset u64][length u64][padding]. A zero length is
  // the legacy "stream to EOF" form; a non-zero length lets swarm/range pulls
  // ask a holder for exactly one piece without wasting tail bytes.

  static const int _streamReadChunk =
      256 * 1024; // source read / wire write unit
  static const int _streamRequestBytes =
      48; // fixed request frame: cid + offset + length
  // The responder may need to wake/reopen its outbound return circuit before a
  // SYN-ACK/request can complete. Real phone↔desktop logs showed the native
  // layer reopening a quiet path at ~21s; a 20s app read timeout reset the stream
  // just before recovery. Keep this above the native quiet-path reopen window.
  static const Duration _defaultStreamRequestTimeout = Duration(seconds: 60);
  static const Duration _streamManifestTimeout = Duration(seconds: 25);
  // Short "did this source even START answering" bound on the manifest read: a
  // holder that hasn't sent the 4-byte length prefix within this window is
  // treated as dead so [_fetchManifestFromStream] moves to the NEXT source
  // immediately, instead of blocking the whole 25s manifest cap on one silent
  // peer. This is the manifest-phase analogue of the range/data stall-abandon
  // detector — without it a resume whose first-tried holder is offline stalled
  // up to 25s per attempt (masked by hedging, but real added latency). The
  // full 25s cap still governs a manifest that HAS started streaming. Tunable.
  Duration streamManifestFirstByteTimeout = const Duration(seconds: 8);
  static const Duration _streamSourceReadTimeout = Duration(seconds: 30);
  static const Duration _defaultStreamOpenWriteGrace = Duration(
    milliseconds: 75,
  );
  // Receiver-side payload idle. Keep this below the sender's write-idle timeout:
  // live traces showed the native route layer detecting no-progress within a
  // few seconds, but the single-stream app pull still waited 60s before retrying
  // while the sender gave up after 30s. Retrying first preserves the sender's
  // serving slot/window for resumable pulls instead of waking up to "not
  // serving" after the old write timed out.
  static const Duration _defaultStreamPayloadIdleTimeout = Duration(
    seconds: 20,
  );
  // Range streams are independently retryable and verified per piece, but their
  // idle timer is per worker while all workers share one onion/circuit budget.
  // At 12 workers a healthy range can legitimately go quiet for several seconds
  // while other ranges drain; treating that as dead caused resume storms (dozens
  // of partial 512 KiB ranges timed out at 3s and reopened together). Ten
  // seconds cuts real zero-progress plateaus quickly enough to avoid long
  // 64 MiB tail stalls. The current default fanout is p8, not p12, and the
  // range target is large enough to keep resume storms low: live phone↔desktop
  // soaks with 1 MiB ranges completed intact above the 1.5 MiB/s target while
  // 20s left stalled ranges parked too long.
  static final Duration _streamRangePayloadIdleTimeout =
      _streamRangePayloadIdleMsDartDefine > 0
      ? Duration(milliseconds: _streamRangePayloadIdleMsDartDefine)
      : const Duration(seconds: 10);
  // Per-stream stall detector for range pulls. The absolute idle timeout above
  // must stay long enough for a globally quiet circuit (route churn can pause
  // EVERY stream for seconds), but when OTHER range workers keep receiving
  // bytes while this stream stays silent, the silence is evidence of a
  // stalled/black-holed route, not global congestion. Live traces showed the
  // native layer remapping such a stream after ~2 consecutive RTOs (~3s with
  // the 1s RTO floor) while the app reader still parked the worker for the
  // full 10s idle window. Abandoning at 2.5s aborts the read, frees the
  // sender's serve slot with a RST and resumes from the received byte count on
  // a fresh stream, which the native pool routes around the cooled relay.
  static const Duration _streamRangeStallProbe = Duration(milliseconds: 500);
  // Tail hedging: when the pending queue is empty, an idle worker duplicates
  // the quietest in-flight range on a fresh stream instead of exiting. At the
  // tail there may be no "other workers progressing" signal left for the stall
  // detector, so a single stalled range would otherwise pin the transfer until
  // its full idle timeout. The duplicate pull also revives the swarm progress
  // tick, which in turn lets the stalled original abandon early. First result
  // wins; pieces are verified before write, so a duplicate is byte-identical.
  static const int _maxStreamRangeHedges = 2;
  // Experimental: range workers share the same small native route/control pool,
  // so a future per-route scheduler may want to pace stream opens/retry-opens.
  // A fixed 25ms default regressed p12 on-device, so keep this opt-in for live
  // matrix probes instead of production behavior.
  static final Duration _streamRangeOpenPace =
      _streamRangeOpenPaceMsDartDefine > 0
      ? Duration(milliseconds: _streamRangeOpenPaceMsDartDefine)
      : Duration.zero;
  // Range workers are already inside a verified, resumable transfer. If a
  // payload stream died, waiting the full request timeout for every retry-open
  // turns one bad tail range into a minute-scale completion stall. Keep the
  // long timeout for initial/sequential opens, but fail range retry-opens fast
  // so another route/attempt can take over.
  static final Duration _streamRangeRetryOpenTimeout =
      _streamRangeRetryOpenMsDartDefine > 0
      ? Duration(milliseconds: _streamRangeRetryOpenMsDartDefine)
      : const Duration(seconds: 10);
  // Sender-side write idle. Keep this close to the receiver's range-idle window:
  // when a circuit route black-holes, old serve streams can otherwise sit in a
  // flow-controlled write for minutes and consume all per-content serve slots,
  // while receiver retry streams see EOF-before-manifest / "not serving".
  static const Duration _streamPayloadWriteTimeout = Duration(seconds: 30);
  // The native pinned-circuit backend keeps a small outbound route pool per
  // peer, so range workers can fan out over multiple receiver rendezvous relays
  // while each reliable stream remains pinned to its chosen route. On the
  // phone↔desktop 3-seed stand after the route-RTO/retry-open fixes, p8/p10
  // completed 64 MiB intact around 1.25 MiB/s, while p12+ repeatedly tripped
  // rendezvous reset/no-progress storms and regressed below 1 MiB/s. After the
  // native TX batching work a single stream reaches ~3.5 MiB/s, so fewer,
  // longer streams beat wide fanout: on-device 64 MiB measured p8/1MiB at
  // ~2.1 MiB/s vs p4/8MiB at ~3.4 MiB/s (longer DATA runs amortize per-cell
  // route/pacing/lock work and per-range manifest rounds).
  //
  // 2026-07-02: re-measured after the 4 KiB cell flag-day + BBR. p8 looked
  // faster on a 64 MiB file (13s vs 15.7s) but that was start-up noise; a
  // head-to-head on 256 MiB (both with zero range resumes) showed p4 holds
  // ~6.24 MiB/s active while p8 drops to ~4.2 — 8 streams contend on the same
  // 3 rendezvous routes in steady state. p4 stays the default; higher fanout
  // remains opt-in via XVEIL_STREAM_RANGE_PARALLELISM.
  static const int _defaultStreamRangeParallelism = 4;
  static const int _maxStreamRangeParallelism = 32;
  static const int _defaultStreamRangeTargetBytes = 8 * 1024 * 1024;
  // After the native TX batching work a single stream sustains ~6 MiB/s, so
  // per-range fixed costs (open + request + manifest round) dominate small
  // ranges: 64 MiB at 1 MiB ranges paid 64 of them (~2.1 MiB/s total) while
  // 2 MiB ranges reached ~3 MiB/s. Resume stays byte-granular within a range
  // and verification stays per 256 KiB piece, so coarser ranges do not
  // meaningfully coarsen recovery; the cap only bounds worst-case hedge
  // duplication.
  static const int _maxStreamRangeTargetBytes = 16 * 1024 * 1024;
  static const int _defaultStreamPullMaxAttempts = 24;
  final Duration _streamPayloadIdleTimeout;
  final Duration _streamRangeStallAbandon;
  final Duration _streamRangeHedgeAfter;
  final int _streamPullMaxAttempts;
  final int _streamRangeParallelism;
  final int _streamRangeTargetBytes;
  final bool _streamRangeEnabled;
  // True when range fanout was requested explicitly (constructor or
  // XVEIL_STREAM_RANGE_PARALLELISM) — then even a single-source pull uses the
  // range swarm; the sequential-stream shortcut applies only to the default.
  final bool _explicitRangeFanout;
  final Duration _streamOpenWriteGrace;
  final Duration _streamRequestTimeout;
  static int _clampStreamRangeParallelism(int value) {
    if (value < 1) return 1;
    if (value > _maxStreamRangeParallelism) return _maxStreamRangeParallelism;
    return value;
  }

  static int _clampStreamRangeTargetBytes(int value) {
    if (value < 1) return 1;
    if (value > _maxStreamRangeTargetBytes) {
      return _maxStreamRangeTargetBytes;
    }
    return value;
  }

  Uint8List _streamRequest(String cid, {int offset = 0, int length = 0}) =>
      Uint8List(_streamRequestBytes)
        ..setAll(0, _hexDecode(cid))
        ..setAll(32, _u64be(offset))
        ..setAll(40, _u64be(length));

  static Future<Uint8List> _awaitPayloadChunk(
    Future<Uint8List> read, {
    required Duration idle,
    required Duration stallAfter,
    required Stopwatch silence,
    required int tickAtLastChunk,
    required int Function()? swarmTick,
    required String Function(String reason) timeoutLabel,
  }) async {
    final chunk = Completer<Uint8List>();
    read.then(
      (v) {
        if (!chunk.isCompleted) chunk.complete(v);
      },
      onError: (Object e, StackTrace st) {
        if (!chunk.isCompleted) chunk.completeError(e, st);
      },
    );
    while (true) {
      final remaining = idle - silence.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException(timeoutLabel('idle'), idle);
      }
      final slice = remaining < _streamRangeStallProbe
          ? remaining
          : _streamRangeStallProbe;
      try {
        return await chunk.future.timeout(slice);
      } on TimeoutException {
        final tick = swarmTick?.call();
        if (tick != null &&
            tick != tickAtLastChunk &&
            silence.elapsed >= stallAfter) {
          throw _RangeStallTimeout(timeoutLabel('stalled'), silence.elapsed);
        }
      }
    }
  }

  static Duration _streamPullRetryDelay(int attempt) {
    final ms = 250 * attempt;
    return Duration(milliseconds: ms > 3000 ? 3000 : ms);
  }

  /// Finalise a completed RECEIVE: an unencrypted-to-file download closes the
  /// sink, remembers the path (tap → open), and reports it; an in-app store
  /// surfaces offer→downloaded. Acks the sender either way (flips sent→delivered).
  static Future<Uint8List?> _readExactly(ReliableStream s, int n) async {
    final out = BytesBuilder(copy: false);
    var got = 0;
    while (got < n) {
      final chunk = await s.read(maxBytes: n - got);
      if (chunk.isEmpty) return null; // EOF
      out.add(chunk);
      got += chunk.length;
    }
    return out.takeBytes();
  }

  static Uint8List _u32be(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v);
  static int _readU32be(Uint8List b) =>
      b.buffer.asByteData(b.offsetInBytes, 4).getUint32(0);
  static Uint8List _u64be(int v) =>
      Uint8List(8)..buffer.asByteData().setUint64(0, v);
  static int _readU64be(Uint8List b) =>
      b.buffer.asByteData(b.offsetInBytes, 8).getUint64(0);

  static String _hexEncode(Uint8List b) {
    const d = '0123456789abcdef';
    final sb = StringBuffer();
    for (final x in b) {
      sb
        ..write(d[(x >> 4) & 0xf])
        ..write(d[x & 0xf]);
    }
    return sb.toString();
  }

  static Uint8List _hexDecode(String s) {
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  void _ensureContentTimer() => _contentFetching.ensureTimer();

  Future<void> dropLiveServingStateForTest() => _clearServingState();

  Future<void> _clearServingState() => _contentServing.clear();

  Future<void> dispose() async {
    _disposed = true; // stops transfer retry/serve work
    _outbox.dispose();
    // Starts synchronously: the transport-scoped broker lease is detached
    // before Riverpod can construct a replacement service, while native
    // serve/pull streams are aborted and joined in the returned future.
    final contentStreamsDisposed = _contentStreams.dispose();
    _retryTimer?.cancel();
    _retryTimer = null;
    _settingsGcTimer?.cancel();
    _settingsGcTimer = null;
    await _downloadResume.dispose();
    await _sub?.cancel();
    _sub = null;
    await _realtimeSub?.cancel();
    _realtimeSub = null;
    await contentStreamsDisposed;
    await _clearServingState();
    _groupContent.clear();
    await _contentFetching.clear();
    await _contentAvailability.clearSession();
    await _changes.close();
    await _incoming.close();
    await _attestation.dispose();
    await _contentReceived.close();
    await _contentProgress.close();
    await _contentFailed.close();
    await _contentCancelled.close();
  }
}

/// A durable record of an explicitly-requested download that has not
/// completed yet — the unit of the torrent-like auto-resume registry
/// (settings KV, one JSON list under `pending_downloads`).
class _PendingDownload {
  const _PendingDownload({
    required this.contentId,
    required this.mode,
    required this.peers,
    required this.requestedAt,
    this.savedPath,
  });

  static const modeStore = 'store'; // encrypted tier / in-volume
  static const modeFile = 'file'; // plaintext to a user-picked path

  final String contentId;
  final String mode;
  final String? savedPath;
  final List<String> peers; // node-id hexes known to hold the content
  final DateTime requestedAt;

  Map<String, Object?> toJson() => {
    'cid': contentId,
    'mode': mode,
    if (savedPath != null) 'path': savedPath,
    'peers': peers,
    'at': requestedAt.toIso8601String(),
  };

  static _PendingDownload? fromJson(Map<String, dynamic> json) {
    final cid = json['cid'];
    final mode = json['mode'];
    if (cid is! String || cid.isEmpty || mode is! String) return null;
    final peers = json['peers'];
    return _PendingDownload(
      contentId: cid,
      mode: mode == modeFile ? modeFile : modeStore,
      savedPath: json['path'] as String?,
      peers: [
        if (peers is List)
          for (final p in peers)
            if (p is String) p,
      ],
      requestedAt:
          DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

/// One in-flight swarm-range pull, tracked for tail hedging: [lastChunk]
/// restarts on every payload chunk the owning worker receives, so an idle
/// worker can duplicate the quietest range on a fresh stream. [hedges] caps
/// duplication at one hedge per task.
class _ActiveRangeTask {
  _ActiveRangeTask(this.pieces, this.peer) : lastChunk = Stopwatch()..start();

  final List<int> pieces;
  final NodeId peer;
  final Stopwatch lastChunk;
  int hedges = 0;
}

/// A range payload read abandoned early because the swarm kept receiving
/// bytes while this stream stayed silent — evidence of a stalled route rather
/// than a sender that stopped serving. Distinguished from the plain idle
/// [TimeoutException] so the resume loop retries in place even at zero
/// received bytes instead of failing the range.
class _RangeStallTimeout extends TimeoutException {
  _RangeStallTimeout(String super.message, Duration super.duration);
}
