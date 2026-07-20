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
    required bool pinned,
    required bool archived,
    int? retentionDays,
    required bool allowPeerDelete,
  }) => _deviceMirror.applyContact(
    peer: peer,
    name: name,
    mutedUntilMs: mutedUntilMs,
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
  Future<void> sendGroupContentRequest(NodeId dst, String requestJson) async {
    GroupContentRequest? request;
    try {
      request = GroupContentRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      /* malformed local request → do not enqueue */
    }
    if (request == null) return;
    // Authorize the reply path BEFORE the request leaves this process. A
    // verified holder answers an accepted group request with a live
    // manifest/ref advertisement; without this early receiver-side scope the
    // normal contact gate would drop that advertisement before the delayed
    // group pull starts. The holder still independently verifies membership,
    // the group reference and freshness before it sends anything.
    _allowGroupPullSources(request.contentId, [dst]);
    final frameId =
        'gcr:${request.groupId.hex}:${request.contentId}:${request.nonce}';
    final wire = WireEnvelope.groupContentRequest(
      requestJson,
    ).withFrameId(frameId).encode();
    await _storage.enqueueOutboxFrame(frameId, dst.hex, wire);
    _outbox.recordQueued(frameId, dst.hex);
    unawaited(() async {
      try {
        await _send(dst, wire);
      } catch (_) {
        // Mailbox copy + outbox re-drive remain authoritative.
      }
    }());
    _stashInBackground(dst, frameId, wire);
  }

  /// Send one already-signed+epoch-encrypted group-call signal. Lifecycle
  /// transitions are durable for short outage tolerance; heartbeats are live
  /// only so stale liveness work never accumulates in an outbox/mailbox.
  Future<void> sendGroupCallSignal(
    NodeId dst,
    GroupCallSignal signal,
    String frameJson,
  ) async {
    final envelope = WireEnvelope.groupCallSignal(
      frameJson,
      sentAtMs: signal.sentAtMs,
    );
    // Group-call control rides the REALTIME IPC connection, mirroring
    // sendCallSignal below. It previously went through _send (the MAIN
    // client), where ring/join/heartbeat queued behind mailbox drains,
    // anonymous sends and file streams on the node's sequential
    // per-connection loop — the same head-of-line class that stalled call
    // media for seconds until media got its own connection (2026-07-17).
    if (signal.type == GroupCallSignalType.heartbeat) {
      try {
        await _sendRealtime(dst, envelope.encode());
      } catch (_) {
        // A subsequent heartbeat supersedes this best-effort frame.
      }
      return;
    }
    await sendDurable(
      dst,
      'gcall:${signal.groupId.hex}:${signal.callId}:'
      '${signal.type.name}:${signal.nonce}',
      envelope,
      liveSender: (wire) => _sendRealtime(dst, wire),
      awaitLive: false,
    );
  }

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

  List<Map<String, Object>> debugGroupServeGrants() =>
      _groupContent.debugGroupServeGrants();

  /// Ship a group snapshot to [dst] durably, chunking oversized bundles.
  Future<void> sendGroupSnapshot(
    NodeId dst,
    String groupIdHex,
    String bundleJson,
  ) => _replication.sendGroupSnapshot(dst, groupIdHex, bundleJson);

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

  void _emitIncoming(NodeId from, String preview, {required bool isFile}) {
    if (!_incoming.isClosed) {
      _incoming.add(
        IncomingNotice(from: from, preview: preview, isFile: isFile),
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

  Future<void> _sendRealtime(NodeId peer, Uint8List wire) =>
      _realtimeControl.sendRealtime(peer, wire);

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
  Future<void> _dispatch(InboundMessage m) async {
    final env = WireEnvelope.decode(m.payload);
    final existing = await _storage.getContact(m.src);
    if (existing?.status == ContactStatus.blocked) return; // drop blocked
    if (existing?.status == ContactStatus.accepted) {
      _realtimeControl.markAccepted(m.src);
    }

    // Durable-frame ack + dedup (generic, any kind): a frame sent via
    // [sendDurable] carries a frameId. Ack it so the sender retires it from its
    // outbox, and process it only ONCE — a re-drive (the sender never got our
    // ack, or we restarted) is re-acked but not re-processed. Consent-gated:
    // only accepted peers reach the durable handlers below.
    final fid = env.frameId;
    final deferredDocumentAck =
        env.kind == WireKind.cloudDocument ||
        env.kind == WireKind.cloudDocumentChunk;
    final deferredGroupCallAck = env.kind == WireKind.groupCallSignal;
    if (fid != null && deferredGroupCallAck && _outbox.hasSeen(fid)) {
      // This exact frame passed membership+AEAD+signature once already. A
      // re-drive means our prior ACK was lost; re-ACK without reprocessing.
      await _ackFrame(m, fid);
      return;
    }
    if (fid != null && existing?.status == ContactStatus.accepted) {
      if (deferredGroupCallAck) {
        // Authorization is the group frame itself, not ContactStatus. The
        // groupCallSignal switch arm ACKs only after the group layer accepts.
      } else if (deferredDocumentAck) {
        if (_outbox.hasSeen(fid)) {
          await _ackFrame(m, fid);
          return;
        }
      } else {
        await _ackFrame(m, fid);
        if (!_outbox.remember(fid)) {
          return; // already processed — re-acked above
        }
      }
    }

    switch (env.kind) {
      case WireKind.request:
        await _handleRequestOrReconnect(m, env, existing?.status);
      case WireKind.accept:
        // Only honour an accept for a request we actually sent.
        if (existing?.status == ContactStatus.pendingOutgoing) {
          await _setStatus(m.src, ContactStatus.accepted);
          // The durable-frame gate above only acks ACCEPTED senders — but an
          // accept is the very frame that CREATES that state, so the honoured
          // accept is acked here instead: the accepting side retires it from
          // its outbox. (A later duplicate finds us accepted and takes the
          // generic gate: re-acked + deduped there.)
          if (fid != null) {
            _outbox.remember(fid);
            await _ackFrame(m, fid);
          }
        } else {
          return;
        }
      case WireKind.message:
        // Consent gate: only deliver from accepted peers; drop the rest.
        if (existing?.status != ContactStatus.accepted) return;
        final id = env.id;
        if (isServiceEchoBody(env.body)) {
          if (id != null) await _ackTo(m, id, direct: true);
          return;
        }
        // [timeline] inbound receipt: id + whether it carried a reply path. id +
        // replyId only (no body) — lets us separate receive-latency from the ACK
        // round-trip when reading a session's logs.
        devLog(
          () =>
              'xVeil[timeline]: recv id=$id replyId=${m.replyId} '
              't=${DateTime.now().millisecondsSinceEpoch}',
        );
        // Dedup re-sent messages (the sender's local outbox re-sends un-acked
        // ones): if we already have this id, just re-ack so they stop.
        if (id != null && await _hasMessage(m.src, id)) {
          await _ackTo(m, id, direct: true);
          return;
        }
        // Deniability: if we DELETED this message, a re-delivery must NOT
        // resurrect it. Re-ack so the sender stops re-sending, then drop.
        if (id != null && await _storage.isMessageDeleted(m.src.hex, id)) {
          await _ackTo(m, id, direct: true);
          return;
        }
        // The peer's edit/delete of this message may have DRAINED FIRST (mailbox
        // blobs are unordered): when they sent then edited/unsent it while we
        // were offline, both deposits arrive on reconnect in arbitrary order.
        final pending = id == null ? null : _mutations.takePending(m.src, id);
        if (pending != null && pending.isDelete) {
          // Honor the unsend: store then tombstone so the message never shows AND
          // a later re-delivery is refused (isMessageDeleted above) — deniable
          // erasure, not a transient hide. No notification for an unsent message.
          await _store(
            m.src,
            MessageDirection.incoming,
            env.body,
            MessageStatus.delivered,
            id: id,
            timestamp: _wireSentAt(env),
            customEmoji: env.customEmoji,
          );
          await _storage.deleteMessage(m.src.hex, id!);
          await _storage.scrubDeleted();
          await _ackTo(m, id, direct: true);
          return;
        }
        // Apply a buffered edit by storing the edited body directly, so the
        // latest text shows on first paint (no flash of the superseded text, and
        // the original body never hits the container — nothing to scrub).
        final body = pending?.body ?? env.body;
        await _store(
          m.src,
          MessageDirection.incoming,
          body,
          MessageStatus.delivered,
          id: id,
          timestamp: _wireSentAt(env),
          replyToId: env.replyTo,
          forwardedFrom: env.forwardedFrom,
          customEmoji: pending == null ? env.customEmoji : pending.customEmoji,
          // Fold under the SENDER's seq (R4) so the (author, seq) is identical on
          // both devices — the basis for gap detection. Null from an older sender
          // → storage allocates locally (no cross-device convergence for them).
          seq: env.seq,
        );
        _emitIncoming(m.src, body, isFile: false);
        if (id != null) {
          await _ackTo(m, id);
        }
      case WireKind.ack:
        // Consent gate, like every other inbound arm: only an accepted contact
        // can flip our message state. Without this any non-blocked peer could
        // ack an arbitrary (guessed) id to forge a "delivered" mark and cancel
        // our retry backoff in any conversation. A legit ack only comes from a
        // peer we already accepted (we send messages — hence acks — only to them).
        // The peer confirms delivery of our message [env.id] — stop re-sending.
        final ackId = env.id;
        if (existing?.status != ContactStatus.accepted &&
            (ackId == null || !await _authorizedGroupCallAck(m.src, ackId))) {
          return;
        }
        if (ackId != null) {
          // Retire a durable control frame the peer just confirmed (sign, edit,
          // del, clear, accept, reconnect): stop re-driving + re-stashing it.
          // A no-op when ackId is an ordinary message id (not in the outbox).
          _retireOutboxFrame(ackId);
          // Idempotent: the peer's drain re-acks every cycle until its relay
          // blob ages out, so duplicate acks arrive in a storm. Mark delivered +
          // log + write storage only ONCE per id — re-doing it on every dup was
          // hammering the store (the user-visible "storage opens slowly").
          if (_messageDelivery.noteAck(m.src.hex, ackId)) {
            // [timeline] sender-side "delivered" moment — pair with the send t0
            // to get the full perceived round-trip. id + time only.
            devLog(
              () =>
                  'xVeil[timeline]: delivered id=$ackId '
                  't=${DateTime.now().millisecondsSinceEpoch}',
            );
            // Scope by the sender's conversation (m.src.hex) so the status can
            // only land on a message that lives in THIS peer's chat.
            await _storage.markMessageStatus(
              m.src.hex,
              ackId,
              MessageStatus.delivered,
            );
          }
        }
      case WireKind.edit:
        // The peer edited a message THEY sent us. Apply only to an INCOMING
        // message we hold from this peer — a peer must never be able to rewrite
        // our own outgoing messages (the id travels on the wire, so they know
        // it; the direction check is the real authorization gate).
        if (existing?.status != ContactStatus.accepted) return;
        await _mutations.applyIncomingEdit(m.src, env);
      case WireKind.del:
        // The peer unsent a message THEY sent us — purge + scrub our copy too.
        // Same authorization gate: only their incoming messages, never ours.
        if (existing?.status != ContactStatus.accepted) return;
        // Receiver policy: a contact we've forbidden from deleting-at-us has its
        // unsend DECLINED — our copy stays. Buffering is skipped too, so an
        // out-of-order del can't apply once the message lands. No oracle: the
        // peer is never told the delete was ignored.
        if (existing?.allowPeerDelete == false) return;
        final delId = env.id;
        if (delId == null) break;
        await _mutations.applyIncomingDelete(m.src, delId);
      case WireKind.sync:
        // Event-log gap-fill beacon (§15, 3c): the peer tells us what it holds
        // per author; we re-ship every event it is missing above its high-water.
        // Consent-gated (R2) — never reconcile a conversation with a non-accepted
        // node. We also beacon back so the peer heals OUR gaps in the same round.
        if (existing?.status != ContactStatus.accepted) return;
        await _handlePeerSync(m.src, env.body);
        return;
      case WireKind.voidSeq:
        // An inert seq placeholder from the peer's gap-fill: record the void slot
        // so our high-water for the peer's stream advances past a deleted/
        // superseded event it never delivered (renders nothing, no resurrection).
        if (existing?.status != ContactStatus.accepted) return;
        final vseq = env.seq;
        if (vseq != null) {
          await _storage.applyRemoteVoid(m.src.hex, m.src.hex, vseq);
        }
        return;
      case WireKind.clear:
        // The peer CLEARED the conversation up to a per-author seq watermark
        // (clear-for-everyone). Consent-gated (R2); the author is bound to the
        // AUTHENTICATED sender (R1, m.src). v1 policy: an accepted contact's clear
        // is APPLIED (the "delete for everyone" the sender intends) — a future
        // per-contact toggle can decline it; and once multi-device lands, a clear
        // from our OWN identity is authoritative for our devices the same way.
        if (existing?.status != ContactStatus.accepted) return;
        // Same receiver policy as del: a forbidden contact can't clear our copy.
        if (existing?.allowPeerDelete == false) return;
        final cseq = env.seq;
        if (cseq != null) {
          Map<String, int> wm;
          try {
            final raw = jsonDecode(env.body);
            wm = raw is Map
                ? raw.map((k, v) => MapEntry(k as String, v as int))
                : <String, int>{};
          } catch (_) {
            return; // malformed watermark → drop
          }
          await _storage.applyRemoteClear(m.src, m.src.hex, cseq, wm);
          _signal();
        }
        return;
      case WireKind.fileQuery:
        // A gap-fill probe for a file (§15 3c, resumable): the peer still holds
        // file <tid> and asks what we're missing. Reply with a fileNack naming
        // the gaps (or "all" if we hold no chunk yet). The peer then re-sends only
        // those chunks, instead of re-pushing the whole blob each round.
        if (existing?.status != ContactStatus.accepted) return;
        await _fileTransfer.handleQuery(m, parseFileMeta(env.body));
        return;
      case WireKind.fileNack:
        // The receiver lists the chunks it still needs of a file WE sent
        // (null = all). Re-send only those, rate-limited per (peer, transfer) so
        // a NACK flood can't drive a re-send storm.
        if (existing?.status != ContactStatus.accepted) return;
        final nack = parseFileNack(env.body);
        await _fileTransfer.handleNack(m.src, nack.transferId, nack.missing);
        return;
      case WireKind.reconnect:
        // "We were connected — re-establish." Treated exactly like a request: a
        // peer who wiped its chat data (Case-A) no longer holds us, so our normal
        // messages/beacons hit its consent gate and drop; this re-intros us so it
        // can re-accept. Disambiguated by OUR state in _handleRequestOrReconnect
        // (accepted→re-ack; unknown/pending→pending intro; blocked→already
        // dropped). Falls through to _signal() so the pending surfaces in the UI.
        await _handleRequestOrReconnect(m, env, existing?.status);
      case WireKind.fileStream:
        // Reserved abandoned push-stream prototype. No production sender ever
        // emitted this kind; the shipped any-size path is contentManifest + a
        // receiver-initiated content-id-bound pull stream. Reusing the same
        // accept loop for a pushed blob would create an ambiguous protocol and
        // bypass manifest/hash/opt-in checks, so legacy experimental frames stay
        // an authenticated, consent-gated silent drop. Keep the enum slot so all
        // later wire indices remain stable.
        if (existing?.status != ContactStatus.accepted) return;
        devLog(
          () =>
              'xVeil[recv]: reserved fileStream frame '
              '${parseFileMeta(env.body).transferId} — dropped',
        );
        return;
      case WireKind.contentManifest:
        // A peer advertises a content manifest (the "torrent"): verify it,
        // register a transfer, request the pieces we lack.
        if (existing?.status != ContactStatus.accepted) {
          final groupCid = _groupScopedManifestContentId(env.body);
          if (groupCid != null && _groupPullSourceAllowed(m.src, groupCid)) {
            await _onGroupContentManifest(m.src, env.body);
            return;
          }
          devLog(
            () =>
                'xVeil[content]: manifest DROPPED — ${m.src.short} '
                'not accepted (status=${existing?.status})',
          );
          return;
        }
        devLog(
          () =>
              'xVeil[content]: manifest frame ${env.body.length}B '
              '<- ${m.src.short}',
        );
        await _onContentManifest(m.src, env.body);
        return;
      case WireKind.contentReoffer:
        // A peer lost the manifest handle (restart) but still holds the offer —
        // re-advertise if we are still serving (or can re-open a durable source).
        if (existing?.status != ContactStatus.accepted) return;
        await _onContentReoffer(m.src, env.body);
        return;
      case WireKind.contentGone:
        // A holder answered a reoffer with "I no longer have those bytes" —
        // stop retrying against them and, once no source remains, surface the
        // terminal ask-for-a-re-send state instead of spinning forever.
        if (existing?.status != ContactStatus.accepted) return;
        await _onContentGone(m.src, env.body);
        return;
      case WireKind.pieceRequest:
        // A peer asks for pieces of content we serve — send the requested
        // pieces as chunks (paced).
        if (existing?.status != ContactStatus.accepted) return;
        _onPieceRequest(m.src, parsePieceRequest(env.body));
        return;
      case WireKind.pieceChunk:
        // One chunk of one piece: buffer + verify-on-complete; finish the
        // transfer when every piece is verified.
        if (existing?.status != ContactStatus.accepted) return;
        await _onPieceChunk(parsePieceChunk(env.body));
        return;
      case WireKind.signRequest:
        // A peer asks us to attest authorship of one of OUR messages. Consent-
        // gated; the policy (ask / auto / refuse) decides what happens next.
        if (existing?.status != ContactStatus.accepted) return;
        await _onSignRequest(m.src, env);
        return;
      case WireKind.signResponse:
        // The author answered our signature request — verify + record.
        if (existing?.status != ContactStatus.accepted) return;
        await _onSignResponse(m.src, env);
        return;
      case WireKind.callSignal:
        // Call control plane (voice/video/screen). Consent-gated; a durable
        // signal was already acked+deduped by the generic frame gate above.
        // Forward the decoded signal to the attached call service (dropped when
        // none is attached — e.g. a headless/loopback context).
        if (existing?.status != ContactStatus.accepted) return;
        final callSig = CallSignal.tryDecode(env.body);
        if (callSig != null) {
          devLog(() {
            final at = callSig.sentAtMs;
            final age = at == null
                ? 'n/a'
                : '${_now().millisecondsSinceEpoch - at}ms';
            return 'xVeil[call-sig]: in type=${callSig.type.name} '
                'call=${callSig.callId} from=${m.src.short} age=$age';
          });
          onCallSignal?.call(m.src, callSig);
        }
        return;
      case WireKind.p2pEndpoints:
        // A contact shared its direct dial endpoints (P2P epic). Consent-gated
        // at transport admission; the endpoint service re-checks the local P2P
        // policy (mutual consent) before acting on or answering it.
        if (existing?.status != ContactStatus.accepted) return;
        devLog(
          () =>
              'xVeil[p2p]: in endpoints from=${m.src.short} '
              '(${env.body.length} B)',
        );
        onP2PEndpoints?.call(m.src, env.body);
        return;
      case WireKind.reaction:
        // The peer reacted to a message in THIS conversation. A side annotation
        // (not an event-log event); the durable frame was already acked+deduped
        // by the generic gate above. Reactor = the authenticated sender.
        if (existing?.status != ContactStatus.accepted) return;
        final targetId = env.id;
        if (targetId == null) return;
        await _applyReaction(m.src.hex, targetId, m.src.hex, env.body);
        _signal();
        return;
      case WireKind.groupEntry:
        // A group snapshot from a member (groups epic); the durable frame was
        // already acked+deduped above. From an accepted contact it ingests as
        // always; from a NON-contact it goes through the guarded stranger
        // path (existing group + sender is a member — scale-free log sync).
        if (existing?.status == ContactStatus.accepted) {
          onGroupEntry?.call(m.src, env.body);
        } else {
          onGroupEntryFromStranger?.call(m.src, env.body);
        }
        return;
      case WireKind.groupEntryChunk:
        // One slice of an oversized snapshot (inline group media). Already
        // acked/deduped above. Reassemble by transferId; once every chunk is
        // present, ingest the joined bundle exactly like a whole groupEntry.
        // A NON-contact's chunk must pass the membership admission BEFORE any
        // reassembly RAM is spent on it.
        if (existing?.status == ContactStatus.accepted) {
          _ingestGroupChunk(m.src, env.body);
        } else {
          await _ingestStrangerGroupChunk(m.src, env.body);
        }
        return;
      case WireKind.groupContentRequest:
        // A signed membership-authorized fetch request (groups content path).
        // Deliberately NOT contact-gated: the signature + membership proof
        // inside is the authorization; the group layer verifies against its
        // own folded state and grants (or silently drops — no oracle).
        onGroupContentRequest?.call(m.src, env.body);
        return;
      case WireKind.groupCallSignal:
        // No contact gate: current group membership + epoch AEAD + node-bound
        // signature are the authorization. Invalid/removed/stale senders are
        // silently dropped by the group layer (no membership/read oracle).
        final accepted =
            await onGroupCallSignal?.call(m.src, env.body) ?? false;
        if (accepted && fid != null) {
          await _ackFrame(m, fid);
          _outbox.remember(fid);
        }
        return;
      case WireKind.chatDeleted:
        // The peer deleted this conversation on their device and explicitly
        // opted into telling us. Accepted contacts only (a stranger/pending
        // peer gets the usual silent drop — no oracle); the durable frame was
        // already acked+deduped by the generic gate above. Leave a LOCAL
        // system-notice marker in the chat via the normal store path, so
        // unread/notification behave like any incoming event.
        if (existing?.status != ContactStatus.accepted) return;
        await _store(
          m.src,
          MessageDirection.incoming,
          kChatDeletedMarkerBody,
          MessageStatus.delivered,
          // Fall back to receive time: an unstamped marker would sort into
          // the middle of the chat instead of closing it.
          timestamp: _wireSentAt(env) ?? _now(),
          // A LOCAL annotation, not an event from the sender's (just wiped)
          // log — see [_store.selfAuthored] for the ordering rationale.
          selfAuthored: true,
        );
        _emitIncoming(m.src, '🗑️', isFile: false);
        return;
      case WireKind.cloudDocument:
        if (existing?.status != ContactStatus.accepted) return;
        if (await _deliverCloudDocumentFrame(m.src, env.body)) {
          await _ackTerminalDocumentFrame(m, fid);
        }
        return;
      case WireKind.cloudDocumentChunk:
        if (existing?.status != ContactStatus.accepted) return;
        await _ingestCloudDocumentChunk(m, env.body, fid);
        return;
      case WireKind.unknown:
        // A structured (v:2) frame from a NEWER build whose kind we don't know —
        // the decoder already mapped it to this drop sentinel (RULE WC). Ignore.
        return;
      case WireKind.fileMeta:
        if (existing?.status != ContactStatus.accepted) {
          devLog(
            () =>
                'xVeil[recv]: fileMeta DROPPED — ${m.src.short} '
                'not accepted (status=${existing?.status})',
          );
          return;
        }
        await _fileTransfer.handleMeta(m, parseFileMeta(env.body));
        return;
      case WireKind.fileChunk:
        if (existing?.status != ContactStatus.accepted) {
          devLog(
            () =>
                'xVeil[recv]: fileChunk DROPPED — ${m.src.short} '
                'not accepted (status=${existing?.status})',
          );
          return;
        }
        await _fileTransfer.handleChunk(m, parseFileChunk(env.body));
        return;
    }
    _signal();
  }

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

  Future<void> setContactMutedUntil(NodeId peer, DateTime? until) =>
      _conversationAdmin.setContactMutedUntil(peer, until);

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

  /// Persist [bytes] as a streamed (uncapped) blob keyed by the manifest's
  /// contentId — the SAME on-disk piece layout the receiver builds — so the
  /// sender SERVES it from disk ([readFileRange]) without holding it in RAM and
  /// without the whole-file [storeFile] cap (which is what bounded send size).
  /// Idempotent: a blob already present (a re-send / re-advertise of identical
  /// bytes) is left as-is, so the de-dup store happens at most once.
  Future<void> _storeServedBlob(
    ContentManifest manifest,
    Uint8List bytes,
  ) async {
    final cid = manifest.contentId;
    if (await _storage.hasFile(cid)) return;
    for (var p = 0; p < manifest.pieceCount; p++) {
      final start = p * manifest.pieceSize;
      final end = start + manifest.pieceLength(p);
      await _storage.storeFilePiece(
        cid,
        p,
        manifest.pieceCount,
        manifest.pieceSize,
        bytes.length,
        Uint8List.sublistView(bytes, start, end),
        name: manifest.name,
      );
    }
  }

  /// Register [manifest] for serving and advertise it to [dst]. The bytes are
  /// read on request either from [source] (a large send, served straight from the
  /// user's original file) or — when [source] is null — from the on-disk blob
  /// store keyed by contentId. Shared tail of every advertise path. A prior
  /// [source] for this contentId is closed if we replace it (no leaked handle).
  static const int _contentManifestInlineEnvelopeLimit = 5600;

  String _contentManifestJson(ContentManifest manifest) =>
      jsonEncode(manifest.toJson());

  String _contentManifestRefJson(ContentManifest manifest) => jsonEncode({
    'ref': 1,
    'id': manifest.contentId,
    'name': manifest.name,
    'size': manifest.size,
    if (manifest.msgId != null) 'mid': manifest.msgId,
    if (manifest.author != null) 'au': manifest.author,
    if (manifest.seq != null) 'sq': manifest.seq,
    if (manifest.ts != null) 'mts': manifest.ts,
    // Embedded micro-thumb (unbound, budget-bound at generation) — rides the
    // ref too so an over-limit full manifest still delivers the preview.
    if (manifest.thumbB64 != null) 'th': manifest.thumbB64,
  });

  _ContentManifestRef? _parseContentManifestRef(Map<String, dynamic> j) {
    try {
      if (j['ref'] != 1) return null;
      final id = j['id'] as String;
      final name = j['name'] as String;
      final size = j['size'] as int;
      if (id.length != 64 || size < 0) return null;
      return (
        contentId: id,
        name: name,
        size: size,
        msgId: j['mid'] as String?,
        author: j['au'] as String?,
        seq: j['sq'] as int?,
        ts: j['mts'] as int?,
        thumb: j['th'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Live-send the manifest frame for [manifest] and return the exact bytes
  /// sent (inline full manifest when it fits, else the compact ref frame) so
  /// the caller can also deposit them for offline delivery.
  Future<Uint8List> _sendContentManifest(
    NodeId dst,
    ContentManifest manifest,
  ) async {
    final encoded = _encodeContentManifest(manifest);
    await _send(dst, encoded.frame);
    if (encoded.inline) {
      devLog(
        () =>
            'xVeil[content]: manifest inline '
            '${manifest.contentId.substring(0, 12)} '
            'frame=${encoded.frame.length}B -> ${dst.short}',
      );
    } else {
      devLog(
        () =>
            'xVeil[content]: manifest ref '
            '${manifest.contentId.substring(0, 12)} '
            'full_frame=${encoded.fullLength}B '
            'ref_frame=${encoded.frame.length}B -> ${dst.short}',
      );
    }
    return encoded.frame;
  }

  ({Uint8List frame, int fullLength, bool inline}) _encodeContentManifest(
    ContentManifest manifest,
  ) {
    final fullJson = _contentManifestJson(manifest);
    final fullFrame = contentManifestEnvelope(fullJson).encode();
    if (fullFrame.length <= _contentManifestInlineEnvelopeLimit) {
      return (frame: fullFrame, fullLength: fullFrame.length, inline: true);
    }
    final refJson = _contentManifestRefJson(manifest);
    final refFrame = contentManifestEnvelope(refJson).encode();
    return (frame: refFrame, fullLength: fullFrame.length, inline: false);
  }

  Future<void> _advertiseStored(
    NodeId dst,
    ContentManifest manifest, {
    ServeSource? source,
  }) async {
    final cid = manifest.contentId;
    final serveManifest = _baseContentManifest(manifest);
    final prev = _serving[cid];
    if (prev?.source != null &&
        source != null &&
        !_sameServeSource(prev!.source!, source)) {
      _retireServeSourceForContent(cid, prev.source!);
    } else if (prev?.source != null && source == null) {
      _retireServeSourceForContent(cid, prev!.source!);
    }
    _serving[cid] = (manifest: serveManifest, source: source, servedAt: _now());
    await _persistServeManifest(serveManifest);
    _evictServing();
    _ensureContentTimer();
    final mid = manifest.msgId;
    Uint8List frame;
    Object? liveError;
    StackTrace? liveStack;
    try {
      frame = await _sendContentManifest(dst, manifest);
    } catch (error, stack) {
      // A dead live route is exactly when the mailbox copy matters. Build the
      // same frame locally and persist it before returning; the previous order
      // threw before `_maybeStash`, making the documented offline fallback a
      // false guarantee.
      frame = _encodeContentManifest(manifest).frame;
      liveError = error;
      liveStack = stack;
    }
    // Offline fallback for the OFFER itself. The manifest was previously
    // live-only: on a flaky/down live path a plain text (which stashes) still
    // arrived while the file offer silently vanished — the reported "file
    // never came, other messages did". Deposit the exact manifest frame at the
    // recipient's mailbox, keyed by THIS send's msgId so a live + drained copy
    // dedup by event identity. Only for real event sends (msgId present) — the
    // bare content API advertises without an event and must not spam mailboxes.
    // Best-effort + non-blocking, exactly like the text path.
    if (mid != null) {
      if (liveError == null) {
        _stashInBackground(dst, 'mf:$mid', frame);
      } else {
        await _maybeStash(dst, 'mf:$mid', frame);
      }
    } else if (liveError != null) {
      Error.throwWithStackTrace(liveError, liveStack!);
    }
    devLog(
      () =>
          'xVeil[content]: advertise ${manifest.contentId.substring(0, 12)} '
          '(${manifest.pieceCount} pieces'
          '${mid != null ? ', msg ${mid.substring(0, 8)}' : ''}) -> ${dst.short}',
    );
  }

  /// Parsed `served:$cid` record. Legacy records are a bare path string; new
  /// ones are JSON `{path,size,pieceSize,name}` so the manifest can be
  /// rebuilt from the source file when the mf: blob is missing (its persist
  /// dies first on a bloated store — IndexFull).
  ({String path, int? size, int? pieceSize, String? name})? _parseServedRecord(
    String? raw,
  ) {
    if (raw == null || raw.isEmpty) return null;
    if (!raw.startsWith('{')) {
      return (path: raw, size: null, pieceSize: null, name: null);
    }
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final path = m['path'] as String?;
      if (path == null || path.isEmpty) return null;
      return (
        path: path,
        size: (m['size'] as num?)?.toInt(),
        pieceSize: (m['pieceSize'] as num?)?.toInt(),
        name: m['name'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Rebuild the manifest of a durable offer by re-hashing the source file at
  /// [rec]'s path (one RAM-bounded pass — the same work the original send
  /// did, ~150 ms for 20 MB). Used when the mf: blob is missing: its persist
  /// is the first casualty of a bloated store (IndexFull), and without this a
  /// restarted sender answered UNSERVED/GONE forever while the bytes sat on
  /// disk. Returns null when the record lacks hashing params (legacy bare
  /// path), the file is gone, or its bytes changed (contentId mismatch).
  Future<ContentManifest?> _rebuildManifestFromServedRecord(
    String cid,
    ({String path, int? size, int? pieceSize, String? name}) rec,
  ) async {
    final opener = sourceOpener;
    final size = rec.size;
    final pieceSize = rec.pieceSize;
    if (opener == null || size == null || pieceSize == null) return null;
    final src = await opener(rec.path);
    if (src == null) return null;
    try {
      final m = await ContentManifest.fromReader(
        name: rec.name ?? 'file',
        size: size,
        pieceSize: pieceSize,
        chunkBytes: _contentChunkBytes,
        readRange: src.read,
      );
      if (m.contentId != cid) {
        devLog(
          () =>
              'xVeil[content]: served source at ${rec.path} no longer '
              'matches ${cid.substring(0, 12)} — treating as gone',
        );
        return null;
      }
      devLog(
        () =>
            'xVeil[content]: manifest rebuilt from source for '
            '${cid.substring(0, 12)} (${m.pieceCount} pieces)',
      );
      unawaited(_persistServeManifest(m)); // best-effort re-persist
      return m;
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: manifest rebuild failed for '
            '${cid.substring(0, 12)}: $e',
      );
      return null;
    } finally {
      try {
        await src.close();
      } catch (_) {}
    }
  }

  Future<void> _persistServeManifest(ContentManifest manifest) async {
    try {
      await _storage.storeFile(
        'mf:${manifest.contentId}',
        Uint8List.fromList(utf8.encode(_contentManifestJson(manifest))),
        name: 'manifest',
      );
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: serve-manifest persist failed '
            '${manifest.contentId.substring(0, 12)}: $e',
      );
    }
  }

  bool _sameServeSource(ServeSource a, ServeSource b) =>
      _contentServing.sameSource(a, b);

  void _retireServeSourceForContent(String cid, ServeSource source) =>
      _contentServing.retireForContent(cid, source);

  /// Persist [bytes] to the blob store (streamed pieces) and advertise. One
  /// source of truth for the in-RAM serve+advertise tail (the bare-content API
  /// and the in-RAM message path); [bytes] is not retained past the store.
  Future<void> _advertise(
    NodeId dst,
    ContentManifest manifest,
    Uint8List bytes,
  ) async {
    try {
      await _storeServedBlob(manifest, bytes);
    } catch (e) {
      devLog(
        () => 'xVeil[content]: serve-store failed for ${manifest.name}: $e',
      );
    }
    await _advertiseStored(dst, manifest);
  }

  /// Offer [bytes] as a bare content transfer to [dst] (no chat message / event
  /// identity): build the manifest, serve it, advertise it. Returns the contentId
  /// (the bytes' self-authenticating address). Used by tests + the recovery
  /// re-ship; user file sends go through [_sendAsContent] (which adds the event).
  Future<String> sendContent(NodeId dst, Uint8List bytes, String name) async {
    final manifest = ContentManifest.fromBytes(
      name,
      bytes,
      pieceSize: adaptivePieceSize(bytes.length),
      chunkBytes: _contentChunkBytes,
    );
    final contact = await _storage.getContact(dst);
    if (contact?.status == ContactStatus.accepted) {
      await _advertise(dst, manifest, bytes);
    }
    return manifest.contentId;
  }

  ContentManifest _baseContentManifest(ContentManifest manifest) =>
      ContentManifest(
        name: manifest.name,
        size: manifest.size,
        pieceSize: manifest.pieceSize,
        pieceHashes: manifest.pieceHashes,
        contentId: manifest.contentId,
        chunkBytes: manifest.chunkBytes,
      );

  /// Share an already-stored content-addressed blob as a NEW filePost without
  /// loading or duplicating its bytes. The cloud layer uses this path: the
  /// manifest and blob remain keyed by the same cid, while this recipient gets
  /// a fresh message/event identity and the normal consent-gated offer flow.
  Future<bool> shareStoredContent(NodeId dst, String contentId) async {
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) {
      return false;
    }
    if (!await _storage.hasFile(contentId)) return false;
    final persisted = await _loadPersistedManifest(contentId);
    if (persisted == null) return false;
    _mailboxDelivery.noteActivity();
    _warmStreamPeer(dst);

    // Strip any old per-send fields: a cid can be shared repeatedly and each
    // recipient must get a distinct filePost, while the immutable byte
    // manifest remains identical.
    final base = _baseContentManifest(persisted);
    final msgId = _uuid.v4();
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      '📎 ${base.name}',
      MessageStatus.sent,
      fileId: contentId,
      fileName: base.name,
      fileSize: base.size,
      thumb: base.thumbB64,
      id: msgId,
      timestamp: _now(),
    );
    _signal();
    await _advertiseStored(
      dst,
      base.withEvent(
        msgId: msgId,
        author: stored.author,
        seq: stored.seq,
        ts: stored.timestamp.millisecondsSinceEpoch,
        thumbB64: base.thumbB64,
      ),
    );
    return true;
  }

  /// Send a VOICE MESSAGE: the Opus clip [bytes] ride the content layer exactly
  /// like a small file (content-addressed, auto-downloaded under the receiver's
  /// cap), named `.opus` so both ends render a voice bubble. The clip's
  /// [durationMs] + [waveform] travel in the SAME `thumb` sidecar image
  /// micro-thumbs use (tagged `vw1:`), so nothing new crosses the wire. Gated to
  /// accepted contacts inside [_sendAsContent].
  Future<void> sendVoice(
    NodeId dst,
    Uint8List bytes,
    int durationMs,
    List<double> waveform, {
    String? lang,
  }) async {
    _mailboxDelivery.noteActivity(); // user action → mailbox burst window
    _warmStreamPeer(dst);
    // Carry the SENDER's language in the sidecar so the receiver transcribes in
    // the spoken language, not their own locale.
    final sidecar = encodeVoiceSidecar(durationMs, waveform, lang: lang);
    final name = '${_uuid.v4()}$kVoiceFileExt';
    await _sendAsContent(dst, bytes, name, thumbOverride: sidecar);
  }

  /// Send a VIDEO NOTE (round message): the VNOTE1 clip [bytes] ride the
  /// content layer like a small file, named `.vnote` so both ends render the
  /// round bubble. Duration + the first-frame micro-thumb travel in the same
  /// `thumb` sidecar (tagged `vn1:`) — the receiver renders BEFORE/without
  /// downloading. Gated to accepted contacts inside [_sendAsContent].
  Future<void> sendVideoNote(
    NodeId dst,
    Uint8List bytes,
    int durationMs, {
    String? thumbB64,
  }) async {
    _mailboxDelivery.noteActivity(); // user action → mailbox burst window
    _warmStreamPeer(dst);
    final sidecar = encodeVnoteSidecar(durationMs, thumbB64);
    final name = '${_uuid.v4()}$kVnoteFileExt';
    await _sendAsContent(dst, bytes, name, thumbOverride: sidecar);
  }

  /// Send a STICKER: the image [bytes] ride the content path under `.stkr`
  /// (auto-downloaded under the receiver's cap), with an ordinary image
  /// micro-thumb in the sidecar so the receiver previews it instantly. The
  /// extension makes both ends render it naked (no bubble chrome).
  Future<void> sendSticker(NodeId dst, Uint8List bytes) async {
    _mailboxDelivery.noteActivity();
    _warmStreamPeer(dst);
    final thumb = await _imageThumbMaker(bytes);
    final name = '${_uuid.v4()}$kStickerFileExt';
    await _sendAsContent(dst, bytes, name, thumbOverride: thumb);
  }

  /// Send a shared STICKER PACK: the STKP1 [blob] rides the content path under
  /// `.stkpack` so the receiver gets an install card. A thumb of the first
  /// sticker ([firstThumbB64]) previews it before download.
  Future<void> sendStickerPack(
    NodeId dst,
    Uint8List blob, {
    String? firstThumbB64,
  }) async {
    _mailboxDelivery.noteActivity();
    _warmStreamPeer(dst);
    final name = '${_uuid.v4()}$kStickerPackFileExt';
    await _sendAsContent(dst, blob, name, thumbOverride: firstThumbB64);
  }

  /// Send a LARGE file via the content layer as a first-class filePost EVENT.
  /// The BYTES are content-addressed (stored + served by contentId, de-duped);
  /// the MESSAGE is a per-send event under a fresh [msgId] + the (author,seq) the
  /// log allocates — so a re-send (even of previously-DELETED content) surfaces
  /// as a NEW message (A), while identical bytes are never re-stored/re-fetched.
  Future<void> _sendAsContent(
    NodeId dst,
    Uint8List bytes,
    String name, {
    String? sourcePath,
    String? thumbOverride,
  }) async {
    // Micro-thumb: embedded in the ADVERT (unbound — not in contentId) so the
    // receiver renders a preview BEFORE downloading. [thumbOverride] wins when
    // set (a voice message's waveform+duration sidecar). Otherwise: images from
    // the in-RAM bytes; videos need the SOURCE PATH (the platform grabber
    // decodes from disk — bytes-only callers get no video thumb, deliberately:
    // writing a plaintext temp file just to grab a frame is not worth it). Null
    // for anything undecodable / over the datagram budget.
    String? thumb = thumbOverride;
    if (thumb == null && isImageFileName(name)) {
      thumb = await _imageThumbMaker(bytes);
    } else if (thumb == null && isVideoFileName(name) && sourcePath != null) {
      try {
        thumb = await _videoThumbMaker(sourcePath);
      } catch (e) {
        devLog(() => 'xVeil[content]: video thumb skipped for $name: $e');
      }
    }
    // Hash the file ONCE → the manifest + contentId (the blob key).
    final base = ContentManifest.fromBytes(
      name,
      bytes,
      pieceSize: adaptivePieceSize(bytes.length),
      chunkBytes: _contentChunkBytes,
    );
    final cid = base.contentId;
    // Store the blob under its HASH as streamed pieces (uncapped), de-duped: a
    // re-send of identical bytes keeps ONE copy, and a receiver that already
    // holds it skips the re-download. ([_advertise] would also ensure-store, but
    // do it here too so a send to a not-yet-accepted contact still retains the
    // local copy for a later re-ship.)
    try {
      await _storeServedBlob(base, bytes);
    } catch (e) {
      devLog(() => 'xVeil[content]: local store failed for $name: $e');
    }
    // Fresh per-send msgId = a NEW event each send (the (author,seq) event is the
    // identity, NOT the byte-hash → re-send surfaces, even after a delete).
    // fileId = contentId binds the message to its hash-keyed blob.
    final msgId = _uuid.v4();
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      '📎 $name',
      MessageStatus.sent,
      fileId: cid,
      fileName: name,
      thumb: thumb,
      id: msgId,
      timestamp: _now(),
    );
    _signal();
    // Advertise carrying THIS send's event identity so the receiver folds a
    // first-class filePost and acks by msgId (not the shared contentId).
    final contact = await _storage.getContact(dst);
    if (contact?.status != ContactStatus.accepted) return;
    await _advertise(
      dst,
      base.withEvent(
        msgId: msgId,
        author: stored.author,
        seq: stored.seq,
        thumbB64: thumb,
      ),
      bytes,
    );
  }

  /// Send a LARGE file by SERVING IT STRAIGHT FROM THE SOURCE — the user's
  /// original file on disk — with no stored or encrypted copy. [read] returns
  /// [length] bytes at [offset] of the source; [close] releases its handle when
  /// serving ends; [size] is the total. The sender already HAS the file, so
  /// keeping a copy would (a) duplicate it — 2× disk for a TB attachment — and
  /// (b) be exactly what overflowed the hidden-volume index on a big send. So we
  /// only HASH the source (one RAM-bounded pass → the manifest), record the
  /// filePost, and register the live source for serving; [_serveChunks] then
  /// reads each requested chunk from it on demand. Same content layer + contentId
  /// as the in-RAM path (so a streamed and an in-RAM send of the same bytes still
  /// share a swarm address). The source is owned by [_serving] and closed on
  /// eviction/dispose — the UI must NOT close it after this returns.
  Future<String?> sendFileStreaming(
    NodeId dst,
    String name,
    int size,
    Future<Uint8List> Function(int offset, int length) read, {
    required Future<void> Function() close,
    String? sourcePath,
  }) async {
    final contact = await _storage.getContact(dst);
    if (contact == null || contact.status != ContactStatus.accepted) {
      await close(); // not serving this peer → release the handle now
      return null;
    }
    _mailboxDelivery.noteActivity(); // user action → mailbox burst window
    // The recipient will pull from us shortly — open our serve pool now, in
    // parallel with the piece hashing below.
    _warmStreamPeer(dst);
    final sw = Stopwatch()..start();
    devLog(
      () =>
          'xVeil[content]: stream-send start "$name" size=$size '
          '-> ${dst.short}',
    );
    // Hash the source piece-by-piece → manifest (contentId + per-piece hashes).
    // Holds at most one piece in RAM; on failure release the handle + surface.
    final ContentManifest base;
    try {
      base = await ContentManifest.fromReader(
        name: name,
        size: size,
        pieceSize: adaptivePieceSize(size),
        chunkBytes: _contentChunkBytes,
        readRange: read,
      );
      devLog(
        () =>
            'xVeil[content]: stream-send hashed "$name" '
            'pieces=${base.pieceCount} piece_size=${base.pieceSize} '
            'cid=${base.contentId.substring(0, 12)} '
            'in ${sw.elapsedMilliseconds}ms',
      );
    } catch (e) {
      await close();
      devLog(() => 'xVeil[content]: stream hash failed for $name: $e');
      rethrow;
    }
    final cid = base.contentId;
    // Streamed MEDIA extras — the source isn't in RAM, so read it once
    // (bounded) and reuse the buffer. Reads are serialized by the source's
    // gate.
    // 1. Micro-thumb for the message (images only, optional).
    // 2. A LOCAL piece-store copy for images AND videos under the cap, so
    //    the SENDER's own bubble works (inline preview / in-app playback —
    //    loadFile(cid) → pieces) instead of a dead download affordance: the
    //    no-local-copy rule exists for TB attachments, but sub-cap media
    //    costs pennies and viewing your own send is the whole point. Also
    //    keeps the serve alive even if the source file later moves away.
    String? thumb;
    // Video preview frame: grabbed by PLATFORM code straight from the source
    // path (no size cap — the grabber never reads the file into RAM), so even
    // a multi-GB video gets a bubble thumb. Best-effort: null on platforms
    // without a handler / undecodable containers → the play-icon row.
    if (isVideoFileName(name) && sourcePath != null) {
      try {
        thumb = await _videoThumbMaker(sourcePath);
      } catch (e) {
        devLog(() => 'xVeil[content]: video thumb skipped for $name: $e');
      }
    }
    final mediaCopy =
        (isImageFileName(name) || isVideoFileName(name)) &&
        size <= kThumbSourceReadCapBytes;
    if (mediaCopy) {
      try {
        final mediaBytes = await read(0, size);
        if (isImageFileName(name)) {
          thumb = await _imageThumbMaker(mediaBytes);
        }
        try {
          await _storeServedBlob(base, mediaBytes);
        } catch (e) {
          devLog(
            () =>
                'xVeil[content]: stream-send local copy skipped for '
                '$name: $e',
          );
        }
      } catch (e) {
        devLog(() => 'xVeil[content]: stream-send thumb skipped for $name: $e');
      }
    }
    // Fresh per-send msgId = a NEW filePost event (identity is (author,seq), not
    // the byte-hash → a re-send surfaces even after a delete). fileId = contentId.
    final msgId = _uuid.v4();
    final stored = await _store(
      dst,
      MessageDirection.outgoing,
      '📎 $name',
      MessageStatus.sent,
      fileId: cid,
      fileName: name,
      fileSize: size,
      thumb: thumb,
      id: msgId,
      timestamp: _now(),
    );
    devLog(
      () =>
          'xVeil[content]: stream-send stored offer '
          '${cid.substring(0, 12)} in ${sw.elapsedMilliseconds}ms',
    );
    _signal();
    final m = base.withEvent(
      msgId: msgId,
      author: stored.author,
      seq: stored.seq,
      thumbB64: thumb,
    );
    final activeExisting = (_activeStreamServes[cid] ?? 0) > 0
        ? _serving[cid]
        : null;
    final activeSource = activeExisting?.source;
    // DURABLE offer: persist the manifest + the source PATH so a reoffer after a
    // restart can re-open the file and re-serve (best-effort; the file must still
    // be at that path). The manifest exceeds the KV value cap → file store.
    if (sourcePath != null && activeSource == null) {
      // The path record and the manifest blob are persisted INDEPENDENTLY: on
      // a bloated store the file-store write dies with IndexFull while the
      // small KV setting still lands. The setting now carries the hashing
      // params too, so a post-restart serve can rebuild the manifest straight
      // from the source file when the mf: blob never made it (one RAM-bounded
      // hashing pass — the same work the original send did).
      try {
        await _storage.putSetting(
          'served:$cid',
          jsonEncode({
            'path': sourcePath,
            'size': size,
            'pieceSize': base.pieceSize,
            'name': name,
          }),
        );
      } catch (e) {
        devLog(
          () =>
              'xVeil[content]: durable-offer path persist failed for $cid: $e',
        );
      }
      try {
        await _storage.storeFile(
          'mf:$cid',
          Uint8List.fromList(utf8.encode(_contentManifestJson(m))),
          name: 'manifest',
        );
      } catch (e) {
        devLog(
          () => 'xVeil[content]: durable-offer persist failed for $cid: $e',
        );
      }
    } else if (sourcePath != null) {
      devLog(
        () =>
            'xVeil[content]: keep active source/path for '
            '${cid.substring(0, 12)} — same-content resend while streaming',
      );
    }
    if (activeSource != null) {
      // We only needed this newly-opened handle to hash/identify the resend. The
      // bytes are identical (same contentId), and an active stream is already
      // using the previous source/path; replacing it mid-flight can close or
      // invalidate the stream's file handle on Android file_picker cache paths.
      await close();
      await _advertiseStored(dst, m, source: activeSource);
    } else {
      // Register the live source + advertise — NO stored copy.
      await _advertiseStored(dst, m, source: (read: read, close: close));
    }
    devLog(
      () =>
          'xVeil[content]: stream-send advertised ${cid.substring(0, 12)} '
          'in ${sw.elapsedMilliseconds}ms',
    );
    return cid;
  }

  Future<void> _onContentManifest(NodeId peer, String body) async {
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final ref = _parseContentManifestRef(decoded);
    if (ref != null) {
      await _onContentManifestRef(peer, ref);
      return;
    }
    final m = ContentManifest.fromJson(decoded);
    if (m == null) {
      devLog(
        () => 'xVeil[content]: manifest DROPPED (malformed) <- ${peer.short}',
      );
      return; // malformed / not self-consistent → untrusted, drop
    }
    devLog(
      () =>
          'xVeil[content]: manifest parsed ${m.contentId.substring(0, 12)} '
          'pieces=${m.pieceCount} msg=${m.msgId?.substring(0, 8)} '
          '<- ${peer.short}',
    );
    // Surface the file as an OFFER first — metadata only (name/size + the
    // contentId to fetch), NO blob yet — idempotent on the sender's per-send
    // msgId. The receiver decides whether to download (anti-spam + disk control).
    await _surfaceFileOffer(peer, m);

    // We ALREADY hold these exact bytes (a re-offer / dedup) → the offer renders
    // as downloaded; ack so the sender flips sent->delivered.
    if (await _storage.hasFile(m.contentId)) {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} ALREADY HELD '
            '<- ${peer.short} (no re-download)',
      );
      await _send(peer, WireEnvelope.ack(m.msgId ?? m.contentId).encode());
      _signal();
      return;
    }
    // Already pulling it (a re-advertise mid-download) → keep the latest identity.
    if (_contentFetching.refreshManifest(peer, m)) {
      return;
    }
    // Retain the manifest so the user (or auto-download) can fetch on demand.
    _contentAvailability.rememberManifest(peer, m);

    // A fresh manifest proves the content is obtainable again — clear any
    // terminal "gone" mark before the resume driver looks at it.
    unawaited(_clearContentGone(m.contentId));
    // A durable (cross-restart) pending download exists for this content and
    // the holder just proved it's online — nudge the auto-resume driver.
    unawaited(_resumeOnOfferSignal(m.contentId, manifest: m));

    // A user download was PARKED waiting for this manifest (re-advertise after a
    // restart) → start it now with its destination (sink for unencrypted-to-file,
    // null for the encrypted tier), regardless of the auto-download policy.
    if (_contentAvailability.hasPending(m.contentId)) {
      final sink = _contentAvailability.takePending(m.contentId);
      devLog(
        () =>
            'xVeil[content]: re-advertised manifest arrived for '
            '${m.contentId.substring(0, 12)} — resuming the parked download',
      );
      final retryPeers = await _contentSourcePeers(
        preferred: peer,
        contentId: m.contentId,
      );
      if (sink != null) {
        // Explicit "save plaintext to this path" intent — stream it (default;
        // see _plainFileStreamDartDefine). The piece/chunk fetch below stays
        // as the automatic fallback when no stream can be opened at all.
        if (_plainFileStream &&
            await _pullSwarmStreamToFile(
              peer,
              m.contentId,
              m,
              retryPeers,
              sink,
              _fetchSavePath[m.contentId] ?? m.contentId,
            )) {
          return;
        }
        await _beginFetch(peer, m, sink: sink);
        return;
      } else {
        if (await _pullSwarmStream(peer, m.contentId, m, retryPeers)) {
          return;
        }
        if (await _pullStream(
          peer,
          m.contentId,
          null,
          retryPeers: retryPeers,
        )) {
          return;
        }
      }
      await _beginFetch(peer, m, sink: sink);
      return;
    }

    // A plaintext save/download has already been explicitly requested for this
    // content id (for example by the desktop save dialog or the soak hook).
    // Do not let the automatic encrypted-tier fetch race it: if auto-download
    // wins, the UI may mark the offer as downloaded while the user's chosen
    // destination file remains empty and waits forever for a savedPath
    // completion event.
    if (_fetchSavePath.containsKey(m.contentId)) {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} '
            'plain-file download pending — suppressing auto-download',
      );
      return;
    }

    if (_filePolicy.allowsAuto(m.size, m.name)) {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} '
            '(${m.size}B "${m.name}") <- ${peer.short} — auto-downloading (<= cap)',
      );
      await _beginFetch(peer, m);
    } else {
      devLog(
        () =>
            'xVeil[content]: ${m.contentId.substring(0, 12)} '
            '(${m.size}B "${m.name}") <- ${peer.short} — OFFERED (awaiting user)',
      );
    }
  }

  /// Parse and retain a holder advertisement that arrived through the
  /// membership-scoped group reply path. Unlike a normal 1:1 offer this must
  /// not materialise a direct-chat row, auto-download, or emit an ACK/read
  /// oracle. The already-running group fetch consumes the hint and still
  /// verifies the full content-addressed manifest and every piece.
  Future<void> _onGroupContentManifest(NodeId peer, String body) async {
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final ref = _parseContentManifestRef(decoded);
    if (ref != null) {
      final cid = ref.contentId;
      if (!_groupPullSourceAllowed(peer, cid)) return;
      _contentAvailability.rememberRef(peer, ref);
      devLog(
        () =>
            'xVeil[content]: group holder ref '
            '${cid.substring(0, 12)} <- ${peer.short}',
      );
      unawaited(_clearContentGone(cid));
      return;
    }
    final manifest = ContentManifest.fromJson(decoded);
    if (manifest == null ||
        !_groupPullSourceAllowed(peer, manifest.contentId)) {
      return;
    }
    _rememberOfferedManifest(peer, manifest);
    devLog(
      () =>
          'xVeil[content]: group holder manifest '
          '${manifest.contentId.substring(0, 12)} <- ${peer.short}',
    );
    unawaited(_clearContentGone(manifest.contentId));
  }

  String? _groupScopedManifestContentId(String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final ref = _parseContentManifestRef(decoded);
      if (ref != null) return ref.contentId;
      return ContentManifest.fromJson(decoded)?.contentId;
    } catch (_) {
      return null;
    }
  }

  Future<void> _onContentManifestRef(
    NodeId peer,
    _ContentManifestRef ref,
  ) async {
    final cid = ref.contentId;
    devLog(
      () =>
          'xVeil[content]: manifest ref parsed ${cid.substring(0, 12)} '
          'size=${ref.size} msg=${ref.msgId?.substring(0, 8)} '
          '<- ${peer.short}',
    );
    await _surfaceFileOfferFields(
      peer,
      contentId: cid,
      name: ref.name,
      size: ref.size,
      msgId: ref.msgId,
      seq: ref.seq,
      ts: ref.ts,
      thumb: ref.thumb,
    );

    if (await _storage.hasFile(cid)) {
      devLog(
        () =>
            'xVeil[content]: ${cid.substring(0, 12)} ALREADY HELD '
            '<- ${peer.short} (manifest ref only)',
      );
      await _send(peer, WireEnvelope.ack(ref.msgId ?? cid).encode());
      _signal();
      return;
    }
    _contentAvailability.rememberRef(peer, ref);
    // A fresh ref proves the content is obtainable again.
    unawaited(_clearContentGone(cid));
    // A durable pending download exists and its holder just showed up online.
    unawaited(_resumeOnOfferSignal(cid));
    if (_contentAvailability.hasPending(cid)) {
      unawaited(_resumePendingFromManifestRef(peer, cid, ref));
      return;
    }
    if (_fetchSavePath.containsKey(cid)) {
      devLog(
        () =>
            'xVeil[content]: ${cid.substring(0, 12)} '
            'plain-file download pending — waiting stream manifest',
      );
      return;
    }
    if (_filePolicy.allowsAuto(ref.size, ref.name)) {
      unawaited(_beginFetchFromManifestRef(peer, cid, ref, null, null));
    } else {
      devLog(
        () =>
            'xVeil[content]: ${cid.substring(0, 12)} '
            '(${ref.size}B "${ref.name}") <- ${peer.short} — '
            'OFFERED via manifest-ref',
      );
    }
  }

  /// Register a fetch for [m] + request all its pieces. Evicts any abandoned
  /// reassembler first (RAM bound). [sink] (non-null) diverts each verified piece
  /// to a plaintext file the user picked, instead of the Storage port. Shared by
  /// auto-download and [downloadContent]/[downloadContentToFile].
  Future<void> _beginFetch(
    NodeId peer,
    ContentManifest m, {
    _FetchSink? sink,
  }) async {
    if (_disposed || _cancelledDownloads.contains(m.contentId)) {
      try {
        await sink?.close();
      } catch (_) {}
      return;
    }
    // Expire before checking this same content id. Previously a stale fetch
    // matched here forever, so a retry was parked behind an abandoned
    // reassembler and its plaintext sink handle was leaked.
    await _contentFetching.evictStale();
    final existing = _contentFetching.active(m.contentId);
    if (existing != null) {
      if (sink != null) {
        if (existing.sink == null) {
          _contentAvailability.holdPending(m.contentId, sink);
          devLog(
            () =>
                'xVeil[content]: plain-file save parked for '
                '${m.contentId.substring(0, 12)} — export after active fetch',
          );
        } else {
          await sink.close(); // already fetching to a plaintext sink
        }
      }
      return;
    }
    _contentFetching.add(
      m.contentId,
      manifest: m,
      xfer: ContentTransfer(m),
      peer: peer,
      name: m.name,
      sink: sink,
    );
    _ensureContentTimer();
    await _send(
      peer,
      pieceRequestEnvelope(contentId: m.contentId, indices: null).encode(),
    );
  }

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

  Future<(NodeId, ContentManifest)?> _raceManifestHeaders(
    Iterable<NodeId> peers,
    String cid,
  ) {
    final candidates = _uniquePeers(peers);
    if (candidates.isEmpty) {
      return Future.value(null);
    }
    final result = Completer<(NodeId, ContentManifest)?>();
    var pending = candidates.length;
    void finish(NodeId peer, ContentManifest? manifest) {
      pending--;
      if (manifest != null && !result.isCompleted) {
        result.complete((peer, manifest));
      } else if (pending == 0 && !result.isCompleted) {
        result.complete(null);
      }
    }

    for (final peer in candidates) {
      unawaited(
        _readManifestHeader(peer, cid).then(
          (manifest) => finish(peer, manifest),
          onError: (Object _, StackTrace _) => finish(peer, null),
        ),
      );
    }
    return result.future;
  }

  Future<bool> _eligiblePullSource(NodeId peer, String contentId) async {
    final contact = await _storage.getContact(peer);
    return (contact != null && contact.status == ContactStatus.accepted) ||
        _groupPullSourceAllowed(peer, contentId);
  }

  NodeId _offerPeer(
    ({ContentManifest manifest, Map<String, NodeId> peers}) offered, {
    required NodeId preferred,
  }) =>
      offered.peers[preferred.hex] ??
      (offered.peers.isNotEmpty ? offered.peers.values.first : preferred);

  List<NodeId> _offerPeers({
    required NodeId preferred,
    required String contentId,
  }) {
    final out = <String, NodeId>{preferred.hex: preferred};
    final offered = _offered[contentId];
    if (offered != null) {
      for (final peer in offered.peers.values) {
        out[peer.hex] = peer;
      }
    }
    final offeredRef = _offeredRefs[contentId];
    if (offeredRef != null) {
      for (final peer in offeredRef.peers.values) {
        out[peer.hex] = peer;
      }
    }
    return out.values.toList(growable: false);
  }

  Future<List<NodeId>> _contentSourcePeers({
    required NodeId preferred,
    required String contentId,
  }) async {
    final out = <String, NodeId>{
      for (final peer in _offerPeers(
        preferred: preferred,
        contentId: contentId,
      ))
        peer.hex: peer,
    };
    for (final peer in await _storedContentSourcePeers(contentId)) {
      out[peer.hex] = peer;
    }
    return _filterGoneSources(contentId, out.values);
  }

  Future<List<NodeId>> _storedContentSourcePeers(String contentId) async {
    final out = <String, NodeId>{};
    try {
      for (final conv in await _storage.loadConversations()) {
        if (!conv.peer.canMessage) continue;
        final hasOffer = (await _storage.loadMessages(conv.id)).any(
          (m) =>
              m.direction == MessageDirection.incoming &&
              (m.fileContentId == contentId || m.fileId == contentId),
        );
        if (hasOffer) out[conv.peer.nodeId.hex] = conv.peer.nodeId;
      }
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: stored source scan failed '
            '${contentId.substring(0, 12)}: $e',
      );
    }
    return out.values.toList(growable: false);
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

  void _onPieceRequest(NodeId peer, PieceRequestFrame req) {
    final served = _serving[req.contentId];
    if (served == null) {
      devLog(
        () =>
            'xVeil[content]: pieceRequest for UNSERVED '
            '${req.contentId.substring(0, 12)} <- ${peer.short} (ignored)',
      );
      return; // not serving this content
    }
    // Refresh freshness on EVERY request (even one we skip) — it isn't evicted
    // mid-flight, and the live serve loop reads this to know the receiver is
    // still interested (it STOPS when the requests stop — see [_serveChunks]).
    _serving[req.contentId] = (
      manifest: served.manifest,
      source: served.source,
      servedAt: _now(),
    );
    if (_servingNow.contains(req.contentId)) {
      devLog(
        () =>
            'xVeil[content]: pieceRequest ${req.contentId.substring(0, 12)} '
            '— a serve is already in flight, skipping <- ${peer.short}',
      );
      return; // one serve loop per content (single-cursor source)
    }
    final m = served.manifest;
    // gaps: pieceIndex → chunk indices to serve (null ⇒ every chunk of the piece).
    final Map<int, List<int>?> gaps;
    final bm = req.bitmaps;
    if (bm != null && bm.isNotEmpty) {
      gaps = {
        for (final e in bm.entries)
          if (e.key >= 0 && e.key < m.pieceCount)
            e.key: _chunksFromBitmap(m, e.key, e.value),
      };
      final total = gaps.values.fold<int>(0, (a, b) => a + (b?.length ?? 0));
      devLog(
        () =>
            'xVeil[content]: pieceRequest ${req.contentId.substring(0, 12)} '
            'CHUNK-granular ($total chunks over ${gaps.length} pieces) '
            '<- ${peer.short} -> serving',
      );
    } else {
      final indices = req.indices ?? [for (var i = 0; i < m.pieceCount; i++) i];
      gaps = {for (final p in indices) p: null};
      devLog(
        () =>
            'xVeil[content]: pieceRequest ${req.contentId.substring(0, 12)} '
            '(${indices.length}/${m.pieceCount} whole pieces) <- ${peer.short} '
            '-> serving',
      );
    }
    _servingNow.add(req.contentId);
    unawaited(
      _serveChunks(
        peer,
        m,
        served.source,
        gaps,
      ).whenComplete(() => _servingNow.remove(req.contentId)),
    );
  }

  /// Drop served manifests idle past their TTL, then — if still over the
  /// registry cap — evict the OLDEST until under it. A serve-from-source
  /// entry's [ServeSource.close] is called as it leaves (release the file
  /// handle); a later re-request to an evicted entry simply finds nothing served
  /// and the receiver gives up (a re-send re-opens the source).
  void _evictServing() => _contentServing.evict();

  /// Decode a missing-chunk bitmap into the chunk indices it marks for piece [p].
  List<int> _chunksFromBitmap(ContentManifest m, int p, Uint8List bm) {
    final cc = m.chunkCount(p);
    return [
      for (var c = 0; c < cc; c++)
        if ((c >> 3) < bm.length && (bm[c >> 3] & (1 << (c & 7))) != 0) c,
    ];
  }

  /// Serve [gaps] (pieceIndex → chunk indices, null ⇒ all chunks of the piece)
  /// of content [m] to [peer]. Each chunk's bytes are read either from [source]
  /// (the sender's original file, for a large serve-from-source send) or — when
  /// [source] is null — from the on-disk blob ([readFileRange]) at the derived
  /// offset; the file is never held in RAM. Chunk coordinates come from the
  /// manifest's [ContentManifest.chunkBytes] so they match the receiver.
  Future<void> _serveChunks(
    NodeId peer,
    ContentManifest m,
    ServeSource? source,
    Map<int, List<int>?> gaps,
  ) async {
    // Flatten the requested (piece, chunk) coordinates into one list so we can
    // emit them in bounded batches across pieces, not strictly piece-by-piece.
    final coords = <({int p, int c})>[];
    for (final entry in gaps.entries) {
      final p = entry.key;
      if (p < 0 || p >= m.pieceCount) continue;
      final n = m.chunkCount(p);
      final chunks = entry.value ?? [for (var c = 0; c < n; c++) c];
      for (final c in chunks) {
        if (c >= 0 && c < n) coords.add((p: p, c: c));
      }
    }
    for (var i = 0; i < coords.length; i += _contentServeBatch) {
      // Stop a long serve the receiver has ABANDONED: if it stopped re-requesting
      // (its fetch completed / went stale), our [_serving] freshness goes stale
      // (refreshed on every pieceRequest). Otherwise the sender grinds out a
      // whole big file nobody is fetching (the receiver logs "pieceChunk DROPPED"
      // for every late chunk) — wasted bandwidth + log spam.
      final cur = _serving[m.contentId];
      if (cur == null ||
          _now().difference(cur.servedAt) > _serveAbandonTimeout) {
        devLog(
          () =>
              'xVeil[content]: serve STOPPED ${m.contentId.substring(0, 12)} '
              'at chunk $i/${coords.length} — receiver no longer requesting',
        );
        return;
      }
      final end = (i + _contentServeBatch < coords.length)
          ? i + _contentServeBatch
          : coords.length;
      // READ the batch sequentially (a serve-from-source RandomAccessFile is a
      // single cursor — concurrent reads would race it; on-disk readFileRange is
      // fine either way), then SEND the batch CONCURRENTLY for throughput — the
      // re-request loop refills anything the TX queue sheds under load.
      final batch = <({int p, int c, Uint8List data})>[];
      for (var j = i; j < end; j++) {
        final p = coords[j].p, c = coords[j].c;
        final cb = m.chunkBytes;
        final plen = m.pieceLength(p);
        final cstart = p * m.pieceSize + c * cb;
        final clen = (c * cb + cb <= plen) ? cb : plen - c * cb;
        Uint8List? data;
        try {
          data = source != null
              ? await source.read(cstart, clen)
              : await _storage.readFileRange(m.contentId, cstart, clen);
        } catch (e) {
          devLog(
            () =>
                'xVeil[content]: serve read failed '
                '${m.contentId.substring(0, 12)} p$p c$c: $e',
          );
        }
        if (data != null) batch.add((p: p, c: c, data: data));
      }
      await Future.wait([
        for (final ch in batch)
          _send(
            peer,
            pieceChunkEnvelope(
              contentId: m.contentId,
              pieceIndex: ch.p,
              chunkIndex: ch.c,
              chunkCount: m.chunkCount(ch.p),
              data: ch.data,
            ).encode(),
          ),
      ]);
      await Future<void>.delayed(
        _contentPacing,
      ); // anti-burst pace between batches
    }
  }

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

  bool _beginStreamServe(String cid, {int? limit}) {
    final maxActive = (limit ?? _streamRangeParallelism).clamp(
      1,
      _maxStreamRangeParallelism,
    );
    return _contentServing.beginStream(cid, maxActive);
  }

  void _endStreamServe(String cid) => _contentServing.endStream(cid);

  void _acceptAnonymousContentStream(NodeId peer, ReliableStream stream) {
    _bulkStreamLog(() => 'xVeil[content]: stream-accept anon <- ${peer.short}');
    _contentStreams.runServe(stream, () => _serveStream(peer, stream));
  }

  void _acceptP2PContentStream(NodeId peer, ReliableStream stream) {
    _contentStreams.runServe(stream, () async {
      if (await _p2pStreamAllowed(peer)) {
        _bulkStreamLog(
          () => 'xVeil[content]: stream-accept p2p <- ${peer.short}',
        );
        await _serveStream(peer, stream);
        return;
      }
      devLog(() => 'xVeil[content]: stream-accept p2p DENIED <- ${peer.short}');
      try {
        await stream.close();
      } catch (_) {}
    });
  }

  /// Serve one inbound bulk stream: read the 32-byte contentId, then write the
  /// manifest + the file bytes from our source (live serve-from-source, or a
  /// durable re-open). Closes the stream (EOF) when done / on any failure.
  Future<void> _serveStream(NodeId peer, ReliableStream stream) async {
    ServeSource? durable; // opened just for this serve (closed in finally)
    String? activeCid;
    var failed = false;
    try {
      _bulkStreamLog(
        () => 'xVeil[content]: stream-serve accepted <- ${peer.short}',
      );
      final reqBytes = await _readExactly(
        stream,
        _streamRequestBytes,
      ).timeout(_streamRequestTimeout, onTimeout: () => null);
      if (reqBytes == null) {
        devLog(
          () =>
              'xVeil[content]: stream-serve EOF/timeout before request '
              '<- ${peer.short}',
        );
        return; // peer hung up before requesting
      }
      final cidBytes = Uint8List.sublistView(reqBytes, 0, 32);
      final cid = _hexEncode(cidBytes);
      final requestedOffset = reqBytes.length >= 40
          ? _readU64be(Uint8List.sublistView(reqBytes, 32, 40))
          : 0;
      final requestedLength = reqBytes.length >= 48
          ? _readU64be(Uint8List.sublistView(reqBytes, 40, 48))
          : 0;
      _bulkStreamLog(
        () =>
            'xVeil[content]: stream-serve request '
            '${cid.substring(0, 12)}'
            '${requestedOffset > 0 ? ' @ $requestedOffset' : ''}'
            '${requestedLength > 0 ? ' +$requestedLength' : ''} '
            '<- ${peer.short}',
      );
      final contact = await _storage.getContact(peer);
      // Serve accepted 1:1 contacts as always; a NON-contact group member is
      // served iff it holds a live membership grant for THIS cid (groups
      // content path — the grant was minted by the authorized signed request).
      if ((contact == null || contact.status != ContactStatus.accepted) &&
          !_groupServeGranted(peer, cid)) {
        devLog(
          () =>
              'xVeil[content]: stream-serve DENIED '
              '${cid.substring(0, 12)} <- ${peer.short} '
              '(not accepted, no group grant)',
        );
        return;
      }
      ContentManifest? manifest;
      ServeSource? source;
      var canReadStoredBlob = false;
      final live = _serving[cid];
      if (live != null) {
        manifest = live.manifest;
        // Prefer a per-stream file handle when we persisted the source path.
        // A repeated send of the same bytes has the same contentId and replaces
        // the shared live source; if this stream borrowed that shared handle, the
        // replacement could close it mid-transfer ("File closed"). A reopened
        // handle is independent and is closed in this method's finally.
        if (sourceOpener != null) {
          final rec = _parseServedRecord(
            await _storage.getSetting('served:$cid'),
          );
          if (rec != null) {
            source = durable = await sourceOpener!(rec.path);
          }
        }
        source ??= live.source;
      }
      if (manifest == null) {
        final mfBytes = await _storage.loadFile('mf:$cid');
        if (mfBytes != null) {
          manifest = ContentManifest.fromJson(
            jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
          );
        }
      }
      if (source == null && sourceOpener != null) {
        final rec = _parseServedRecord(
          await _storage.getSetting('served:$cid'),
        );
        if (rec != null) {
          source = durable = await sourceOpener!(rec.path);
        }
      }
      // No mf: blob (its persist is the first casualty of a bloated store —
      // IndexFull) but the served: record carries the hashing params: rebuild
      // the manifest from the source file instead of answering UNSERVED.
      if (manifest == null) {
        final rec = _parseServedRecord(
          await _storage.getSetting('served:$cid'),
        );
        if (rec != null) {
          manifest = await _rebuildManifestFromServedRecord(cid, rec);
        }
      }
      if (source == null && manifest != null) {
        canReadStoredBlob = await _storage.hasFile(cid);
      }
      if (manifest == null || (source == null && !canReadStoredBlob)) {
        devLog(
          () =>
              'xVeil[content]: stream-serve UNSERVED '
              '${cid.substring(0, 12)} <- ${peer.short} (close → re-send)',
        );
        return; // close → receiver sees EOF before the manifest
      }
      // A single long stream can wedge inside flow-controlled write() until its
      // write-idle timeout fires. If rangeParallelism is 1, treating that as the
      // per-content serve limit makes every receiver retry get EOF-before-
      // manifest while the old stream is still timing out. When we have an
      // independent per-stream source (durable reopen or stored blob), allow one
      // extra serve so the retry can resume instead of waiting behind the dead
      // writer. Shared live sources keep the configured cap to avoid cursor
      // thrash.
      final independentSource =
          durable != null || (source == null && canReadStoredBlob);
      final serveLimit = independentSource
          ? (_streamRangeParallelism + 4).clamp(2, _maxStreamRangeParallelism)
          : _streamRangeParallelism;
      if (!_beginStreamServe(cid, limit: serveLimit)) {
        devLog(
          () =>
              'xVeil[content]: stream-serve too many active '
              '${cid.substring(0, 12)} <- ${peer.short} '
              '(limit=$serveLimit, closing retry)',
        );
        return;
      }
      activeCid = cid;
      final m = manifest; // promoted non-null (closures need a final)
      final src = source;
      if (src == null) {
        // Warm the manifest for repeated swarm pulls. A null source means the
        // bytes are served from this identity's verified stored blob.
        _serving[cid] = (manifest: m, source: null, servedAt: _now());
        _evictServing();
      }
      _bulkStreamLog(
        () =>
            'xVeil[content]: stream-serve ${cid.substring(0, 12)} '
            '(${m.size}B) -> ${peer.short}',
      );
      if (_disposed) throw StateError('messaging service disposed');
      final mf = Uint8List.fromList(utf8.encode(jsonEncode(m.toJson())));
      await stream.write(_u32be(mf.length)).timeout(_streamPayloadWriteTimeout);
      await stream.write(mf).timeout(_streamPayloadWriteTimeout);
      _bulkStreamLog(
        () =>
            'xVeil[content]: stream-serve manifest sent '
            '${cid.substring(0, 12)} (${mf.length}B) -> ${peer.short}',
      );
      final size = m.size;
      var off = requestedOffset.clamp(0, size).toInt();
      final end = requestedLength > 0
          ? (off + requestedLength).clamp(off, size).toInt()
          : size;
      if (off > 0 || requestedLength > 0) {
        _bulkStreamLog(
          () =>
              'xVeil[content]: stream-serve range '
              '${cid.substring(0, 12)} $off..$end/${size}B -> ${peer.short}',
        );
      }
      final serveSw = Stopwatch()..start();
      var lastServeLogBytes = off;
      var lastServeLogMs = 0;
      while (off < end) {
        if (_disposed) throw StateError('messaging service disposed');
        final n =
            ((end - off) < _streamReadChunk ? (end - off) : _streamReadChunk)
                .toInt();
        final data = src == null
            ? await _storage
                  .readFileRange(cid, off, n)
                  .timeout(
                    _streamSourceReadTimeout,
                    onTimeout: () => throw TimeoutException(
                      'stored blob idle at $off/$size',
                      _streamSourceReadTimeout,
                    ),
                  )
            : await src
                  .read(off, n)
                  .timeout(
                    _streamSourceReadTimeout,
                    onTimeout: () => throw TimeoutException(
                      'source idle at $off/$size',
                      _streamSourceReadTimeout,
                    ),
                  );
        if (data == null || data.isEmpty) {
          throw StateError('source truncated at $off/$size');
        }
        if (_disposed) throw StateError('messaging service disposed');
        await stream
            .write(data)
            .timeout(
              _streamPayloadWriteTimeout,
              onTimeout: () => throw TimeoutException(
                'payload write idle at $off/$size',
                _streamPayloadWriteTimeout,
              ),
            ); // flow-controlled (back-pressures)
        off += data.length;
        final elapsedMs = serveSw.elapsedMilliseconds;
        if (off == data.length ||
            off >= size ||
            off - lastServeLogBytes >= 1024 * 1024 ||
            elapsedMs - lastServeLogMs >= 2000) {
          _bulkStreamLog(
            () =>
                'xVeil[content]: stream-serve queued '
                '${cid.substring(0, 12)} $off/${size}B -> ${peer.short}',
          );
          lastServeLogBytes = off;
          lastServeLogMs = elapsedMs;
        }
      }
      _bulkStreamLog(
        () =>
            'xVeil[content]: stream-serve complete '
            '${cid.substring(0, 12)} $off/${size}B -> ${peer.short}',
      );
    } catch (e) {
      failed = true;
      devLog(() => 'xVeil[content]: stream-serve failed <- ${peer.short}: $e');
    } finally {
      final cid = activeCid;
      if (cid != null) _endStreamServe(cid);
      if (durable != null) {
        try {
          await durable.close();
        } catch (_) {}
      }
      try {
        if (failed) {
          await stream.abort();
        } else {
          await stream.close();
        }
      } catch (_) {}
    }
  }

  /// Try to download [cid] from [peer] over a RELIABLE stream. Returns true if it
  /// took ownership (runs async to completion / failure); false if streams aren't
  /// available so the caller falls back to the datagram path. The bytes land in
  /// [sink] (unencrypted-to-file) or the Storage port (encrypted tier / in-volume)
  /// with per-piece verification + progress. Works WITHOUT a live offer handle —
  /// the manifest arrives on the stream, so no reoffer dance.
  List<NodeId> _uniquePeers(Iterable<NodeId> peers) {
    final out = <String, NodeId>{};
    for (final peer in peers) {
      out[peer.hex] = peer;
    }
    return out.values.toList(growable: false);
  }

  List<NodeId> _orderedPullPeers(NodeId first, Iterable<NodeId> peers) {
    return _uniquePeers([first, ...peers]);
  }

  Future<bool> _pullStream(
    NodeId peer,
    String cid,
    _FetchSink? sink, {
    String? savedPath,
    Iterable<NodeId> retryPeers = const [],
  }) async {
    final peers = _orderedPullPeers(peer, retryPeers);
    for (final candidate in peers) {
      final stream = await _openInitialPullStream(candidate, cid);
      if (stream == null) continue;
      final runPeers = _orderedPullPeers(candidate, peers);
      _contentStreams.runPull(() async {
        await _runPull(
          candidate,
          cid,
          sink,
          stream,
          savedPath,
          retryPeers: runPeers,
        );
      });
      return true;
    }
    return false; // no circuit → caller falls back
  }

  Future<bool?> _pullStreamToCompletion(
    NodeId peer,
    String cid, {
    _FetchSink? sink,
    String? savedPath,
    bool closeSinkOnFailure = true,
  }) async {
    final stream = await _openInitialPullStream(peer, cid);
    if (stream == null) return null;
    return _runPull(
      peer,
      cid,
      sink,
      stream,
      savedPath,
      emitFailure: false,
      closeSinkOnFailure: closeSinkOnFailure,
    );
  }

  Future<bool> _pullSwarmStream(
    NodeId preferred,
    String cid,
    ContentManifest manifest,
    Iterable<NodeId> peers,
  ) async {
    if (_transport is! StreamTransport) {
      return false;
    }
    if (!_streamRangeEnabled || manifest.pieceCount < 2) {
      devLog(
        () =>
            'xVeil[content]: swarm-range disabled '
            '${cid.substring(0, 12)}, using sequential stream',
      );
      return _pullStream(preferred, cid, null, retryPeers: peers);
    }
    final sources = await _eligibleStreamSources(
      _orderedPullPeers(preferred, peers),
      contentId: cid,
    );
    if (sources.isEmpty) return false;
    if (sources.length < 2 &&
        !_explicitRangeFanout &&
        !await _hasStoredPiece(manifest)) {
      // ONE source and a FRESH download: a single whole-file stream beats the
      // range swarm — ranges pay per-stream opens + manifest rounds + a fresh
      // congestion ramp each (measured 64 MiB device A/B: sequential
      // 11.2-13.7s vs ranged p4 14-21s / p1 23-100s), and the sequential pull
      // already resumes at piece granularity on retry. The range swarm still
      // wins when it can fan out over DIFFERENT holders, and still handles a
      // PARTIALLY stored blob (it skips locally verified pieces; the
      // sequential stream would re-fetch them). An explicit
      // XVEIL_STREAM_RANGE_PARALLELISM keeps forcing the swarm path.
      devLog(
        () =>
            'xVeil[content]: swarm-range single-source '
            '${cid.substring(0, 12)}, using sequential stream',
      );
      if (await _pullStream(preferred, cid, null, retryPeers: peers)) {
        return true;
      }
      // No stream could be opened RIGHT NOW (route flap at tap time). The
      // range swarm keeps retrying opens with backoff, so fall through to it
      // instead of degrading to the datagram path.
    }
    _contentStreams.runPull(
      () => _runSwarmPullThenFallback(preferred, cid, manifest, sources),
    );
    return true;
  }

  /// True if ANY piece of [manifest] is already in the blob store (a partial
  /// earlier download). Cheap for a fresh download: every lookup misses and
  /// the first stored piece short-circuits.
  Future<bool> _hasStoredPiece(ContentManifest manifest) async {
    final cid = manifest.contentId;
    for (var i = 0; i < manifest.pieceCount; i++) {
      final len = manifest.pieceLength(i);
      final existing = await _storage.readFileRange(
        cid,
        i * manifest.pieceSize,
        len,
      );
      if (existing != null && existing.length == len) return true;
    }
    return false;
  }

  Future<bool> _pullSwarmStreamToFile(
    NodeId preferred,
    String cid,
    ContentManifest manifest,
    Iterable<NodeId> peers,
    _FetchSink sink,
    String savedPath,
  ) async {
    if (_transport is! StreamTransport) {
      return false;
    }
    if (!_streamRangeEnabled || manifest.pieceCount < 2) {
      devLog(
        () =>
            'xVeil[content]: swarm-range-to-file disabled '
            '${cid.substring(0, 12)}, using sequential stream',
      );
      return _pullStream(
        preferred,
        cid,
        sink,
        savedPath: savedPath,
        retryPeers: peers,
      );
    }
    final sources = await _eligibleStreamSources(
      _orderedPullPeers(preferred, peers),
      contentId: cid,
    );
    if (sources.isEmpty) return false;
    // A RESUME (sink.read != null) MUST take the range path even for one
    // source: only the range swarm hash-verifies pieces off disk and skips the
    // ones already written. The sequential stream would re-fetch from byte 0,
    // defeating the resume.
    final isResume = sink.read != null;
    if (sources.length < 2 && !_explicitRangeFanout && !isResume) {
      // See _pullSwarmStream: one source → sequential whole-file stream (a FRESH
      // sink download has no partially stored pieces to skip). Falls through to
      // the range swarm when no stream opens right now.
      devLog(
        () =>
            'xVeil[content]: swarm-range-to-file single-source '
            '${cid.substring(0, 12)}, using sequential stream',
      );
      if (await _pullStream(
        preferred,
        cid,
        sink,
        savedPath: savedPath,
        retryPeers: peers,
      )) {
        return true;
      }
    }
    _contentStreams.runPull(
      () => _runSwarmFileThenFallback(
        preferred,
        cid,
        manifest,
        sources,
        sink,
        savedPath,
      ),
    );
    return true;
  }

  Future<List<NodeId>> _eligibleStreamSources(
    Iterable<NodeId> peers, {
    required String contentId,
  }) async {
    final accepted = <String, NodeId>{};
    for (final peer in peers) {
      if (!await _eligiblePullSource(peer, contentId)) continue;
      accepted[peer.hex] = peer;
    }
    return accepted.values.toList(growable: false);
  }

  NodeId _offerRefPeer(
    ({_ContentManifestRef ref, Map<String, NodeId> peers}) offered, {
    required NodeId preferred,
  }) =>
      offered.peers[preferred.hex] ??
      (offered.peers.isNotEmpty ? offered.peers.values.first : preferred);

  Future<ContentManifest?> _fetchManifestFromRef(
    NodeId preferred,
    String cid,
    _ContentManifestRef ref,
    Iterable<NodeId> peers,
  ) async {
    final sources = await _eligibleStreamSources(
      _orderedPullPeers(preferred, peers),
      contentId: cid,
    );
    for (final peer in sources) {
      final m = await _readManifestOnly(peer, cid, ref);
      if (m == null) continue;
      _rememberOfferedManifest(peer, m);
      return m;
    }
    return null;
  }

  Future<ContentManifest?> _readManifestOnly(
    NodeId peer,
    String cid,
    _ContentManifestRef ref,
  ) async {
    final stream = await _openInitialPullStream(peer, cid);
    if (stream == null) return null;
    var gracefulClose = false;
    try {
      final req = _streamRequest(cid, offset: ref.size);
      await Future<void>.delayed(_streamOpenWriteGrace);
      await stream.write(req).timeout(_streamRequestTimeout);
      final lenB = await _readExactly(
        stream,
        4,
      ).timeout(_streamManifestTimeout, onTimeout: () => null);
      if (lenB == null) throw StateError('no stream manifest');
      final mfLen = _readU32be(lenB);
      if (mfLen <= 0 || mfLen > (1 << 20)) {
        throw StateError('bad stream manifest len');
      }
      final mfBytes = await _readExactly(
        stream,
        mfLen,
      ).timeout(_streamManifestTimeout, onTimeout: () => null);
      if (mfBytes == null) throw StateError('stream manifest truncated');
      final m = ContentManifest.fromJson(
        jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
      );
      if (m == null ||
          m.contentId != cid ||
          m.size != ref.size ||
          m.name != ref.name) {
        throw StateError('stream manifest does not bind advertised ref');
      }
      devLog(
        () =>
            'xVeil[content]: manifest stream-resolved '
            '${cid.substring(0, 12)} pieces=${m.pieceCount} '
            'piece_size=${m.pieceSize} <- ${peer.short}',
      );
      gracefulClose = true;
      return m;
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: manifest stream-resolve failed '
            '${cid.substring(0, 12)} <- ${peer.short}: $e',
      );
      return null;
    } finally {
      try {
        if (gracefulClose) {
          await stream.close();
        } else {
          await stream.abort();
        }
      } catch (_) {}
    }
  }

  Future<ContentManifest?> _fetchManifestFromStream(
    NodeId preferred,
    String cid,
    Iterable<NodeId> peers,
  ) async {
    final sources = await _eligibleStreamSources(
      _orderedPullPeers(preferred, peers),
      contentId: cid,
    );
    for (final peer in sources) {
      final m = await _readManifestHeader(peer, cid);
      if (m == null) continue;
      _rememberOfferedManifest(peer, m);
      return m;
    }
    return null;
  }

  Future<ContentManifest?> _readManifestHeader(NodeId peer, String cid) async {
    final stream = await _openInitialPullStream(peer, cid);
    if (stream == null) return null;
    var gracefulClose = false;
    try {
      // Ask for the smallest possible payload after the manifest so the sender
      // can finish this probe cleanly. A length of 0 means "stream the whole
      // content" in the serve path; closing immediately after the manifest then
      // trips a noisy write-failure and can perturb the shared onion driver.
      final req = _streamRequest(cid, length: 1);
      await Future<void>.delayed(_streamOpenWriteGrace);
      await stream.write(req).timeout(_streamRequestTimeout);
      // First-byte stall: a source that never sends the length prefix is dead —
      // abandon it fast (the shorter of the two bounds) so the caller tries the
      // next holder rather than eating the full 25s cap on one silent peer.
      final firstByteTimeout =
          streamManifestFirstByteTimeout < _streamManifestTimeout
          ? streamManifestFirstByteTimeout
          : _streamManifestTimeout;
      final lenB = await _readExactly(
        stream,
        4,
      ).timeout(firstByteTimeout, onTimeout: () => null);
      if (lenB == null) throw StateError('no stream manifest');
      final mfLen = _readU32be(lenB);
      if (mfLen <= 0 || mfLen > (1 << 20)) {
        throw StateError('bad stream manifest len');
      }
      final mfBytes = await _readExactly(
        stream,
        mfLen,
      ).timeout(_streamManifestTimeout, onTimeout: () => null);
      if (mfBytes == null) throw StateError('stream manifest truncated');
      final m = ContentManifest.fromJson(
        jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
      );
      if (m == null || m.contentId != cid) {
        throw StateError('stream manifest does not bind requested content');
      }
      if (m.size > 0) {
        await _readExactly(
          stream,
          1,
        ).timeout(_streamManifestTimeout, onTimeout: () => null);
      }
      devLog(
        () =>
            'xVeil[content]: manifest stream-probed '
            '${cid.substring(0, 12)} pieces=${m.pieceCount} '
            'piece_size=${m.pieceSize} <- ${peer.short}',
      );
      gracefulClose = true;
      return m;
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: manifest stream-probe failed '
            '${cid.substring(0, 12)} <- ${peer.short}: $e',
      );
      return null;
    } finally {
      try {
        if (gracefulClose) {
          await stream.close();
        } else {
          await stream.abort();
        }
      } catch (_) {}
    }
  }

  void _rememberOfferedManifest(NodeId peer, ContentManifest manifest) {
    _contentAvailability.rememberManifest(peer, manifest);
  }

  Future<bool> _beginDownloadWithManifest(
    NodeId peer,
    String cid,
    ContentManifest manifest,
    _FetchSink? sink,
    String? savedPath,
  ) async {
    final retryPeers = await _contentSourcePeers(
      preferred: peer,
      contentId: cid,
    );
    if (sink != null) {
      if (_plainFileStream &&
          await _pullSwarmStreamToFile(
            peer,
            cid,
            manifest,
            retryPeers,
            sink,
            savedPath ?? cid,
          )) {
        return true;
      }
      await _beginFetch(peer, manifest, sink: sink);
      return true;
    }
    if (await _pullSwarmStream(peer, cid, manifest, retryPeers)) return true;
    if (await _pullStream(peer, cid, null, retryPeers: retryPeers)) return true;
    await _beginFetch(peer, manifest);
    return true;
  }

  Future<bool> _beginFetchFromManifestRef(
    NodeId peer,
    String cid,
    _ContentManifestRef ref,
    _FetchSink? sink,
    String? savedPath,
  ) async {
    final offeredRef = _offeredRefs[cid];
    final sources = _uniquePeers([
      peer,
      if (offeredRef != null) ...offeredRef.peers.values,
      ...await _storedContentSourcePeers(cid),
    ]);
    if (await _pipelinedPullToFile(peer, cid, sink, savedPath, sources)) {
      return true;
    }
    final m = await _fetchManifestFromRef(peer, cid, ref, sources);
    if (m == null) return false;
    return _beginDownloadWithManifest(peer, cid, m, sink, savedPath);
  }

  Future<bool> _beginFetchFromStreamManifest(
    NodeId peer,
    String cid,
    _FetchSink? sink, {
    String? savedPath,
    Iterable<NodeId> peers = const [],
  }) async {
    if (await _pipelinedPullToFile(peer, cid, sink, savedPath, peers)) {
      return true;
    }
    final m = await _fetchManifestFromStream(peer, cid, peers);
    if (m == null) return false;
    return _beginDownloadWithManifest(peer, cid, m, sink, savedPath);
  }

  /// PIPELINE: a plain-file download that would use ONE sequential stream
  /// anyway skips the standalone manifest probe (open + request + manifest +
  /// close ≈ two serialized onion RTTs before any payload) and goes straight
  /// to the pull stream — the serve path sends the manifest as the stream
  /// header, and that manifest self-authenticates against the requested
  /// contentId ([ContentManifest.isSelfConsistent] re-derives the id), so the
  /// probe adds no verification the pull itself lacks. Applies only when the
  /// swarm cannot be used anyway (range disabled) or would not be chosen
  /// (single accepted holder, no explicit fanout); sink downloads have no
  /// locally stored pieces the swarm could skip. Returns false → caller runs
  /// the classic probe-then-swarm path (which also retries opens).
  Future<bool> _pipelinedPullToFile(
    NodeId peer,
    String cid,
    _FetchSink? sink,
    String? savedPath,
    Iterable<NodeId> peers,
  ) async {
    if (sink == null ||
        !_plainFileStream ||
        _explicitRangeFanout ||
        _transport is! StreamTransport) {
      return false;
    }
    final streamSources = await _eligibleStreamSources(
      _orderedPullPeers(peer, peers),
      contentId: cid,
    );
    if (streamSources.isEmpty) return false;
    if (_streamRangeEnabled && streamSources.length > 1) return false;
    if (!await _pullStream(
      streamSources.first,
      cid,
      sink,
      savedPath: savedPath,
      retryPeers: streamSources,
    )) {
      return false; // no stream right now → probing path retries with backoff
    }
    devLog(
      () =>
          'xVeil[content]: manifest+data pipelined '
          '${cid.substring(0, 12)} -> ${streamSources.first.short} '
          '(sequential pull, probe round skipped)',
    );
    return true;
  }

  Future<void> _resumePendingFromManifestRef(
    NodeId peer,
    String cid,
    _ContentManifestRef ref,
  ) async {
    if (!_contentAvailability.hasPending(cid)) return;
    final m = await _fetchManifestFromRef(peer, cid, ref, [peer]);
    if (m == null || !_contentAvailability.hasPending(cid)) return;
    final sink = _contentAvailability.takePending(cid);
    devLog(
      () =>
          'xVeil[content]: manifest ref resolved for '
          '${cid.substring(0, 12)} — resuming the parked download',
    );
    await _beginDownloadWithManifest(peer, cid, m, sink, _fetchSavePath[cid]);
  }

  Future<void> _runSwarmPullThenFallback(
    NodeId preferred,
    String cid,
    ContentManifest manifest,
    List<NodeId> peers,
  ) async {
    if (await _pullSwarmPiecesToCompletion(peers, manifest) ||
        await _storage.hasFile(cid)) {
      return;
    }
    if (_cancelledDownloads.contains(cid)) return;
    devLog(
      () =>
          'xVeil[content]: swarm-range failed ${cid.substring(0, 12)}, '
          'falling back to sequential stream',
    );
    final fallbackPeers = _orderedPullPeers(preferred, [
      ...peers,
      ...await _contentSourcePeers(preferred: preferred, contentId: cid),
    ]);
    for (final peer in fallbackPeers) {
      final contact = await _storage.getContact(peer);
      if (contact == null || contact.status != ContactStatus.accepted) continue;
      final ok = await _pullStreamToCompletion(peer, cid);
      if (ok == true || await _storage.hasFile(cid)) return;
      if (_cancelledDownloads.contains(cid)) return;
    }
    final ok = await _pullStreamToCompletion(preferred, cid);
    if (ok == true || await _storage.hasFile(cid)) return;
    if (!_cancelledDownloads.contains(cid) && !_contentFailed.isClosed) {
      _contentFailed.add(cid);
    }
  }

  Future<void> _runSwarmFileThenFallback(
    NodeId preferred,
    String cid,
    ContentManifest manifest,
    List<NodeId> peers,
    _FetchSink sink,
    String savedPath,
  ) async {
    var ok = false;
    try {
      ok = await _pullSwarmPiecesToCompletion(
        peers,
        manifest,
        sink: sink,
        savedPath: savedPath,
      );
      if (ok) return;
      if (_cancelledDownloads.contains(cid)) return;
      devLog(
        () =>
            'xVeil[content]: swarm-range-to-file failed '
            '${cid.substring(0, 12)}, falling back to sequential stream',
      );
      final fallbackPeers = _orderedPullPeers(preferred, [
        ...peers,
        ...await _contentSourcePeers(preferred: preferred, contentId: cid),
      ]);
      for (final peer in fallbackPeers) {
        final contact = await _storage.getContact(peer);
        if (contact == null || contact.status != ContactStatus.accepted) {
          continue;
        }
        ok =
            await _pullStreamToCompletion(
              peer,
              cid,
              sink: sink,
              savedPath: savedPath,
              closeSinkOnFailure: false,
            ) ==
            true;
        if (ok) return;
        if (_cancelledDownloads.contains(cid)) return;
      }
    } finally {
      if (!ok) {
        try {
          await sink.close();
        } catch (_) {}
        if (!_cancelledDownloads.contains(cid) && !_contentFailed.isClosed) {
          _contentFailed.add(cid);
        }
      }
    }
  }

  Future<bool> _pullSwarmPiecesToCompletion(
    Iterable<NodeId> peers,
    ContentManifest manifest, {
    _FetchSink? sink,
    String? savedPath,
  }) async {
    _pullStarted(manifest.contentId);
    try {
      return await _pullSwarmPiecesToCompletionInner(
        peers,
        manifest,
        sink: sink,
        savedPath: savedPath,
      );
    } finally {
      _pullEnded(manifest.contentId);
    }
  }

  Future<bool> _pullSwarmPiecesToCompletionInner(
    Iterable<NodeId> peers,
    ContentManifest manifest, {
    _FetchSink? sink,
    String? savedPath,
  }) async {
    final cid = manifest.contentId;
    if (_cancelledDownloads.contains(cid)) return false;
    unawaited(_persistManifestIfPending(manifest));
    if (_transport is! StreamTransport ||
        !_streamRangeEnabled ||
        manifest.pieceCount < 2) {
      return false;
    }
    final initialPeers = peers.toList(growable: false);
    final sourceMap = <String, NodeId>{};

    Future<int> refreshSources() async {
      final before = sourceMap.length;
      final offered = _offered[cid];
      final accepted = await _eligibleStreamSources([
        ...initialPeers,
        if (offered != null) ...offered.peers.values,
        ...await _storedContentSourcePeers(cid),
      ], contentId: cid);
      for (final peer in accepted) {
        sourceMap[peer.hex] = peer;
      }
      final added = sourceMap.length - before;
      if (added > 0 && before > 0) {
        devLog(
          () =>
              'xVeil[content]: swarm-range sources refreshed '
              '${cid.substring(0, 12)} +$added -> ${sourceMap.length}',
        );
      }
      return added;
    }

    await refreshSources();
    if (sourceMap.isEmpty) return false;
    List<NodeId> sourceList() => sourceMap.values.toList(growable: false);

    final pending = <int>[];
    final completed = <int>{};
    var completedBytes = 0;
    // A RESUME reopen of a plain file provides a reader; read each piece back
    // off disk and hash-verify it (mirror of the encrypted-tier skip below), so
    // a restart re-pulls only the MISSING pieces instead of the whole file. A
    // fresh download / encrypted tier: sink.read is null → nothing to skip.
    final sinkRead = sink?.read;
    for (var i = 0; i < manifest.pieceCount; i++) {
      final len = manifest.pieceLength(i);
      final Uint8List? existing;
      if (sink == null) {
        existing = await _storage.readFileRange(
          cid,
          i * manifest.pieceSize,
          len,
        );
      } else if (sinkRead != null) {
        existing = await sinkRead(i * manifest.pieceSize, len);
      } else {
        existing = null;
      }
      if (existing != null &&
          existing.length == len &&
          manifest.verifyPiece(i, existing)) {
        completed.add(i);
        completedBytes += len;
      } else {
        pending.add(i);
      }
    }

    if (!_contentProgress.isClosed && completedBytes > 0) {
      _contentProgress.add((
        contentId: cid,
        done: completedBytes.clamp(0, manifest.size).toInt(),
        total: manifest.size,
      ));
    }
    if (pending.isEmpty) {
      if (!await _storage.hasFile(cid)) return false;
      if (!await _finishReceived(sourceList().first, manifest, null, null)) {
        return false;
      }
      if (!_contentProgress.isClosed) {
        _contentProgress.add((
          contentId: cid,
          done: manifest.size,
          total: manifest.size,
        ));
      }
      return true;
    }

    final workerCount = pending.length < _streamRangeParallelism
        ? pending.length
        : _streamRangeParallelism;
    final attempts = List<int>.filled(manifest.pieceCount, 0);
    int maxAttemptsPerPiece() {
      final sourceCount = sourceMap.length;
      final minAttemptsPerPiece = sourceCount < 3 ? 3 : sourceCount;
      return _streamPullMaxAttempts < minAttemptsPerPiece
          ? minAttemptsPerPiece
          : _streamPullMaxAttempts;
    }

    var failed = false;
    NodeId? completionPeer;
    ContentManifest? completionManifest;
    Future<void> sinkWriteTail = Future<void>.value();

    Future<void> writePiece(int pieceIndex, Uint8List piece) {
      if (sink == null) {
        return _storage.storeFilePiece(
          cid,
          pieceIndex,
          manifest.pieceCount,
          manifest.pieceSize,
          manifest.size,
          piece,
          name: manifest.name,
        );
      }
      final offset = pieceIndex * manifest.pieceSize;
      final next = sinkWriteTail.then((_) => sink.write(offset, piece));
      // The UI/soak callers use one RandomAccessFile with setPosition+write.
      // Serialize those writes here so parallel network pulls do not race the
      // file cursor.
      sinkWriteTail = next.catchError((_) {});
      return next;
    }

    var adaptiveRangeTargetBytes = _streamRangeTargetBytes;
    var successfulBytesSinceRangeGrow = 0;
    const rangeGrowAfterBytes = 8 * 1024 * 1024;
    // Keep the production default conservative (p8), but make explicit
    // speed-test overrides literal. Otherwise a requested
    // `XVEIL_STREAM_RANGE_PARALLELISM=12` silently starts at p8 and never
    // exceeds p10, which hides whether the native route/circuit fixes can
    // actually sustain higher fanout.
    final explicitRangeFanout = _streamRangeParallelismDartDefine > 0;
    final maxAdaptiveWorkerLimit = explicitRangeFanout
        ? workerCount
        : (workerCount < _defaultStreamRangeParallelism + 2
              ? workerCount
              : _defaultStreamRangeParallelism + 2);
    var adaptiveWorkerLimit = explicitRangeFanout
        ? workerCount
        : (workerCount < _defaultStreamRangeParallelism
              ? workerCount
              : _defaultStreamRangeParallelism);
    var activeRangeWorkers = 0;
    var successfulBytesSinceFanoutGrow = 0;
    var consecutiveRangeFailures = 0;
    const fanoutGrowAfterBytes = 16 * 1024 * 1024;
    Future<void> rangeOpenTail = Future<void>.value();

    Future<void> paceRangeStreamOpen() {
      final previous = rangeOpenTail;
      final gate = Completer<void>();
      rangeOpenTail = gate.future;
      return previous.catchError((_) {}).then((_) async {
        if (_streamRangeOpenPace > Duration.zero) {
          await Future<void>.delayed(_streamRangeOpenPace);
        }
        gate.complete();
      });
    }

    final beforeStreamOpen = _streamRangeOpenPace > Duration.zero
        ? paceRangeStreamOpen
        : null;

    void noteRangeFailure(List<int> pieces) {
      successfulBytesSinceRangeGrow = 0;
      successfulBytesSinceFanoutGrow = 0;
      consecutiveRangeFailures++;
      if (adaptiveWorkerLimit > 1 &&
          (adaptiveWorkerLimit > _defaultStreamRangeParallelism ||
              consecutiveRangeFailures >= 3)) {
        final previousLimit = adaptiveWorkerLimit;
        adaptiveWorkerLimit--;
        consecutiveRangeFailures = 0;
        devLog(
          () =>
              'xVeil[content]: swarm-range adapt fanout '
              '${cid.substring(0, 12)} workers=$previousLimit'
              '->$adaptiveWorkerLimit after failure '
              'failed_pieces=${pieces.length}',
        );
      }
      final minTarget = manifest.pieceSize < _streamRangeTargetBytes
          ? manifest.pieceSize
          : _streamRangeTargetBytes;
      if (adaptiveRangeTargetBytes <= minTarget) return;
      final previous = adaptiveRangeTargetBytes;
      var next = adaptiveRangeTargetBytes ~/ 2;
      if (next < minTarget) next = minTarget;
      adaptiveRangeTargetBytes = next;
      devLog(
        () =>
            'xVeil[content]: swarm-range adapt shrink '
            '${cid.substring(0, 12)} target_bytes=$previous'
            '->$adaptiveRangeTargetBytes failed_pieces=${pieces.length}',
      );
    }

    void noteRangeSuccess(int bytes) {
      consecutiveRangeFailures = 0;
      if (adaptiveWorkerLimit < maxAdaptiveWorkerLimit) {
        successfulBytesSinceFanoutGrow += bytes;
        if (successfulBytesSinceFanoutGrow >= fanoutGrowAfterBytes) {
          final previousLimit = adaptiveWorkerLimit;
          adaptiveWorkerLimit++;
          successfulBytesSinceFanoutGrow = 0;
          devLog(
            () =>
                'xVeil[content]: swarm-range adapt fanout '
                '${cid.substring(0, 12)} workers=$previousLimit'
                '->$adaptiveWorkerLimit after ${fanoutGrowAfterBytes}B ok',
          );
        }
      }
      if (adaptiveRangeTargetBytes >= _streamRangeTargetBytes) return;
      successfulBytesSinceRangeGrow += bytes;
      if (successfulBytesSinceRangeGrow < rangeGrowAfterBytes) return;
      final previous = adaptiveRangeTargetBytes;
      var next = adaptiveRangeTargetBytes * 2;
      if (next > _streamRangeTargetBytes) next = _streamRangeTargetBytes;
      adaptiveRangeTargetBytes = next;
      successfulBytesSinceRangeGrow = 0;
      devLog(
        () =>
            'xVeil[content]: swarm-range adapt grow '
            '${cid.substring(0, 12)} target_bytes=$previous'
            '->$adaptiveRangeTargetBytes',
      );
    }

    ({List<int> pieces, NodeId peer, int bytes})? takeRange() {
      if (_cancelledDownloads.contains(cid) || failed || pending.isEmpty) {
        return null;
      }
      final sources = sourceList();
      if (sources.isEmpty) {
        failed = true;
        return null;
      }
      final first = pending.removeAt(0);
      final firstAttempt = attempts[first];
      if (firstAttempt >= maxAttemptsPerPiece()) {
        failed = true;
        return null;
      }
      final pieces = <int>[first];
      var rangeBytes = manifest.pieceLength(first);
      var nextPiece = first + 1;
      while (nextPiece < manifest.pieceCount) {
        final pendingIndex = pending.indexOf(nextPiece);
        if (pendingIndex < 0) break;
        final nextLen = manifest.pieceLength(nextPiece);
        if (pieces.isNotEmpty &&
            rangeBytes + nextLen > adaptiveRangeTargetBytes) {
          break;
        }
        if (attempts[nextPiece] >= maxAttemptsPerPiece()) {
          failed = true;
          return null;
        }
        pending.removeAt(pendingIndex);
        pieces.add(nextPiece);
        rangeBytes += nextLen;
        nextPiece++;
      }
      for (final piece in pieces) {
        attempts[piece]++;
      }
      return (
        pieces: List<int>.unmodifiable(pieces),
        peer: sources[(first + firstAttempt) % sources.length],
        bytes: rangeBytes,
      );
    }

    Future<void> requeueAll(List<int> pieces) async {
      await refreshSources();
      for (final piece in pieces) {
        if (attempts[piece] >= maxAttemptsPerPiece()) {
          failed = true;
          return;
        }
      }
      for (final piece in pieces) {
        if (!completed.contains(piece)) {
          pending.add(piece);
        }
      }
    }

    // Swarm-wide payload progress tick plus per-task last-chunk tracking. The
    // tick lets an individual range reader distinguish "everything is quiet"
    // (global route churn — keep the long idle timeout) from "only MY stream is
    // quiet" (stalled route — abandon early and resume on a fresh stream). The
    // per-task stopwatches let tail hedging pick the quietest in-flight range.
    var swarmPayloadTick = 0;
    int swarmTick() => swarmPayloadTick;
    final activeTasks = <_ActiveRangeTask>{};
    var activeHedges = 0;

    void emitProgress() {
      if (_contentProgress.isClosed) return;
      _contentProgress.add((
        contentId: cid,
        done: completedBytes.clamp(0, manifest.size).toInt(),
        total: manifest.size,
      ));
    }

    void recordPulled(
      ({NodeId peer, ContentManifest manifest, List<int> pieces}) pulled,
    ) {
      completionPeer = pulled.peer;
      completionManifest = pulled.manifest;
      for (final piece in pulled.pieces) {
        if (!completed.add(piece)) continue;
        completedBytes += manifest.pieceLength(piece);
      }
      emitProgress();
    }

    _ActiveRangeTask? takeHedge() {
      if (activeHedges >= _maxStreamRangeHedges) return null;
      _ActiveRangeTask? best;
      for (final task in activeTasks) {
        if (task.hedges > 0) continue;
        if (task.lastChunk.elapsed < _streamRangeHedgeAfter) continue;
        if (best == null || task.lastChunk.elapsed > best.lastChunk.elapsed) {
          best = task;
        }
      }
      if (best == null) return null;
      best.hedges++;
      return best;
    }

    Future<void> runHedge(_ActiveRangeTask hedge) async {
      final pieces = hedge.pieces
          .where((piece) => !completed.contains(piece))
          .toList(growable: false);
      if (pieces.isEmpty) return;
      activeHedges++;
      activeRangeWorkers++;
      var hedgeBytes = 0;
      for (final piece in pieces) {
        hedgeBytes += manifest.pieceLength(piece);
      }
      devLog(
        () =>
            'xVeil[content]: swarm-range hedge ${cid.substring(0, 12)} '
            'p${pieces.first}..${pieces.last} '
            'silent=${hedge.lastChunk.elapsed.inMilliseconds}ms',
      );
      try {
        final pulled = await _pullPieceRangeToStorage(
          hedge.peer,
          manifest,
          pieces,
          writePiece: writePiece,
          beforeStreamOpen: beforeStreamOpen,
          swarmTick: swarmTick,
          onPayloadChunk: () => swarmPayloadTick++,
        );
        // A failed hedge is not a transfer failure: the original worker still
        // owns the range's retry/requeue budget, so do not shrink the adaptive
        // fanout for it either.
        if (pulled == null) return;
        noteRangeSuccess(hedgeBytes);
        recordPulled(pulled);
      } finally {
        activeRangeWorkers--;
        activeHedges--;
      }
    }

    Future<void> worker(int index) async {
      while (!_disposed && !_cancelledDownloads.contains(cid) && !failed) {
        while (!_disposed &&
            !_cancelledDownloads.contains(cid) &&
            !failed &&
            activeRangeWorkers >= adaptiveWorkerLimit) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final task = takeRange();
        if (task == null) {
          if (_disposed || _cancelledDownloads.contains(cid) || failed) return;
          if (completed.length >= manifest.pieceCount) return;
          if (pending.isNotEmpty) continue; // requeue raced takeRange
          // Tail: every remaining piece is in flight on another worker. Hedge
          // the quietest range on a fresh stream instead of exiting, so one
          // stalled route cannot pin the transfer until its idle timeout.
          final hedge = takeHedge();
          if (hedge != null) {
            await runHedge(hedge);
            continue;
          }
          if (activeTasks.isEmpty) return;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        final tracked = _ActiveRangeTask(task.pieces, task.peer);
        activeTasks.add(tracked);
        activeRangeWorkers++;
        ({NodeId peer, ContentManifest manifest, List<int> pieces})? pulled;
        try {
          pulled = await _pullPieceRangeToStorage(
            task.peer,
            manifest,
            task.pieces,
            writePiece: writePiece,
            beforeStreamOpen: beforeStreamOpen,
            swarmTick: swarmTick,
            onPayloadChunk: () {
              swarmPayloadTick++;
              tracked.lastChunk
                ..reset()
                ..start();
            },
          );
        } finally {
          activeRangeWorkers--;
          activeTasks.remove(tracked);
        }
        if (pulled == null) {
          if (task.pieces.every(completed.contains)) {
            // A hedge finished this range while the original attempt was
            // failing — nothing to requeue and no failure to adapt on.
            continue;
          }
          noteRangeFailure(task.pieces);
          await requeueAll(task.pieces);
          final nextDelayAttempt = task.pieces.fold<int>(
            0,
            (maxAttempt, piece) =>
                attempts[piece] > maxAttempt ? attempts[piece] : maxAttempt,
          );
          await Future<void>.delayed(_streamPullRetryDelay(nextDelayAttempt));
          continue;
        }
        noteRangeSuccess(task.bytes);
        recordPulled(pulled);
      }
    }

    devLog(
      () =>
          'xVeil[content]: swarm-range start ${cid.substring(0, 12)} '
          'pieces=${manifest.pieceCount} workers=$workerCount '
          'active_limit=$adaptiveWorkerLimit '
          'target_bytes=$_streamRangeTargetBytes '
          'open_pace_ms=${_streamRangeOpenPace.inMilliseconds} '
          'sources=${sourceMap.length} resume=${completed.length} '
          'attempts_per_piece=${maxAttemptsPerPiece()}',
    );
    await Future.wait<void>([for (var i = 0; i < workerCount; i++) worker(i)]);
    if (_cancelledDownloads.contains(cid) ||
        failed ||
        completed.length < manifest.pieceCount ||
        (sink == null && !await _storage.hasFile(cid))) {
      devLog(
        () =>
            'xVeil[content]: swarm-range incomplete '
            '${cid.substring(0, 12)} completed=${completed.length}/'
            '${manifest.pieceCount} failed=$failed',
      );
      return false;
    }
    if (!await _finishReceived(
      completionPeer ?? sourceList().first,
      completionManifest ?? manifest,
      sink,
      savedPath,
    )) {
      return false;
    }
    if (!_contentProgress.isClosed) {
      _contentProgress.add((
        contentId: cid,
        done: manifest.size,
        total: manifest.size,
      ));
    }
    return true;
  }

  Future<({NodeId peer, ContentManifest manifest, List<int> pieces})?>
  _pullPieceRangeToStorage(
    NodeId peer,
    ContentManifest expected,
    List<int> pieceIndices, {
    required Future<void> Function(int pieceIndex, Uint8List piece) writePiece,
    Future<void> Function()? beforeStreamOpen,
    int Function()? swarmTick,
    void Function()? onPayloadChunk,
  }) async {
    final cid = expected.contentId;
    if (pieceIndices.isEmpty) return null;
    final pieces = pieceIndices.toList(growable: false);
    final firstPiece = pieces.first;
    final lastPiece = pieces.last;
    final offset = firstPiece * expected.pieceSize;
    var rangeLen = 0;
    for (final piece in pieces) {
      rangeLen += expected.pieceLength(piece);
    }
    if (beforeStreamOpen != null) await beforeStreamOpen();
    final stream = await _openInitialPullStream(peer, cid);
    if (stream == null) return null;
    ReliableStream? current = stream;
    var failed = false;
    try {
      final pulled = await _readRangePayloadResumable(
        peer,
        expected,
        current,
        offset: offset,
        rangeLen: rangeLen,
        firstPiece: firstPiece,
        lastPiece: lastPiece,
        beforeStreamOpen: beforeStreamOpen,
        swarmTick: swarmTick,
        onPayloadChunk: onPayloadChunk,
      );
      current = null; // consumed/closed by _readRangePayloadResumable
      final m = pulled.manifest;
      final range = pulled.bytes;
      var cursor = 0;
      final verifiedPieces = <({int index, Uint8List bytes})>[];
      for (final pieceIndex in pieces) {
        final pieceLen = expected.pieceLength(pieceIndex);
        final piece = Uint8List.sublistView(range, cursor, cursor + pieceLen);
        if (!expected.verifyPiece(pieceIndex, piece)) {
          throw StateError('piece $pieceIndex failed verify');
        }
        verifiedPieces.add((index: pieceIndex, bytes: piece));
        cursor += pieceLen;
      }
      for (final piece in verifiedPieces) {
        await writePiece(piece.index, piece.bytes);
      }
      return (peer: peer, manifest: m, pieces: pieces);
    } catch (e) {
      failed = true;
      devLog(
        () =>
            'xVeil[content]: swarm-range piece failed '
            '${cid.substring(0, 12)} p$firstPiece..$lastPiece '
            '<- ${peer.short}: $e',
      );
      return null;
    } finally {
      try {
        if (failed) {
          await current?.abort();
        } else {
          await current?.close();
        }
      } catch (_) {}
    }
  }

  /// Await one payload chunk while watching for a per-stream stall.
  ///
  /// The underlying FFI read blocks a worker isolate until data arrives or the
  /// stream is aborted, so the read future cannot be cancelled directly. This
  /// polls the same future in short slices and throws when either the full
  /// [idle] window elapses ([TimeoutException], same semantics as before) or
  /// the swarm made progress elsewhere while this stream stayed silent for at
  /// least [stallAfter] ([_RangeStallTimeout]); the caller then aborts the
  /// stream, which releases the blocked read.
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

  Future<({ContentManifest manifest, Uint8List bytes})>
  _readRangePayloadResumable(
    NodeId peer,
    ContentManifest expected,
    ReliableStream initialStream, {
    required int offset,
    required int rangeLen,
    required int firstPiece,
    required int lastPiece,
    Future<void> Function()? beforeStreamOpen,
    int Function()? swarmTick,
    void Function()? onPayloadChunk,
  }) async {
    final cid = expected.contentId;
    final idle = _streamPayloadIdleTimeout < _streamRangePayloadIdleTimeout
        ? _streamPayloadIdleTimeout
        : _streamRangePayloadIdleTimeout;
    final out = BytesBuilder(copy: false);
    ContentManifest? manifest;
    ReliableStream? current = initialStream;
    var got = 0;
    Object? lastError;
    for (
      var attempt = 1;
      got < rangeLen &&
          attempt <= _streamPullMaxAttempts &&
          !_disposed &&
          !_cancelledDownloads.contains(cid);
      attempt++
    ) {
      final startGot = got;
      try {
        if (current == null && beforeStreamOpen != null) {
          await beforeStreamOpen();
        }
        current ??= await _openRetryStream(
          peer,
          cid,
          attempt,
          timeout: _streamRangeRetryOpenTimeout,
        );
        if (current == null) throw StateError('range retry-open unavailable');
        final remaining = rangeLen - got;
        final resumeOffset = offset + got;
        final req = _streamRequest(
          cid,
          offset: resumeOffset,
          length: remaining,
        );
        // veil_anon_stream_open returns once the local stream FSM exists; on the
        // datagram-backed anonymous stream the peer accept can trail by a few
        // milliseconds. A tiny grace before the first DATA frame avoids the
        // observed open/accept/no-request race without affecting bulk throughput.
        await Future<void>.delayed(_streamOpenWriteGrace);
        await current.write(req).timeout(_streamRequestTimeout);
        final lenB = await _readExactly(
          current,
          4,
        ).timeout(_streamManifestTimeout, onTimeout: () => null);
        if (lenB == null) throw StateError('no manifest (sender not serving)');
        final mfLen = _readU32be(lenB);
        if (mfLen <= 0 || mfLen > (1 << 20)) {
          throw StateError('bad manifest len');
        }
        final mfBytes = await _readExactly(
          current,
          mfLen,
        ).timeout(_streamManifestTimeout, onTimeout: () => null);
        if (mfBytes == null) throw StateError('manifest truncated');
        final m = ContentManifest.fromJson(
          jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
        );
        if (m == null ||
            m.contentId != cid ||
            m.size != expected.size ||
            m.pieceSize != expected.pieceSize ||
            m.pieceCount != expected.pieceCount) {
          throw StateError('manifest does not bind requested piece range');
        }
        final previous = manifest;
        if (previous != null &&
            (previous.size != m.size ||
                previous.pieceSize != m.pieceSize ||
                previous.pieceCount != m.pieceCount ||
                previous.contentId != m.contentId)) {
          throw StateError('manifest changed across range resume');
        }
        manifest ??= m;
        _bulkStreamLog(
          () =>
              'xVeil[content]: swarm-range payload '
              '${cid.substring(0, 12)} p$firstPiece..$lastPiece '
              '<- ${peer.short} (${got > 0 ? 'resume=$got/' : ''}$rangeLen)',
        );
        final silence = Stopwatch()..start();
        var tickAtLastChunk = swarmTick?.call() ?? 0;
        while (got < rangeLen) {
          final nextRemaining = rangeLen - got;
          final maxBytes = nextRemaining < _streamReadChunk
              ? nextRemaining
              : _streamReadChunk;
          final chunk = await _awaitPayloadChunk(
            current.read(maxBytes: maxBytes),
            idle: idle,
            stallAfter: _streamRangeStallAbandon,
            silence: silence,
            tickAtLastChunk: tickAtLastChunk,
            swarmTick: swarmTick,
            timeoutLabel: (reason) =>
                'pieces $firstPiece..$lastPiece $reason after $got/$rangeLen',
          );
          if (chunk.isEmpty) {
            throw StateError(
              'pieces $firstPiece..$lastPiece EOF after $got/$rangeLen',
            );
          }
          out.add(chunk);
          got += chunk.length;
          onPayloadChunk?.call();
          silence
            ..reset()
            ..start();
          tickAtLastChunk = swarmTick?.call() ?? 0;
        }
      } catch (e) {
        lastError = e;
        if (got > startGot || got > 0) {
          devLog(
            () =>
                'xVeil[content]: swarm-range resume '
                '${cid.substring(0, 12)} p$firstPiece..$lastPiece '
                '<- ${peer.short} got=$got/$rangeLen after: $e',
          );
        }
        try {
          await current?.abort();
        } catch (_) {}
        current = null;
        // A zero-byte attempt normally means "sender not serving this range" —
        // fail the range so the swarm can requeue it elsewhere. A stall
        // abandon is different: the swarm was demonstrably progressing while
        // this stream sat on a bad route, so retry in place on a fresh stream
        // even before the first payload byte.
        if ((got <= 0 && e is! _RangeStallTimeout) ||
            attempt >= _streamPullMaxAttempts ||
            _disposed ||
            _cancelledDownloads.contains(cid)) {
          break;
        }
        if (_disposed || _cancelledDownloads.contains(cid)) break;
        await Future<void>.delayed(_streamPullRetryDelay(attempt));
      }
    }
    try {
      await current?.close();
    } catch (_) {}
    if (got < rangeLen) {
      throw lastError ??
          StateError(
            'pieces $firstPiece..$lastPiece incomplete $got/$rangeLen',
          );
    }
    final m = manifest;
    if (m == null) throw StateError('range completed without manifest');
    return (manifest: m, bytes: out.takeBytes());
  }

  Future<ReliableStream?> _openInitialPullStream(
    NodeId peer,
    String cid,
  ) async {
    if (_disposed || _cancelledDownloads.contains(cid)) return null;
    final t = _transport;
    if (t is! StreamTransport) return null;
    final sw = Stopwatch()..start();
    final useP2P =
        _p2pStreamsEnabled &&
        !_anonymous &&
        t is P2PStreamTransport &&
        await _p2pStreamAllowed(peer);
    _bulkStreamLog(
      () =>
          'xVeil[content]: stream-open ${cid.substring(0, 12)} '
          '-> ${peer.short} (${useP2P ? 'p2p' : 'anon'})',
    );
    final slowLog = Timer(const Duration(seconds: 5), () {
      devLog(
        () =>
            'xVeil[content]: stream-open still pending '
            '${cid.substring(0, 12)} -> ${peer.short} '
            '(${sw.elapsedMilliseconds}ms)',
      );
    });
    ReliableStream? stream;
    try {
      if (useP2P) {
        stream = await _contentStreams.awaitOpen(
          (t as P2PStreamTransport).openP2PStream(peer),
        );
      }
      if (_disposed || _contentStreams.closing) return null;
      stream ??= await _contentStreams.awaitOpen(
        (t as StreamTransport).openStream(peer),
      );
    } finally {
      slowLog.cancel();
    }
    if (stream == null) {
      devLog(
        () =>
            'xVeil[content]: stream-open unavailable '
            '${cid.substring(0, 12)} -> ${peer.short} '
            '(${sw.elapsedMilliseconds}ms), using datagram fallback',
      );
      return null;
    }
    if (_cancelledDownloads.contains(cid)) {
      await stream.abort();
      return null;
    }
    _bulkStreamLog(
      () =>
          'xVeil[content]: stream-open ok ${cid.substring(0, 12)} '
          '-> ${peer.short} (${sw.elapsedMilliseconds}ms, '
          '${useP2P && stream != null ? 'p2p-or-fallback' : 'anon'})',
    );
    return _trackPullStream(cid, stream);
  }

  Future<bool> _runPull(
    NodeId peer,
    String cid,
    _FetchSink? sink,
    ReliableStream initialStream,
    String? savedPath, {
    bool emitFailure = true,
    Iterable<NodeId> retryPeers = const [],
    bool closeSinkOnFailure = true,
  }) async {
    if (_cancelledDownloads.contains(cid)) {
      await initialStream.abort();
      return false;
    }
    var ok = false;
    Object? lastError;
    ReliableStream? stream = initialStream;
    final peers = _orderedPullPeers(peer, retryPeers);
    // `_streamPullMaxAttempts` protects a single-source transfer from retrying
    // forever, but a group/swarm transfer may know more holders than that cap.
    // Give every known holder at least one stream attempt; after that, cycle up
    // to the configured retry budget.
    final maxAttempts = _streamPullMaxAttempts < peers.length
        ? peers.length
        : _streamPullMaxAttempts;
    ContentManifest? resumeManifest;
    var resumePiece = 0;
    _pullStarted(cid);
    try {
      for (
        var attempt = 1;
        attempt <= maxAttempts &&
            !_disposed &&
            !_cancelledDownloads.contains(cid);
        attempt++
      ) {
        var payloadStarted = false;
        var readBytes = 0;
        var committedPieces = 0;
        Timer? manifestWait;
        final attemptStream = stream;
        stream = null;
        ReliableStream? current;
        final attemptPeer = attemptStream != null
            ? peer
            : peers[(attempt - 1) % peers.length];
        var attemptFailed = false;
        try {
          current =
              attemptStream ??
              await _openRetryStream(attemptPeer, cid, attempt);
          if (current == null) {
            throw StateError('stream retry-open unavailable');
          }
          devLog(
            () =>
                'xVeil[content]: stream-pull request '
                '${cid.substring(0, 12)} -> ${attemptPeer.short} '
                '(attempt $attempt)',
          );
          final resumeFrom = resumeManifest;
          final resumeOffset = resumeFrom == null
              ? 0
              : (resumePiece * resumeFrom.pieceSize)
                    .clamp(0, resumeFrom.size)
                    .toInt();
          // The sender consumes the whole fixed-size request frame. The first
          // 32 bytes are contentId; bytes 32..40 carry an optional big-endian
          // resume offset; bytes 40..48 carry an optional requested length.
          // Keep this first write to a single onion-stream cell: padding this
          // to several cells created a request burst before payload pacing had
          // a chance to smooth the transfer.
          final req = _streamRequest(cid, offset: resumeOffset);
          await Future<void>.delayed(_streamOpenWriteGrace);
          await current.write(req).timeout(_streamRequestTimeout);
          devLog(
            () =>
                'xVeil[content]: stream-pull request sent '
                '${cid.substring(0, 12)} -> ${attemptPeer.short} '
                '(${req.length}B'
                '${resumeOffset > 0 ? ', resume=$resumeOffset' : ''}, '
                'attempt $attempt)',
          );
          manifestWait = Timer(const Duration(seconds: 5), () {
            devLog(
              () =>
                  'xVeil[content]: stream-pull waiting manifest '
                  '${cid.substring(0, 12)} <- ${attemptPeer.short} '
                  '(attempt $attempt)',
            );
          });
          // First-byte stall (length prefix): a sender that never emits the
          // 4-byte manifest length is not serving on this stream — the request
          // never landed (flaky/stale first circuit) or the serve source is
          // absent. Abandon it on the SHORTER bound so we retry-open (a fresh
          // circuit, often a different route) fast instead of eating the full
          // 25s cap on a silent first attempt — device-observed as ~25s "долго
          // перед скачиванием" before attempt 2 succeeds. Once the length
          // prefix arrives the manifest BODY keeps the full timeout (patient
          // once bytes actually flow). Mirrors the probe path (_readManifestHeader).
          final firstByteTimeout =
              streamManifestFirstByteTimeout < _streamManifestTimeout
              ? streamManifestFirstByteTimeout
              : _streamManifestTimeout;
          final lenB = await _readExactly(
            current,
            4,
          ).timeout(firstByteTimeout, onTimeout: () => null);
          manifestWait.cancel();
          manifestWait = null;
          if (lenB == null) {
            throw StateError('no manifest (sender not serving)');
          }
          final mfLen = _readU32be(lenB);
          if (mfLen <= 0 || mfLen > (1 << 20)) {
            throw StateError('bad manifest len');
          }
          final mfBytes = await _readExactly(
            current,
            mfLen,
          ).timeout(_streamManifestTimeout, onTimeout: () => null);
          if (mfBytes == null) throw StateError('manifest truncated');
          final m = ContentManifest.fromJson(
            jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
          );
          if (m == null || m.contentId != cid) {
            throw StateError('manifest does not bind the requested cid');
          }
          final previous = resumeManifest;
          if (previous != null &&
              (previous.size != m.size ||
                  previous.pieceSize != m.pieceSize ||
                  previous.pieceCount != m.pieceCount ||
                  previous.contentId != m.contentId)) {
            throw StateError('manifest changed across resume');
          }
          resumeManifest ??= m;
          unawaited(_persistManifestIfPending(m));
          final startPiece = resumeOffset > 0
              ? (resumeOffset ~/ m.pieceSize).clamp(0, m.pieceCount)
              : 0;
          readBytes = (startPiece * m.pieceSize).clamp(0, m.size).toInt();
          payloadStarted = true;
          devLog(
            () =>
                'xVeil[content]: stream-pull ${cid.substring(0, 12)} '
                '(${m.size}B, ${m.pieceCount} pieces) <- ${attemptPeer.short} '
                '(attempt $attempt'
                '${readBytes > 0 ? ', resume=$readBytes' : ''})',
          );
          if (!_contentProgress.isClosed) {
            _contentProgress.add((
              contentId: cid,
              done: readBytes,
              total: m.size,
            ));
          }
          var lastProgressBytes = readBytes;
          var lastProgressMs = 0;
          final progressSw = Stopwatch()..start();
          const minProgressBytes = 1024 * 1024; // avoid UI backpressure
          const minProgressMs = 1000;
          void emitReadProgress() {
            if (_contentProgress.isClosed || m.size <= 0) return;
            final elapsedMs = progressSw.elapsedMilliseconds;
            if (readBytes < m.size &&
                readBytes - lastProgressBytes < minProgressBytes &&
                elapsedMs - lastProgressMs < minProgressMs) {
              return;
            }
            final visibleDone = readBytes < m.size ? readBytes : m.size - 1;
            _contentProgress.add((
              contentId: cid,
              done: visibleDone,
              total: m.size,
            ));
            lastProgressBytes = readBytes;
            lastProgressMs = elapsedMs;
          }

          final buf = BytesBuilder(copy: false);
          var bufLen = 0;
          for (var pi = startPiece; pi < m.pieceCount; pi++) {
            final pieceLen = m.pieceLength(pi);
            while (bufLen < pieceLen) {
              final chunk = await current
                  .read(maxBytes: _streamReadChunk)
                  .timeout(
                    _streamPayloadIdleTimeout,
                    onTimeout: () => throw TimeoutException(
                      'payload idle after $readBytes/${m.size}B',
                      _streamPayloadIdleTimeout,
                    ),
                  );
              if (chunk.isEmpty) throw StateError('stream EOF mid-piece $pi');
              buf.add(chunk);
              bufLen += chunk.length;
              readBytes = (readBytes + chunk.length).clamp(0, m.size).toInt();
              emitReadProgress();
            }
            final acc = buf.takeBytes(); // clears buf
            final piece = acc.length == pieceLen
                ? acc
                : Uint8List.sublistView(acc, 0, pieceLen);
            if (!m.verifyPiece(pi, piece)) {
              throw StateError('piece $pi failed verify');
            }
            if (sink != null) {
              await sink.write(pi * m.pieceSize, piece);
            } else {
              await _storage.storeFilePiece(
                cid,
                pi,
                m.pieceCount,
                m.pieceSize,
                m.size,
                piece,
                name: m.name,
              );
            }
            committedPieces++;
            if (acc.length > pieceLen) {
              buf.add(Uint8List.sublistView(acc, pieceLen));
              bufLen = acc.length - pieceLen;
            } else {
              bufLen = 0;
            }
          }
          if (_cancelledDownloads.contains(cid) ||
              !await _finishReceived(attemptPeer, m, sink, savedPath)) {
            lastError = StateError('download finalization failed');
            break;
          }
          ok = true;
          if (!_contentProgress.isClosed) {
            _contentProgress.add((contentId: cid, done: m.size, total: m.size));
          }
          break;
        } catch (e) {
          attemptFailed = true;
          lastError = e;
          if (payloadStarted && committedPieces > 0) {
            final completed = (resumePiece + committedPieces)
                .clamp(
                  0,
                  resumeManifest?.pieceCount ?? resumePiece + committedPieces,
                )
                .toInt();
            if (completed > resumePiece) {
              resumePiece = completed;
              final m = resumeManifest;
              final resumeBytes = m == null
                  ? 0
                  : (resumePiece * m.pieceSize).clamp(0, m.size).toInt();
              devLog(
                () =>
                    'xVeil[content]: stream-pull resume point '
                    '${cid.substring(0, 12)} piece=$resumePiece '
                    'offset=$resumeBytes after attempt $attempt',
              );
            }
          }
          devLog(
            () =>
                'xVeil[content]: stream-pull attempt $attempt failed '
                '${cid.substring(0, 12)}: $e',
          );
          if (attempt == maxAttempts ||
              _disposed ||
              _cancelledDownloads.contains(cid)) {
            break;
          }
        } finally {
          manifestWait?.cancel();
          try {
            if (attemptFailed) {
              await current?.abort();
            } else {
              await current?.close();
            }
          } catch (_) {}
        }

        await Future<void>.delayed(_streamPullRetryDelay(attempt));
      }
    } finally {
      _pullEnded(cid);
      if (!ok && lastError != null) {
        devLog(
          () =>
              'xVeil[content]: stream-pull failed '
              '${cid.substring(0, 12)}: $lastError',
        );
      }
      if (!ok &&
          !_cancelledDownloads.contains(cid) &&
          sink != null &&
          closeSinkOnFailure) {
        try {
          await sink.close();
        } catch (_) {}
        _fetchSavePath.remove(cid);
      }
      if (!ok &&
          !_cancelledDownloads.contains(cid) &&
          emitFailure &&
          !_contentFailed.isClosed) {
        _contentFailed.add(cid);
      }
    }
    return ok;
  }

  Future<ReliableStream?> _openRetryStream(
    NodeId peer,
    String cid,
    int attempt, {
    Duration? timeout,
  }) async {
    if (_disposed || _cancelledDownloads.contains(cid)) return null;
    final t = _transport;
    if (t is! StreamTransport) return null;
    final streamTransport = t as StreamTransport;
    final useP2P =
        _p2pStreamsEnabled &&
        !_anonymous &&
        t is P2PStreamTransport &&
        await _p2pStreamAllowed(peer);
    devLog(
      () =>
          'xVeil[content]: stream-pull retry-open '
          '${cid.substring(0, 12)} -> ${peer.short} '
          '(attempt $attempt, ${useP2P ? 'p2p' : 'anon'})',
    );
    try {
      ReliableStream? stream;
      if (useP2P) {
        stream = await _contentStreams.awaitOpen(
          (t as P2PStreamTransport).openP2PStream(peer),
          timeout: timeout ?? _streamRequestTimeout,
        );
      }
      if (_disposed || _contentStreams.closing) return null;
      stream ??= await _contentStreams.awaitOpen(
        streamTransport.openStream(peer),
        timeout: timeout ?? _streamRequestTimeout,
      );
      if (stream == null) return null;
      if (_cancelledDownloads.contains(cid)) {
        await stream.abort();
        return null;
      }
      return _trackPullStream(cid, stream);
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: stream-pull retry-open failed '
            '${cid.substring(0, 12)} -> ${peer.short}: $e',
      );
      return null;
    }
  }

  ReliableStream _trackPullStream(String contentId, ReliableStream stream) {
    return _contentStreams.trackPull(contentId, stream);
  }

  static Duration _streamPullRetryDelay(int attempt) {
    final ms = 250 * attempt;
    return Duration(milliseconds: ms > 3000 ? 3000 : ms);
  }

  /// Finalise a completed RECEIVE: an unencrypted-to-file download closes the
  /// sink, remembers the path (tap → open), and reports it; an in-app store
  /// surfaces offer→downloaded. Acks the sender either way (flips sent→delivered).
  Future<bool> _finishReceived(
    NodeId peer,
    ContentManifest m,
    _FetchSink? sink,
    String? savedPath,
  ) async {
    final ackId = m.msgId ?? m.contentId;
    if (sink != null) {
      try {
        await sink.close();
      } catch (e) {
        devLog(
          () =>
              'xVeil[content]: plaintext close failed '
              '${m.contentId.substring(0, 12)} -> $savedPath: $e',
        );
        if (!_contentFailed.isClosed) _contentFailed.add(m.contentId);
        return false;
      }
      if (savedPath != null) {
        try {
          await _storage.putSetting('saved:${m.contentId}', savedPath);
          // Serve the saved plaintext back on demand (content-addressed): the
          // ORIGINAL SENDER can recover a file they deleted, and any accepted
          // holder can re-seed. Mirrors the sender's serve-from-source model —
          // persist the manifest + the serve path so a stream request / reoffer
          // reopens the file. If the user later moves or deletes this plain
          // file, the reopen fails and the peer gets an honest content-GONE.
          await _persistServeManifest(m);
          // JSON record with the hashing params, so a missing mf: blob
          // (IndexFull) can be rebuilt from the saved file — same contract as
          // the sender-side durable offer.
          await _storage.putSetting(
            'served:${m.contentId}',
            jsonEncode({
              'path': savedPath,
              'size': m.size,
              'pieceSize': m.pieceSize,
              'name': m.name,
            }),
          );
          // Durable-only (no RAM _serving entry): every serve/reoffer reopens
          // the file from served:<cid>, so a since-moved/deleted plain file is
          // detected and answered with content-GONE instead of a false offer.
        } catch (_) {}
      }
      _fetchSavePath.remove(m.contentId);
      devLog(
        () =>
            'xVeil[content]: COMPLETE ${m.contentId.substring(0, 12)} '
            '(${m.size}B) saved to $savedPath (serveable)',
      );
      await _send(peer, WireEnvelope.ack(ackId).encode());
      if (!_contentReceived.isClosed) {
        _contentReceived.add((
          contentId: m.contentId,
          name: m.name,
          savedToPath: savedPath,
        ));
      }
      _clearGroupPullSources(m.contentId);
      return true;
    }
    devLog(
      () =>
          'xVeil[content]: COMPLETE ${m.contentId.substring(0, 12)} '
          '(${m.size}B) stored',
    );
    final persisted = await _persistReceivedContent(peer, m);
    if (persisted) await _send(peer, WireEnvelope.ack(ackId).encode());
    if (persisted) _clearGroupPullSources(m.contentId);
    if (persisted && await _consumeParkedPlainFileSave(m.contentId)) {
      return true;
    }
    if (!_contentReceived.isClosed) {
      _contentReceived.add((
        contentId: m.contentId,
        name: m.name,
        savedToPath: null,
      ));
    }
    return persisted;
  }

  /// Read EXACTLY [n] bytes (looping); null on EOF before [n] arrives.
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

  Future<void> _onPieceChunk(PieceChunkFrame f) async {
    final fetch = _contentFetching.active(f.contentId);
    if (fetch == null) {
      // The manifest never arrived (or this content was already completed/
      // deleted): we hold no reassembler, so the chunk is dropped. A burst of
      // these means a LOST MANIFEST — the receiver can't reassemble or
      // re-request without it.
      devLog(
        () =>
            'xVeil[content]: pieceChunk DROPPED — no manifest/fetch for '
            '${f.contentId.substring(0, 12)} (p${f.pieceIndex} c${f.chunkIndex})',
      );
      return; // not fetching this content
    }
    _contentFetching.touch(f.contentId); // progress — keep this fetch non-stale
    final piece = fetch.xfer.addChunk(
      f.pieceIndex,
      f.chunkIndex,
      f.chunkCount,
      f.data,
    );
    if (piece != null) {
      // Stream the verified piece STRAIGHT to its destination; the reassembler
      // keeps no piece bytes, so the whole file never sits in RAM (any size).
      final m = fetch.manifest;
      try {
        if (fetch.sink != null) {
          // UNENCRYPTED download → write the piece to the user's plaintext file
          // at its byte offset; nothing is kept in the app.
          await fetch.sink!.write(f.pieceIndex * m.pieceSize, piece);
        } else {
          // Store via the Storage port (encrypted on-disk tier / in-volume).
          await _storage.storeFilePiece(
            m.contentId,
            f.pieceIndex,
            m.pieceCount,
            m.pieceSize,
            m.size,
            piece,
            name: m.name,
          );
        }
      } catch (e) {
        fetch.xfer.unverify(f.pieceIndex); // write failed → re-request it
        devLog(
          () =>
              'xVeil[content]: piece ${f.pieceIndex} store/write failed '
              'for ${m.contentId.substring(0, 12)}: $e',
        );
        return;
      }
      devLog(
        () =>
            'xVeil[content]: piece ${f.pieceIndex} VERIFIED+'
            '${fetch.sink != null ? 'WRITTEN' : 'STORED'} for '
            '${m.contentId.substring(0, 12)} '
            '(${fetch.xfer.verifiedCount}/${fetch.xfer.pieceCount})',
      );
      if (!_contentProgress.isClosed) {
        _contentProgress.add((
          contentId: f.contentId,
          done: fetch.xfer.verifiedCount,
          total: fetch.xfer.pieceCount,
        ));
      }
    }
    if (!fetch.xfer.isComplete) return;
    // Every piece verified AND written → done.
    _contentFetching.take(f.contentId);
    final ackId = fetch.manifest.msgId ?? f.contentId;
    final sink = fetch.sink;
    if (sink != null) {
      // UNENCRYPTED-to-file: the bytes are on the user's disk, NOT in the app —
      // so no offer→downloaded flip; just finalise the file, ack (we received
      // it), and tell the UI where it landed.
      final savedPath = _fetchSavePath.remove(f.contentId);
      try {
        await sink.close();
      } catch (e) {
        devLog(
          () =>
              'xVeil[content]: plaintext close failed '
              '${f.contentId.substring(0, 12)} -> $savedPath: $e',
        );
        if (!_contentFailed.isClosed) _contentFailed.add(f.contentId);
        return;
      }
      // Remember where it landed so a later tap OPENS the file instead of
      // re-offering it (it isn't in the app store → hasFile is false).
      if (savedPath != null) {
        try {
          await _storage.putSetting('saved:${f.contentId}', savedPath);
        } catch (_) {
          /* non-fatal */
        }
      }
      devLog(
        () =>
            'xVeil[content]: COMPLETE ${f.contentId.substring(0, 12)} '
            '(${fetch.manifest.size}B) saved UNENCRYPTED to $savedPath',
      );
      await _send(fetch.peer, WireEnvelope.ack(ackId).encode());
      if (!_contentReceived.isClosed) {
        _contentReceived.add((
          contentId: f.contentId,
          name: fetch.name,
          savedToPath: savedPath,
        ));
      }
      return;
    }
    // Stored in the app (encrypted tier / in-volume) → surface offer→downloaded.
    devLog(
      () =>
          'xVeil[content]: COMPLETE ${f.contentId.substring(0, 12)} '
          '(${fetch.manifest.size}B) streamed to disk',
    );
    final persisted = await _persistReceivedContent(fetch.peer, fetch.manifest);
    // Ack by the per-send msgId (the EVENT identity) so the SENDER's specific
    // file message flips sent->delivered = actually received (a legacy sender
    // without msgId falls back to the contentId — old behaviour).
    if (persisted) {
      devLog(
        () =>
            'xVeil[timeline]: content-ack id=$ackId '
            'via=direct t=${DateTime.now().millisecondsSinceEpoch}',
      );
      await _send(fetch.peer, WireEnvelope.ack(ackId).encode());
    }
    if (persisted && await _consumeParkedPlainFileSave(f.contentId)) {
      return;
    }
    if (!_contentReceived.isClosed) {
      _contentReceived.add((
        contentId: f.contentId,
        name: fetch.name,
        savedToPath: null,
      ));
    }
  }

  /// A content transfer completed: its pieces were already streamed to disk
  /// (storeFilePiece in [_onPieceChunk]), so the blob is hasFile-complete. Ensure
  /// the OFFER message exists (idempotent) so it flips offer → downloaded, then
  /// signal. Returns true (safe to ack = delivered = actually received).
  Future<bool> _persistReceivedContent(NodeId peer, ContentManifest m) async {
    _contentAvailability.forgetOffer(m.contentId);
    await _surfaceFileOffer(peer, m);
    await _persistServeManifest(m);
    _serving[m.contentId] = (manifest: m, source: null, servedAt: _now());
    _evictServing();
    _ensureContentTimer();
    _signal();
    return true;
  }

  /// Surface a received file as an incoming filePost — an OFFER carrying the
  /// descriptor (name/size + the contentId to download on demand), NOT the blob.
  /// Idempotent on the sender's per-send msgId. A re-send of previously-DELETED
  /// content surfaces as a NEW message (A); a re-delivery of the SAME (deleted)
  /// event stays gone. The "downloaded" state is derived from hasFile(contentId),
  /// so no message rewrite is needed when the blob later lands.
  Future<void> _surfaceFileOffer(NodeId peer, ContentManifest m) async {
    await _surfaceFileOfferFields(
      peer,
      contentId: m.contentId,
      name: m.name,
      size: m.size,
      msgId: m.msgId,
      seq: m.seq,
      ts: m.ts,
      thumb: m.thumbB64,
    );
  }

  Future<void> _surfaceFileOfferFields(
    NodeId peer, {
    required String contentId,
    required String name,
    required int size,
    String? msgId,
    int? seq,
    int? ts,
    String? thumb,
  }) async {
    final msgIdOrContent = msgId ?? contentId; // legacy sender → hash id
    if (await _hasMessage(peer, msgIdOrContent)) {
      devLog(
        () =>
            'xVeil[content]: offer skip ${contentId.substring(0, 12)} '
            'msg ${msgIdOrContent.substring(0, 8)} already stored <- ${peer.short}',
      );
      return; // already surfaced
    }
    if (await _storage.isMessageDeleted(peer.hex, msgIdOrContent)) {
      devLog(
        () =>
            'xVeil[content]: offer skip ${contentId.substring(0, 12)} '
            'msg ${msgIdOrContent.substring(0, 8)} deleted <- ${peer.short}',
      );
      return; // already surfaced / deliberately deleted
    }
    await _store(
      peer,
      MessageDirection.incoming,
      '📎 $name',
      MessageStatus.delivered,
      fileContentId: contentId,
      fileSize: size,
      fileName: name,
      thumb: thumb,
      id: msgIdOrContent,
      seq: seq,
      timestamp: ts != null ? DateTime.fromMillisecondsSinceEpoch(ts) : _now(),
    );
    _emitIncoming(peer, '📎 $name', isFile: true);
    _signal();
    devLog(
      () =>
          'xVeil[content]: offered ${contentId.substring(0, 12)} as msg '
          '${msgIdOrContent.substring(0, 8)} (${size}B) <- ${peer.short}',
    );
  }

  void _ensureContentTimer() => _contentFetching.ensureTimer();

  Future<void> dropLiveServingStateForTest() => _clearServingState();

  Future<void> _clearServingState() => _contentServing.clear();

  Future<void> dispose() async {
    _disposed = true; // stops transfer retry/serve work
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
