import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_server.dart';
import '../api/blob_sources.dart';
import '../api/cloud_api_adapter.dart';
import '../api/direct_file_api.dart';
import '../api/group_api_adapter.dart';
import '../api/webhook_pump.dart';
import '../core/ids.dart';
import '../core/log.dart';
import 'cloud_service.dart';
import '../data/serve_source.dart';
import '../data/transport/bootstrap_invite.dart';
import '../domain/call_signal.dart' show CallMedia;
import '../domain/chat.dart';
import '../domain/group.dart' show GroupRole;
import '../domain/group_call.dart' show GroupCallStatus;
import 'app_controller.dart';
import 'call_service.dart' show callServiceProvider, currentCallProvider;
import 'group_call_service.dart'
    show GroupCallService, groupCallServiceProvider;
import 'group_service_providers.dart';
import 'messaging.dart' show conversationsProvider, messagingServiceProvider;
import 'providers.dart';

export '../api/api_server.dart';

const String _kEnabledKey = 'api.enabled';
const String _kTokensKey = 'api.tokens';
const String _kTokenKey = 'api.token';
const String _kReadOnlyKey = 'api.readonly';
const String _kWebhookKey = 'api.webhook';

class ApiServerController extends Notifier<ApiConfig> {
  /// The port the loopback API binds.
  ///
  /// A knob only so a test can ask for an ephemeral port (0) instead of
  /// racing whatever else holds [kApiPort] on the machine running the suite.
  /// Production never touches it.
  @visibleForTesting
  static int debugBindPort = kApiPort;

  ApiServer? _server;
  int _identityGeneration = 0;
  String? _identityHex;
  Future<void> _reconcileTail = Future<void>.value();

  /// The services the webhook feed is built from, captured SYNCHRONOUSLY at
  /// rewire time. [WebhookPump.setTarget] subscribes after an await, and a
  /// provider read that late can outlive the container that owns it.
  GroupService? _webhookGroups;
  GroupCallService? _webhookGroupCalls;

  /// The webhook feed, bounded and one-at-a-time, and — the reason it replaced
  /// a bare `listen` — able to be silenced. A plain subscription cancel stops
  /// new events and leaves the retries already scheduled for the old URL to
  /// run: about twelve seconds of a previous identity's messages arriving at a
  /// previous identity's webhook (audit X-07). Same pump the headless daemon
  /// uses; the GUI was simply never moved onto it.
  late final WebhookPump _webhookPump = WebhookPump(
    () => _events(_webhookGroups, _webhookGroupCalls),
  );

  @override
  ApiConfig build() {
    ref.onDispose(() {
      _identityGeneration++;
      unawaited(_server?.stop());
      // Retarget, NOT `close()`. A dispose callback registered inside a
      // notifier's `build` runs on every REBUILD — an identity switch is one —
      // while the notifier itself (and this pump) survives. A close here would
      // stick, and the webhook would be silent for the rest of the session
      // after the first switch. Retargeting to null releases exactly what a
      // close would (subscription, queue, client) and stays reusable.
      unawaited(_webhookPump.setTarget(null));
    });
    // The config lives in the (per-identity) deniable store, so it can only be
    // read once the store is UNLOCKED. Gate on the identity being ready — before
    // unlock the store is locked (getSetting throws) and there's nothing to
    // serve anyway. Re-runs when the identity appears (or switches) → reloads.
    // Watch the ACTUAL identity, not only a ready boolean. In a master session
    // `identity != null` stays true across switchIdentity; watching the boolean
    // left the prior identity's token/socket active under the new identity.
    final identityHex = ref.watch(
      appControllerProvider.select((s) => s.identity?.nodeId.hex),
    );
    _identityHex = identityHex;
    final generation = ++_identityGeneration;
    unawaited(_loadIdentity(identityHex, generation));
    // The signer/group service becomes ready asynchronously after identity
    // boot. Rebuild the handler once so group routes/events move 501→live.
    ref.listen<GroupService?>(groupServiceProvider, (previous, next) {
      if (previous != next && state.enabled && _identityHex != null) {
        unawaited(_reconcile(expectedIdentity: _identityHex));
      }
    });
    return ApiConfig.empty;
  }

  Future<void> _loadIdentity(String? identityHex, int generation) async {
    await _server?.stop();
    _server = null;
    await _webhookPump.setTarget(null);
    if (identityHex == null || generation != _identityGeneration) return;
    final st = ref.read(storageProvider);
    try {
      final enabled = (await st.getSetting(_kEnabledKey)) == '1';
      var tokens = <ApiToken>[];
      final raw = await st.getSetting(_kTokensKey);
      if (raw != null && raw.isNotEmpty) {
        final d = jsonDecode(raw);
        if (d is List) {
          tokens = d.map(ApiToken.fromJson).whereType<ApiToken>().toList();
        }
      } else {
        // Migrate the old single-token model (api.token + api.readonly).
        final old = await st.getSetting(_kTokenKey);
        if (old != null && old.isNotEmpty) {
          tokens = [
            ApiToken(
              id: _mintId(),
              name: 'default',
              token: old,
              readOnly: (await st.getSetting(_kReadOnlyKey)) == '1',
            ),
          ];
          await st.putSetting(
            _kTokensKey,
            jsonEncode(tokens.map((t) => t.toJson()).toList()),
          );
        }
      }
      final webhook = await st.getSetting(_kWebhookKey);
      if (generation != _identityGeneration || _identityHex != identityHex) {
        return;
      }
      state = ApiConfig(
        enabled: enabled,
        tokens: tokens,
        webhookUrl: (webhook == null || webhook.isEmpty) ? null : webhook,
      );
      if (enabled && tokens.isNotEmpty) {
        await _reconcile(expectedIdentity: identityHex);
      }
    } catch (e) {
      // Store not ready yet (e.g. mid-unlock) — a later identity change re-runs.
      devLog(() => 'xVeil[api]: config load deferred: $e');
    }
  }

  String _mintToken() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Map<String, dynamic> _status() {
    final id = ref.read(appControllerProvider).identity?.nodeId;
    return {
      'ok': id != null,
      if (id != null) 'nodeId': id.hex,
      if (id != null) 'short': id.short,
      'api': 'v1',
    };
  }

  /// Who is unlocked, which identity is active, and what a master space
  /// manages. Read straight from the controller so it cannot drift from what
  /// the UI shows.
  Future<Map<String, dynamic>> _account() async {
    final app = ref.read(appControllerProvider);
    final id = app.identity?.nodeId;
    return {
      'ok': id != null,
      'phase': app.phase.name,
      if (id != null) 'nodeId': id.hex,
      if (id != null) 'short': id.short,
      'isMaster': app.isMaster,
      if (app.activeIdentity != null) 'activeIdentity': app.activeIdentity,
      'identities': app.identities,
      'api': 'v1',
    };
  }

  /// Lock, and wait for it.
  ///
  /// This used to schedule the lock and return at once, so the endpoint wrote
  /// `200 {"locked": true}` while the tunnel, the node and the container were
  /// all still up — and any failure landed in an unhandled async gap where
  /// nothing could report it. The response was the one thing in the system
  /// that claimed the boundary had closed, and it was written before anything
  /// had been asked to close.
  ///
  /// Locking does tear down this very server, so the answer may never reach
  /// the caller: the API going silent IS the success signal, and the endpoint
  /// says so in its own summary. A failure, by contrast, leaves the server up
  /// to report it — which is the case worth being able to tell apart.
  @visibleForTesting
  /// Lock, and answer what the teardown could not confirm.
  ///
  /// `lock()` deliberately does not throw for a tunnel that would not stop —
  /// parking someone on an unlocked-looking screen because the OS did not
  /// answer is its own failure. The API is not a screen: a caller that asked
  /// for the boundary to close has to be told when it did not
  /// (report17 XV17-M14).
  Future<List<String>> lockForApi() async {
    final controller = ref.read(appControllerProvider.notifier);
    await controller.lock();
    return controller.lastTeardown.incomplete;
  }

  Future<String?> _switchIdentity(String label) async {
    final app = ref.read(appControllerProvider);
    if (!app.isMaster) return 'not a master space';
    if (!app.identities.contains(label)) return 'unknown identity';
    if (app.activeIdentity == label) return null;
    await ref.read(appControllerProvider.notifier).switchIdentity(label);
    // switchIdentity reports through state, not a return value: a refusal
    // leaves the active label untouched.
    return ref.read(appControllerProvider).activeIdentity == label
        ? null
        : 'identity switch refused';
  }

  Future<List<Map<String, dynamic>>> _contacts() async {
    final convos =
        ref.read(conversationsProvider).value ?? const <Conversation>[];
    // Pending requests are listed too, with the status that says so: a client
    // driving this API has no other way to learn that somebody asked to reach
    // it, and accepting needs the node id. See the headless twin.
    return [
      for (final c in convos)
        {
          'nodeId': c.peer.nodeId.hex,
          'short': c.peer.nodeId.short,
          if (c.peer.name != null) 'name': c.peer.name,
          'status': c.peer.status.name,
          'canMessage': c.peer.status == ContactStatus.accepted,
        },
    ];
  }

  /// Ask [target] to be a contact. Null on success, else the reason, which the
  /// handler returns as a 400.
  ///
  /// The refusal comes FIRST and is a real answer, not a validation nicety: a
  /// bare node id gives the node no key to seal to, so the request it would
  /// send can never arrive — see [contactRequestRefusal] for what was measured.
  /// This used to accept one and report `200 {"ok":true}`, having done nothing
  /// but write a `pendingOutgoing` contact nobody would ever answer.
  Future<String?> _requestContact(
    String target,
    String greeting,
    bool Function() moved,
  ) async {
    final refusal = contactRequestRefusal(target);
    if (refusal != null) return refusal;
    try {
      final invite = BootstrapInvite.parse(target);
      final stack = ref.read(realStackProvider);
      if (stack == null) return 'node unavailable';
      // Both services taken now, so the contact lands in the stack that was
      // asked and the greeting goes out over the same pipeline.
      final messaging = ref.read(messagingServiceProvider);
      await stack.addContact(invite);
      // The greeting is the part that reaches another person. If the identity
      // moved while the contact was being added, it is not sent at all — the
      // contact stays in A's stack, where the bearer that asked for it lives.
      if (moved()) return kIdentityChanged;
      final deposited = await messaging.sendRequest(invite.nodeId, greeting);
      // The live leg above is best-effort BY CONTRACT — `boundedLiveLeg`
      // swallows its failure on the stated grounds that "the durable copy and
      // the deposit both stand". When the deposit does NOT stand there is no
      // durable path left, and this send has no retry behind it, so silence
      // here is a request that never happens. Say so instead.
      if (!deposited) {
        return 'the request could not be deposited at the recipient relay — '
            'nothing was sent; try again';
      }
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> _contactAction(String peerHex, String action) async {
    try {
      final peer = NodeId.fromHex(peerHex);
      final messaging = ref.read(messagingServiceProvider);
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

  /// Send a text message to [toHex] via the messaging service. Returns null on
  /// success, or an error string (bad peer / send failure).
  Future<String?> _send(String toHex, String text) async {
    final NodeId peer;
    try {
      peer = NodeId.fromHex(toHex);
    } catch (_) {
      return 'invalid peer';
    }
    try {
      await ref.read(messagingServiceProvider).sendText(peer, text);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// The most-recent [limit] messages of the conversation with [peerHex].
  Future<List<Map<String, dynamic>>> _messages(
    String peerHex,
    int limit,
  ) async {
    final NodeId peer;
    try {
      peer = NodeId.fromHex(peerHex);
    } catch (_) {
      return const [];
    }
    final storage = ref.read(storageProvider);
    final msgs = await storage.loadMessages(peer.hex, limit: limit);
    // One shared projection with the headless daemon's `_messages`. The two
    // used to spell this out separately and both dropped the offer handle.
    return apiMessagesJson(msgs, storage);
  }

  /// Start the opt-in download of an offered 1:1 file. See [fetchDirectFile].
  Future<String?> _fetchFile(String peerHex, String messageId) =>
      fetchDirectFile(
        ref.read(storageProvider),
        ref.read(messagingServiceProvider),
        peerHex,
        messageId,
      );

  /// Opens the file a `POST /v1/files` send streams from. TESTS ONLY — the
  /// production value is [veilOpenSourceForSend] and nothing else sets it.
  @visibleForTesting
  static Future<VeilOpenedSource?> Function(String path) debugSourceOpener =
      veilOpenSourceForSend;

  /// Send the file at local [path] to [toHex] (streamed off disk, any size).
  /// Returns null on success or an error string.
  ///
  /// ONE open, not three. This used to call `exists()`, then `length()`, then
  /// open the name again — and a name pointed somewhere else between the second
  /// and the third produced an offer describing one file's SIZE while hashing
  /// and serving another file's BYTES. That combination is what a receiver
  /// cannot tell from an honest send: the manifest is internally consistent, so
  /// it accepts. Size and bytes now come from the same descriptor
  /// ([veilOpenSourceForSend]), so there is nothing left to disagree.
  ///
  /// What remains is the gap between the API edge's authorization check and
  /// this open, and Dart cannot close it — no `openat`, no `O_NOFOLLOW`.
  /// [veilOpenPinnedSource] narrows it: the name's identity is stamped
  /// immediately before and immediately after the open, and a change refuses
  /// BEFORE anything is offered. The old shape took its first stamp after the
  /// open — so a swap between the edge's check and the open was already in it,
  /// and the comparison was of the attacker's file against itself.
  ///
  /// The comparison across the READ stays, and is detection only: by the time
  /// it fires the offer has been made. It is worth having because the
  /// alternative is that nobody ever finds out.
  Future<String?> _sendFile(
    String toHex,
    String path,
    String? name,
    List<String> roots,
    bool Function() moved,
  ) async {
    final NodeId peer;
    try {
      peer = NodeId.fromHex(toHex);
    } catch (_) {
      return 'invalid peer';
    }
    final messaging = ref.read(messagingServiceProvider);
    final opened = await veilOpenPinnedSource(path, opener: debugSourceOpener);
    if (opened.refusal != null) return opened.refusal;
    final source = opened.source!;
    // Opening the file is the gap this closes. A's token authorized the path;
    // sending it from B would hand B's contact a file out of A's folders.
    // Closed here, because nothing else will: the offer is never built.
    if (moved()) {
      await source.close();
      return kIdentityChanged;
    }
    // [path] arrives resolved and absolute from the API edge, so derive the
    // display name through the URI rather than by splitting on '/' — on
    // Windows that split would hand the peer the whole `C:\…` path as a name.
    final n = (name != null && name.isNotEmpty)
        ? name
        : File(path).uri.pathSegments.last;
    final before = opened.stamp;
    try {
      final cid = await messaging.sendFileStreaming(
        peer,
        n,
        source.size,
        source.read,
        close: source.close,
        sourcePath: path,
        sourceRoots: roots,
      );
      if (cid == null) return 'peer not accepted';
      final after = await veilSourceStamp(path);
      if (before != null && after != null && before != after) {
        devLog(
          () =>
              'xVeil[api]: source at $path changed while it was being read — '
              'the offer for ${cid.substring(0, 12)} was built from it anyway',
        );
        return 'source changed while it was being read; the offer may not '
            'describe the file you named';
      }
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// May a durable offer made under [roots] still be opened from [path]?
  ///
  /// Two questions, both of them live: is the file still inside the folders
  /// that authorized the send, and is any of that still granted to a token
  /// that exists right now. The first catches a folder withdrawn from the
  /// token or moved out from under it; the second catches the token being
  /// revoked outright. Either used to leave the `served:` record happily
  /// serving out of a folder nobody had granted.
  ///
  /// Deliberately re-run on every reopen. A revoke that takes effect when a
  /// cache expires is not a revoke.
  Future<bool> _authorizeServedSource(String path, List<String> roots) async {
    if (await resolveSendableFile(path, roots) == null) return false;
    for (final token in state.tokens) {
      if (token.fileRoots.isEmpty) continue;
      if (await resolveSendableFile(path, token.fileRoots) != null) return true;
    }
    return false;
  }

  Future<ApiBlobSource?> _loadFile(String fileId) =>
      storedBlobSource(ref.read(storageProvider), fileId);

  Future<String?> _placeCall(String toHex, String media) async {
    final NodeId peer;
    try {
      peer = NodeId.fromHex(toHex);
    } catch (_) {
      return 'invalid peer';
    }
    try {
      await ref
          .read(callServiceProvider)
          .placeCall(
            peer,
            CallMedia(
              audio: true,
              video: media == 'video',
              screen: media == 'screen',
            ),
          );
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Map<String, dynamic>? _callState() {
    final c = ref.read(currentCallProvider);
    if (c == null) return null;
    return {
      'callId': c.callId,
      'peer': c.peer.hex,
      'direction': c.direction.name,
      'status': c.status.name,
      'media': {
        'audio': c.media.audio,
        'video': c.media.video,
        'screen': c.media.screen,
      },
      'micOn': c.micOn,
      'cameraOn': c.cameraOn,
    };
  }

  Future<void> _callAction(String action) async {
    final svc = ref.read(callServiceProvider);
    switch (action) {
      case 'hangup':
        await svc.hangup();
      case 'accept':
        await svc.accept();
      case 'reject':
        await svc.reject();
    }
  }

  Future<String?> _startGroupCall(String groupHex, String media) async {
    final groups = ref.read(groupServiceProvider);
    final service = ref.read(groupCallServiceProvider);
    if (groups == null || service == null) return 'group call unavailable';
    final NodeId groupId;
    try {
      groupId = NodeId.fromHex(groupHex);
    } catch (_) {
      return 'invalid group';
    }
    final listed = (await groups.listGroups()).any(
      (entry) => entry.groupId == groupId,
    );
    final bundle = listed ? await groups.load(groupId) : null;
    if (bundle == null || bundle.manifest.isSpace) return 'group not found';
    final state = await groups.stateOf(groupId);
    if (state == null || !state.isMember(groups.selfId)) {
      return 'group not found';
    }
    final started = await service.startCall(
      groupId,
      CallMedia(
        audio: true,
        video: media == 'video' || media == 'screen',
        screen: media == 'screen',
      ),
    );
    return started ? null : 'group call unavailable';
  }

  Future<String?> _startSpaceVoiceSession(
    String spaceHex,
    String channelHex,
    String media,
  ) async {
    final groups = ref.read(groupServiceProvider);
    final service = ref.read(groupCallServiceProvider);
    if (groups == null || service == null) return 'group call unavailable';
    final NodeId spaceId;
    final NodeId channelId;
    try {
      spaceId = NodeId.fromHex(spaceHex);
      channelId = NodeId.fromHex(channelHex);
    } catch (_) {
      return 'invalid space or channel';
    }
    final listed = (await groups.listSpaces()).any(
      (entry) => entry.groupId == spaceId,
    );
    final bundle = listed ? await groups.load(spaceId) : null;
    if (bundle == null || !bundle.manifest.isSpace) return 'space not found';
    final started = await service.startCall(
      spaceId,
      CallMedia(
        audio: true,
        video: media == 'video' || media == 'screen',
        screen: media == 'screen',
      ),
      channelId: channelId,
    );
    return started ? null : 'group call unavailable';
  }

  Map<String, dynamic>? _groupCallState() {
    final groups = ref.read(groupServiceProvider);
    final service = ref.read(groupCallServiceProvider);
    final call = service?.current;
    if (groups == null || service == null || call == null) return null;
    final participants = call.participants.values.toList()
      ..sort((a, b) => a.nodeId.hex.compareTo(b.nodeId.hex));
    return {
      'groupId': call.groupId.hex,
      if (call.channelId != null) 'channelId': call.channelId!.hex,
      'callId': call.callId,
      'initiator': call.initiator.hex,
      'epoch': call.membershipEpoch,
      'status': call.status.name,
      'media': {
        'audio': call.media.audio,
        'video': call.media.video,
        'screen': call.media.screen,
      },
      'participants': [
        for (final participant in participants)
          {
            'nodeId': participant.nodeId.hex,
            'self': participant.nodeId == groups.selfId,
            'audio': participant.media.audio,
            'video': participant.media.video,
            'screen': participant.media.screen,
          },
      ],
      'joined': call.isJoined(groups.selfId),
      'micOn': call.micOn,
      'cameraOn': call.cameraOn,
      'screenOn': call.screenOn,
      'mediaAvailable': service.mediaController != null,
      'endReason': call.endReason?.name,
    };
  }

  Future<String?> _groupCallAction(String action) async {
    final groups = ref.read(groupServiceProvider);
    final service = ref.read(groupCallServiceProvider);
    final call = service?.current;
    if (groups == null || service == null || call == null || !call.isLive) {
      return 'group call action unavailable';
    }
    switch (action) {
      case 'join':
        return await service.join() ? null : 'group call action unavailable';
      case 'decline':
        if (call.status != GroupCallStatus.ringing) {
          return 'group call action unavailable';
        }
        await service.decline();
        return null;
      case 'leave':
        await service.leave();
        return null;
      case 'end':
        final state = await groups.stateOf(call.groupId);
        final role = state?.roleOf(groups.selfId);
        if (role == null || role.rank < GroupRole.admin.rank) {
          return 'operation rejected by group policy';
        }
        return await service.endForEveryone()
            ? null
            : 'group call action unavailable';
      default:
        return 'invalid group call action';
    }
  }

  Future<String?> _groupCallPosture(
    bool? mic,
    bool? camera,
    bool? screen,
  ) async {
    final groups = ref.read(groupServiceProvider);
    final service = ref.read(groupCallServiceProvider);
    var call = service?.current;
    if (groups == null ||
        service == null ||
        call == null ||
        !call.isLive ||
        !call.isJoined(groups.selfId)) {
      return 'group call action unavailable';
    }
    if ((camera == true || screen == true) && !call.media.video) {
      return 'group call media unavailable';
    }
    // Screen enable is the only posture operation that can be unsupported.
    // Attempt it first so a failed multi-field request does not partially
    // mutate microphone/camera state.
    if (screen != null) {
      await service.setScreenShareEnabled(screen);
      call = service.current;
      if (screen && call?.screenOn != true) {
        return 'screen share unavailable';
      }
    }
    if (camera != null) await service.setCameraEnabled(camera);
    if (mic != null) await service.setMicEnabled(mic);
    return null;
  }

  Stream<Map<String, dynamic>> _events(
    GroupService? groups,
    GroupCallService? groupCalls,
  ) => Stream.multi((controller) {
    String? lastGroupCallJson;
    void emitGroupCall() {
      final event = {'type': 'group_call', 'call': _groupCallState()};
      final encoded = jsonEncode(event);
      // Heartbeats refresh internal last-seen timestamps every five
      // seconds. They must not flood bot feeds when public call state did
      // not change.
      if (encoded == lastGroupCallJson) return;
      lastGroupCallJson = encoded;
      controller.add(event);
    }

    final subscriptions = <StreamSubscription<dynamic>>[
      ref
          .read(messagingServiceProvider)
          .incoming
          .listen(
            (notice) => controller.add({
              'type': 'message',
              'from': notice.from.hex,
              'preview': notice.preview,
              'isFile': notice.isFile,
            }),
            onError: controller.addError,
          ),
      if (groups != null)
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
      if (groupCalls != null)
        groupCalls.changes.listen(
          (_) => emitGroupCall(),
          onError: controller.addError,
        ),
    ];
    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
  }, isBroadcast: true);

  /// Bring the socket in line with [state]: run (with a fresh handler carrying
  /// the current token) iff enabled + tokened, else stop. The webhook
  /// subscription follows the same lifecycle (active iff server runs + URL set).
  Future<void> _reconcile({String? expectedIdentity}) {
    final requestedIdentity = expectedIdentity ?? _identityHex;
    final run = _reconcileTail.then((_) => _reconcileNow(requestedIdentity));
    _reconcileTail = run.then<void>((_) {}, onError: (_, _) {});
    return run;
  }

  /// What a request gets when the identity that authorized it is no longer
  /// the one signed in.
  static const String kIdentityChanged = 'identity changed';

  Future<void> _reconcileNow(String? identityAtStart) async {
    if (identityAtStart == null || identityAtStart != _identityHex) return;
    await _server?.stop();
    _server = null;
    await _webhookPump.setTarget(null);
    if (identityAtStart != _identityHex ||
        !state.enabled ||
        state.tokens.isEmpty) {
      // No live grants left to ask about, so the durable offers made under
      // them stop answering. `_openVerifiedServedSource` fails closed on a
      // rooted record with no authorizer, which is the point.
      ref.read(messagingServiceProvider).servedSourceAuthorizer = null;
      return;
    }
    ref.read(messagingServiceProvider).servedSourceAuthorizer =
        _authorizeServedSource;
    final groupService = ref.read(groupServiceProvider);
    final groupApi = groupService == null
        ? null
        : GroupApiAdapter(
            groupService,
            registerContentSource: ref
                .read(messagingServiceProvider)
                .registerGroupContentStreaming,
            loadContent: (contentId) =>
                storedBlobSource(ref.read(storageProvider), contentId),
          );
    final groupCalls = groupService == null
        ? null
        : ref.read(groupCallServiceProvider);
    final cloud = ref.read(cloudServiceProvider);
    final cloudApi = cloud == null
        ? null
        : CloudApiAdapter(
            cloud,
            loadFile: (contentId) =>
                storedBlobSource(ref.read(storageProvider), contentId),
          );
    // The identity these handlers are built for.
    //
    // A bearer token belongs to ONE identity — the tokens themselves are read
    // out of that identity's own store. `stop()` closes the listener and the
    // connections, but a handler already running is a Dart Future that nothing
    // cancels, and every one of these callbacks resolves its services when it
    // runs. So a request authorized by A's token, still in flight when a
    // concurrent `POST /v1/account/identity` moved the app to B, went on to
    // send as B, write into B's store and greet a contact as B — with no
    // bearer for B anywhere in it, and tying the two identities together in
    // front of that contact (report17 XV17-H7).
    //
    // Captured in the closure, not read from the field: the field belongs to
    // whichever identity is current, which is exactly the thing being tested
    // against.
    final generation = _identityGeneration;
    bool moved() => generation != _identityGeneration;

    final handler = ApiHandler(
      cloudItems: cloudApi?.items,
      cloudFolders: cloudApi?.folders,
      cloudUsage: cloudApi?.usage,
      cloudFile: cloudApi?.file,
      saveCloudNote: cloudApi?.saveNote,
      deleteCloudItem: cloudApi?.deleteItem,
      tokens: state.tokens,
      // `tokens` above is captured ONCE, so this handler keeps authenticating
      // the identity it was built for even after the app has moved on. That is
      // deliberate — the socket is not torn down mid-request — and it is
      // exactly why everything below has to ask `moved()` before it answers
      // from, or acts on, whatever is current.
      status: () => moved() ? const {'ok': false, 'api': 'v1'} : _status(),
      account: () async =>
          moved() ? const {'ok': false, 'moved': true} : await _account(),
      accountInvite: () async =>
          moved() ? null : ref.read(realStackProvider)?.myInvite.toUri(),
      lockAccount: lockForApi,
      switchIdentity: (label) async =>
          moved() ? kIdentityChanged : await _switchIdentity(label),
      contacts: () async => moved() ? const [] : await _contacts(),
      // `moved` goes INSIDE these two: each does real work between its first
      // await and its side effect, and the switch can land in that gap.
      requestContact: (target, greeting) async => moved()
          ? kIdentityChanged
          : await _requestContact(target, greeting, moved),
      contactAction: (peerHex, action) async =>
          moved() ? kIdentityChanged : await _contactAction(peerHex, action),
      send: (toHex, text) async =>
          moved() ? kIdentityChanged : await _send(toHex, text),
      messages: (peerHex, limit) async =>
          moved() ? const [] : await _messages(peerHex, limit),
      sendFile: (toHex, path, name, roots) async => moved()
          ? kIdentityChanged
          : await _sendFile(toHex, path, name, roots, moved),
      fetchFile: (peerHex, messageId) async =>
          moved() ? kIdentityChanged : await _fetchFile(peerHex, messageId),
      loadFile: (fileId) async => moved() ? null : await _loadFile(fileId),
      placeCall: (toHex, media) async =>
          moved() ? kIdentityChanged : await _placeCall(toHex, media),
      callState: () => moved() ? null : _callState(),
      callAction: (action) async =>
          moved() ? kIdentityChanged : await _callAction(action),
      groups: groupApi == null ? () async => const [] : groupApi.list,
      spaces: groupApi == null ? () async => const [] : groupApi.listSpaces,
      spaceMemberships: groupApi == null
          ? () async => const []
          : groupApi.listSpaceMemberships,
      createGroup: groupApi == null ? (_) async => null : groupApi.create,
      createSpace: groupApi?.createSpace,
      groupMessages: groupApi == null
          ? (_, _) async => null
          : groupApi.messages,
      sendGroupMessage: groupApi == null
          ? (_, _, _) async => 'groups unavailable'
          : groupApi.sendMessage,
      sendGroupFile: groupApi == null
          ? (_, _, _, _, _, _, {kind, width, height, durationMs}) async =>
                (error: 'group media unavailable', contentId: null)
          : groupApi.sendFile,
      fetchGroupFile: groupApi == null
          ? (_, _) async => 'group media unavailable'
          : groupApi.fetchFile,
      loadGroupFile: groupApi == null
          ? (_, _) async => (error: 'group media unavailable', source: null)
          : groupApi.loadFile,
      groupMembers: groupApi == null ? (_, _) async => null : groupApi.members,
      groupMemberAction: groupApi == null
          ? (_, _, _, _, _) async => 'groups unavailable'
          : groupApi.memberAction,
      spaceAccess: groupApi?.spaceAccess,
      spaceAccessAction: groupApi?.spaceAccessAction,
      spacePolicyAudit: groupApi?.policyAudit,
      spaceObservability: groupApi?.spaceObservability,
      renameGroup: groupApi == null
          ? (_, _, _) async => 'groups unavailable'
          : groupApi.rename,
      leaveGroup: groupApi == null
          ? (_, _) async => 'groups unavailable'
          : groupApi.leave,
      spaceChannels: groupApi?.channels,
      spacePosts: groupApi?.posts,
      spacePostDraft: groupApi?.postDraft,
      saveSpacePostDraft: groupApi?.savePostDraft,
      clearSpacePostDraft: groupApi?.clearPostDraft,
      spaceScheduledPosts: groupApi?.scheduledPosts,
      scheduleSpacePost: groupApi?.schedulePost,
      cancelScheduledSpacePost: groupApi?.cancelScheduledPost,
      publishScheduledSpacePostNow: groupApi?.publishScheduledPostNow,
      spacePostComments: groupApi?.postComments,
      publishSpacePostComment: groupApi?.postComment,
      editSpacePostComment: groupApi?.editPostComment,
      deleteSpacePostComment: groupApi?.deletePostComment,
      publishSpacePost: groupApi?.publishPost,
      editSpacePost: groupApi?.editPost,
      deleteSpacePost: groupApi?.deletePost,
      setSpacePostPinned: groupApi?.setPostPinned,
      reactToSpacePost: groupApi?.reactToPost,
      spaceRecommendationCampaigns: groupApi == null
          ? null
          : (space, includeRevoked) => groupApi.recommendationCampaigns(
              space,
              includeRevoked: includeRevoked,
            ),
      createSpaceRecommendationCampaign: groupApi?.createRecommendationCampaign,
      revokeSpaceRecommendationCampaign: groupApi?.revokeRecommendationCampaign,
      shareSpaceRecommendation: groupApi?.shareRecommendation,
      spaceRecommendationPolicy: groupApi?.recommendationPolicy,
      setSpaceRecommendationPolicy: groupApi?.setRecommendationPolicy,
      spaceRecommendationShares: groupApi?.recommendationShares,
      revokeSpaceRecommendationShare: groupApi?.revokeRecommendationShare,
      spaceFeed: groupApi?.feed,
      spaceFeedTypeFilter: groupApi?.feedTypeFilter,
      setSpaceFeedTypeFilter: groupApi?.setFeedTypeFilter,
      publicSpaceDiscoverySearch: groupApi?.searchPublicSpaces,
      publicSpaceDiscoveryResolve: groupApi?.resolvePublicSpace,
      publicSpaceSubscriptions: groupApi?.publicSubscriptions,
      subscribePublicSpace: groupApi?.subscribePublicSpace,
      unsubscribePublicSpace: groupApi?.unsubscribePublicSpace,
      spaceSubscription: groupApi?.subscription,
      updateSpaceSubscription: groupApi == null
          ? null
          : (
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
      setSpaceFeedPostHidden: groupApi?.setFeedPostHidden,
      spaceInvites: groupApi?.invites,
      decideSpaceInvite: groupApi?.decideInvite,
      spaceJoinRequests: groupApi?.joinRequests,
      spaceJoinRequestAction: groupApi?.joinRequestAction,
      spaceProfile: groupApi?.profile,
      updateSpaceDescription: groupApi?.updateDescription,
      spaceLifecycle: groupApi?.lifecycle,
      setSpaceLifecycle: groupApi?.setLifecycle,
      spaceRetention: groupApi?.retention,
      setSpaceRetention: groupApi?.setRetention,
      spaceChannelRetention: groupApi?.channelRetention,
      setSpaceChannelRetention: groupApi?.setChannelRetention,
      spaceRules: groupApi?.rules,
      publishSpaceRules: groupApi?.publishRules,
      acceptSpaceRules: groupApi?.acceptRules,
      spaceModerationAudit: groupApi?.moderationAudit,
      moderateSpace: groupApi?.moderate,
      revokeSpaceModeration: groupApi?.revokeModeration,
      spaceModerationAppeals: groupApi?.moderationAppeals,
      spaceModerationAppealAction: groupApi?.moderationAppealAction,
      spaceAbuseReports: groupApi?.abuseReports,
      spaceAbuseReportAction: groupApi?.abuseReportAction,
      createSpaceChannel: groupApi?.createChannel,
      updateSpaceChannel: groupApi?.updateChannel,
      spaceChannelAction: groupApi?.channelAction,
      setSpaceChannelMembers: groupApi?.setChannelMembers,
      spaceChannelMessages: groupApi?.channelMessages,
      sendSpaceChannelMessage: groupApi?.sendChannelMessage,
      groupsAvailable: groupService != null,
      groupMediaAvailable: groupApi != null,
      // Each of these resolves `groupServiceProvider`/`groupCallServiceProvider`
      // when it runs, which is the CURRENT identity's — so unbound they let a
      // bearer minted for A start a group call as B, act on B's live call and
      // read B's participants. Same rule as the direct-call callbacks above.
      startGroupCall: (groupHex, media) async =>
          moved() ? kIdentityChanged : await _startGroupCall(groupHex, media),
      startSpaceVoiceSession: (spaceHex, channelHex, media) async => moved()
          ? kIdentityChanged
          : await _startSpaceVoiceSession(spaceHex, channelHex, media),
      groupCallState: () => moved() ? null : _groupCallState(),
      groupCallAction: (action) async =>
          moved() ? kIdentityChanged : await _groupCallAction(action),
      groupCallPosture: (mic, camera, screen) async => moved()
          ? kIdentityChanged
          : await _groupCallPosture(mic, camera, screen),
      groupCallsAvailable: groupCalls != null,
      webhook: () => moved() ? null : state.webhookUrl,
      // Bound like every other acting callback, and checked AGAIN inside:
      // this one writes to storage before it publishes, and a switch landing
      // in that gap used to point the NEW identity's event feed — sender ids
      // and message previews — at a URL the old identity's bearer chose.
      setWebhook: (url) async => moved() ? null : await setWebhook(url, moved),
    );
    // The bot event feed: incoming-message notices as JSON. `.map` on a
    // broadcast stream stays broadcast, so many WS clients can each subscribe.
    final events = _events(groupService, groupCalls);
    final server = ApiServer(handler, events);
    _server = server;
    try {
      await server.start(debugBindPort);
      // Decided on the LOCAL reference, never on the field. `_loadIdentity`
      // runs outside this reconcile's serialization: it stops whatever the
      // field holds — ours, still unbound, so a no-op — and nulls it, and then
      // this bind completes. Reading `_server!` here therefore threw on null
      // and the throw was swallowed below as "bind failed", leaving a socket
      // bound to the old identity's tokens with nobody holding it: no later
      // reconcile can find it, because the field it would look in is empty.
      if (identityAtStart != _identityHex || !identical(_server, server)) {
        await server.stop();
        if (identical(_server, server)) _server = null;
        return;
      }
    } catch (e) {
      devLog(() => 'xVeil[api]: bind failed: $e');
      // Bound-then-threw is possible; stopping an unbound server is a no-op.
      await server.stop();
      if (identical(_server, server)) _server = null;
    }
    _rewireWebhook(groupService);
  }

  /// (Re)point the webhook push at the current URL. Separate from
  /// [_reconcile] so changing the URL mid-request does NOT restart the socket —
  /// tearing the server down while it is serving the very POST /v1/webhook that
  /// changed the URL kills that connection before the response is written.
  ///
  /// Webhook push: the same events the WS feed carries, POSTed to a loopback
  /// URL, for bots that would rather run a plain HTTP server than hold a
  /// WebSocket open. Retargeting to null is what an identity switch, a
  /// shutdown, or turning the API off all come down to — and the pump treats
  /// that as "nothing more goes there", retries included.
  void _rewireWebhook([GroupService? groupService]) {
    _webhookGroups = groupService ?? ref.read(groupServiceProvider);
    _webhookGroupCalls = ref.read(groupCallServiceProvider);
    final hook = state.webhookUrl;
    final live = (!state.enabled || _server == null) ? null : hook;
    unawaited(_webhookPump.setTarget(live));
  }

  /// Persist + apply the webhook URL (null clears). The URL is validated at
  /// the API edge ([webhookUrlError]); this stores and rewires the push
  /// subscription only — never the socket (see [_rewireWebhook]).
  ///
  /// [moved] is the identity-generation check of the handler this call came
  /// through, and it is asked AFTER the storage write, not only before it. The
  /// write itself is right either way — it was authorised for, and lands in,
  /// the identity that asked — but everything after it is about whoever is
  /// current: `state` belongs to the live controller and `_rewireWebhook`
  /// subscribes the live event feed. Publishing those from a request that
  /// began under another identity pointed B's feed at A's URL.
  Future<void> setWebhook(String? url, [bool Function()? moved]) async {
    await ref.read(storageProvider).putSetting(_kWebhookKey, url ?? '');
    if (moved?.call() ?? false) return;
    state = state.withWebhook(url);
    _rewireWebhook();
  }

  String _mintId() => mintShortId();

  Future<void> _persistTokens() => ref
      .read(storageProvider)
      .putSetting(
        _kTokensKey,
        jsonEncode(state.tokens.map((t) => t.toJson()).toList()),
      );

  /// Turn the API on: ensure at least one (full) token exists, persist, start.
  Future<void> enable() async {
    if (state.tokens.isEmpty) {
      state = state.copyWith(
        tokens: [
          ApiToken(
            id: _mintId(),
            name: 'default',
            token: _mintToken(),
            readOnly: false,
          ),
        ],
      );
      await _persistTokens();
    }
    await ref.read(storageProvider).putSetting(_kEnabledKey, '1');
    state = state.copyWith(enabled: true);
    await _reconcile();
  }

  /// Turn the API off (keeps the tokens so re-enabling is one tap).
  Future<void> disable() async {
    await ref.read(storageProvider).putSetting(_kEnabledKey, '0');
    state = state.copyWith(enabled: false);
    await _reconcile();
  }

  /// Issue a new token ([readOnly] = least-privilege); returns its secret.
  ///
  /// [fileRoots] defaults to none: a fresh token cannot send local files until
  /// somebody points it at a folder ([setTokenFileRoots]). See
  /// [ApiToken.fileRoots].
  Future<String> addToken(
    String name, {
    bool readOnly = false,
    List<String> fileRoots = const <String>[],
  }) async {
    final tok = ApiToken(
      id: _mintId(),
      name: name.trim().isEmpty ? 'token' : name.trim(),
      token: _mintToken(),
      readOnly: readOnly,
      fileRoots: List<String>.unmodifiable(fileRoots),
    );
    state = state.copyWith(tokens: [...state.tokens, tok]);
    await _persistTokens();
    if (state.enabled) await _reconcile();
    return tok.token;
  }

  /// Grant (or clear) the folders the token with [id] may send local files
  /// from — the out-of-band half of [ApiToken.fileRoots].
  ///
  /// Deliberately NOT reachable through the API itself: a stolen token that
  /// could widen its own folders would leave the capability exactly as broad
  /// as it was. It also means an integration that predates the field is fixed
  /// by granting a folder rather than by re-minting a secret the bot already
  /// has deployed.
  Future<void> setTokenFileRoots(String id, List<String> roots) async {
    final cleaned = <String>[
      for (final root in roots)
        if (root.trim().isNotEmpty) root.trim(),
    ];
    state = state.copyWith(
      tokens: [
        for (final t in state.tokens)
          if (t.id == id) t.withFileRoots(cleaned) else t,
      ],
    );
    await _persistTokens();
    if (state.enabled) await _reconcile();
  }

  /// Revoke the token with [id] (that client immediately stops working).
  ///
  /// The event socket goes with it (audit XV-10). "Revoked" used to mean only
  /// that the next REQUEST would be refused: an already-upgraded `/v1/events`
  /// WebSocket carried no trace of which token opened it, and
  /// `HttpServer.close` does not take upgraded sockets down, so the revoked
  /// client kept its live feed across the restart below. Closed BY TOKEN, so
  /// revoking one bot does not disconnect the others.
  Future<void> revokeToken(String id) async {
    await _server?.closeLiveSockets(
      tokenId: id,
      code: 1008, // policy violation: this credential is no longer valid
      reason: 'token revoked',
    );
    state = state.copyWith(
      tokens: state.tokens.where((t) => t.id != id).toList(),
    );
    await _persistTokens();
    if (state.enabled) await _reconcile();
  }

  bool get running => _server?.running ?? false;

  /// Live `/v1/events` subscribers, or 0 when the server is down. Lets a test
  /// watch the identity-switch and disable paths let their sockets go.
  int get liveSocketCount => _server?.liveSocketCount ?? 0;

  /// The bound port, or null when the server is down. Tests use it to reach a
  /// server that came up on an ephemeral port.
  int? get boundPort => _server?.port;
}

final apiServerControllerProvider =
    NotifierProvider<ApiServerController, ApiConfig>(ApiServerController.new);
