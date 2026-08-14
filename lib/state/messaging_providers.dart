import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/node/node_controller.dart';
import '../data/serve_source.dart';
import '../data/transport/relay_key_cache.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../data/transport/wire_envelope.dart' show isServiceEchoBody;
import '../domain/chat.dart';
import '../domain/chat_folder.dart';
import 'app_controller.dart';
import 'chat_page_size_controller.dart';
import 'mailbox_orchestrator.dart';
import 'mailbox_service.dart';
import 'messaging_core.dart';
import 'p2p_policy_controller.dart';
import 'providers.dart';
import 'ratchet_persistence.dart';
import 'signature_policy_controller.dart';
import 'thumbnail.dart';
import 'video_thumb.dart';
import '../data/veil_stack.dart';

/// Constructed once and kept alive for the session; starts listening eagerly.
final messagingServiceProvider = Provider<MessagingService>((ref) {
  // All-online: use the ACTIVE identity's OWN pipeline from the session, so we
  // don't spin up a second service on its transport (which would double-process
  // its inbound). The session owns/disposes it; switching just re-resolves here.
  final session = ref.watch(sessionProvider);
  final active = ref.watch(activeIdentityProvider);
  if (session != null && active != null) {
    final m = session.messagingFor(active);
    if (m != null) return m;
  }
  // The send anonymity MUST match the value the node booted with
  // (AppController._activeAnonymous): an anonymous send needs the node's onion
  // service armed, and a non-anonymous send goes clearnet/direct. Hardcoding
  // `true` here (the old anonymity-first default) ignored the user's per-space
  // anonymity toggle — so disabling anonymity had NO effect on send, and the
  // forced-anonymous send had no onion path on a node that booted non-anon, so
  // it never delivered. Track the live setting instead. The loopback fake
  // ignores the flag.
  final anonymous = ref.read(appControllerProvider.notifier).activeIsAnonymous;
  final transport = ref.watch(veilTransportProvider);
  final storage = ref.watch(storageProvider);
  devLog(
    () =>
        'xVeil[messaging]: fallback service (no session pipeline) '
        'anonymous=$anonymous '
        'streamRangeEnabled=${xveilConfiguredStreamRangeEnabled()} '
        'streamRangeParallelism=${xveilConfiguredStreamRangeParallelism() ?? 'default'} '
        'streamRangeTargetBytes=${xveilConfiguredStreamRangeTargetBytes() ?? 'default'}',
  );
  final service = MessagingService(
    transport,
    storage,
    anonymous: anonymous,
    streamRangeParallelism: xveilConfiguredStreamRangeParallelism(),
    streamRangeTargetBytes: xveilConfiguredStreamRangeTargetBytes(),
    p2pStreamAllowed: (peer) =>
        ref.read(p2pPolicyProvider.notifier).allowsPeer(peer),
    videoThumbMaker: makeVideoThumbB64,
    imageThumbMaker: makeMessageThumbB64,
  );
  service.sourceOpener = veilSourceOpener; // DURABLE offers: re-open by path
  // The durable half of the ratchet, over the SAME storage this service writes
  // messages to — so an identity's chain keys can only ever land in that
  // identity's own container. Null on the loopback fake and on builds without
  // the embedded-node FFI, which have no ratchet to keep.
  service.ratchet = ratchetPersistenceFor(
    ref.watch(realStackProvider),
    storage,
  );
  // Author-side answer to incoming signature requests, read live from settings.
  service.signaturePolicyResolver = () => ref.read(signaturePolicyProvider);
  service.start();

  // Offline delivery: over the real veil transport, advertise a mailbox relay
  // (a configured bootstrap peer) and drain our mailbox into the inbound path.
  // Best-effort + inert on the loopback transport or when no bootstrap peers
  // are configured — live delivery is unaffected if this never registers.
  final relays = mailboxRelayCandidates(
    ref.read(deniableBootProvider)?.bootstrapPeers ?? const [],
  );
  devLog(
    () =>
        'xVeil[mailbox]: setup — transport=${transport.runtimeType} '
        'relays=${relays.length}',
  );
  MailboxService? mailbox;
  // The provider rebuilds whenever the real stack changes (node reboot, identity
  // create/switch tears down then re-boots — TWO rapid rebuilds). buildMailboxService
  // is async, so its `.then` can resolve AFTER this provider was already disposed.
  // If we attached then, the orphaned mailbox's retry timer would run forever on
  // a dead veil handle ("handle already closed" spam). Track disposal and drop a
  // late-arriving mailbox instead of leaking it.
  var providerDisposed = false;
  ref.onDispose(() => providerDisposed = true);
  if (transport is VeilFlutterTransport && relays.isNotEmpty) {
    // Persist verified relay keys INSIDE the active deniable space so a cold
    // restart can stay reachable through a transient resolve failure (the fresh
    // one-hop resolve is still preferred — see MailboxService._register).
    // Hold the relay copy back while the recipient may still confirm having
    // STORED the message (the ack is sent after the write, not on receipt).
    // Reaching one device of an identity is reaching the identity: its devices
    // mirror what they receive among themselves, deduplicating by message id.
    service.mailboxAckGrace = const Duration(seconds: 6);
    final relayKeyCache = StorageRelayKeyCache(storage);
    // Receive under the IDENTITY's address, not the node's. The same value for
    // every identity that has no transport key of its own, and the difference
    // between reachable and silently unreachable for one that has. Chained
    // rather than awaited: this provider body is synchronous, and the mailbox
    // has always been built off a future it does not block on.
    RealVeilStack.sovereignReceiveAddress(storage)
        .then((receiveAddress) {
          // The transport needs it too, and for the opposite direction: a
          // send addressed HERE is a device sync, not a message to
          // ourselves, and only the transport can tell the node so.
          if (receiveAddress != null) {
            transport.identityAddress = receiveAddress;
          }
          return transport.buildMailboxService(
            deliver: service.deliverInbound,
            relayKeyCache: relayKeyCache,
            receiveAddress: receiveAddress == null
                ? null
                : NodeId(receiveAddress),
            // Durable quarantine for permanently-undecryptable deposits —
            // without it one poisoned blob kept the drain at max cadence for
            // its whole 7-day relay TTL (re-fetch + re-fail + backoff reset
            // every tick).
            poisonedBlobs: PoisonedBlobRegistry(
              getSetting: storage.getSetting,
              putSetting: storage.putSetting,
            ),
          );
        })
        .then((m) {
          if (providerDisposed) {
            // This stack/transport is already gone — don't start a timer on it.
            unawaited(m.dispose());
            return;
          }
          mailbox = m;
          service.attachMailbox(m);
          ref.onDispose(m.dispose);
          unawaited(m.start(relays: relays));
        })
        .catchError((e) {
          devLog(() => 'xVeil[mailbox]: build/start FAILED: $e');
        });
  } else {
    devLog(
      () =>
          'xVeil[mailbox]: NOT started '
          '(transport=${transport.runtimeType}, relays=${relays.length})',
    );
  }

  // Flush the local outbox whenever the node (re)connects: messages composed
  // while offline stay `sent` and go out the moment transport is up again. Also
  // (re)attempt mailbox registration — the DHT resolve needs the node connected.
  ref.listen<AsyncValue<NodeStatus>>(nodeStatusProvider, (prev, next) {
    final was = prev?.value?.phase;
    final now = next.value?.phase;
    if (now == NodePhase.connected && was != NodePhase.connected) {
      // Reconcile on reconnect: fire the gap-fill beacons immediately + flush the
      // outbox so messages composed while offline (and any the peer missed) heal.
      unawaited(service.reconcileOnConnect());
      unawaited(mailbox?.start(relays: relays) ?? Future.value());
    }
  });
  ref.onDispose(service.dispose);
  return service;
});

/// In-flight download progress (contentId → fraction 0..1), fed by
/// [MessagingService.contentProgress]. A completed transfer's entry is cleared
/// shortly after the final emit so the file bubble flips to its downloaded/saved
/// state instead of lingering at 100%.
class ContentProgressNotifier extends StateNotifier<Map<String, double>> {
  ContentProgressNotifier(MessagingService svc)
    : this.forStreams(
        svc.contentProgress,
        svc.contentDownloadFailed,
        cancelled: svc.contentDownloadCancelled,
      );

  @visibleForTesting
  ContentProgressNotifier.forStreams(
    Stream<({String contentId, int done, int total})> progress,
    Stream<String> failed, {
    Stream<String> cancelled = const Stream.empty(),
  }) : super(const {}) {
    _sub = progress.listen((e) {
      final frac = e.total <= 0 ? 0.0 : e.done / e.total;
      // Late echoes of a transfer that already completed (a duplicate pull
      // draining out) must not resurrect the bar.
      final doneAt = _completedAt[e.contentId];
      if (doneAt != null) {
        if (DateTime.now().difference(doneAt) < const Duration(seconds: 30)) {
          return;
        }
        _completedAt.remove(e.contentId);
      }
      // Monotonic latch: several emitters share this per-contentId channel
      // (restart markers are 0/1; retries and concurrent pulls count from
      // their own resume baselines) — the bar only ever moves forward. The
      // entry resets only via the completion cleanup / failure listener.
      final prev = state[e.contentId];
      if (prev != null && frac < prev) return;
      state = {...state, e.contentId: frac};
      if (e.done >= e.total) {
        _completedAt[e.contentId] = DateTime.now();
        Future<void>.delayed(const Duration(milliseconds: 800), () {
          if (mounted) state = {...state}..remove(e.contentId);
        });
      }
    });
    _failedSub = failed.listen((contentId) {
      state = {...state}..remove(contentId);
    });
    _cancelledSub = cancelled.listen((contentId) {
      state = {...state}..remove(contentId);
    });
  }

  final Map<String, DateTime> _completedAt = {};
  StreamSubscription<({String contentId, int done, int total})>? _sub;
  StreamSubscription<String>? _failedSub;
  StreamSubscription<String>? _cancelledSub;

  @override
  void dispose() {
    _sub?.cancel();
    _failedSub?.cancel();
    _cancelledSub?.cancel();
    super.dispose();
  }
}

/// contentId → download fraction (0..1) for transfers currently in flight.
final contentProgressProvider =
    StateNotifierProvider<ContentProgressNotifier, Map<String, double>>(
      (ref) => ContentProgressNotifier(ref.watch(messagingServiceProvider)),
    );

/// The set of contentIds with a background auto-resume record (queued /
/// retrying — the sender may be offline). Drives the file bubble's "resuming…"
/// hint for a parked download, which shows NO [contentProgress] until a pull
/// actually starts moving bytes.
class ContentResumingNotifier extends StateNotifier<Set<String>> {
  ContentResumingNotifier(MessagingService svc)
    : this.forStream(svc.contentResuming);

  @visibleForTesting
  ContentResumingNotifier.forStream(Stream<Set<String>> resuming)
    : super(const {}) {
    _sub = resuming.listen((s) => state = s);
  }

  StreamSubscription<Set<String>>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final contentResumingProvider =
    StateNotifierProvider<ContentResumingNotifier, Set<String>>(
      (ref) => ContentResumingNotifier(ref.watch(messagingServiceProvider)),
    );

/// Conversations, re-loaded on first build and whenever the service signals a
/// change. StreamProvider yields the same AsyncValue the UI already consumes.
final conversationsProvider = StreamProvider<List<Conversation>>((ref) async* {
  // DesktopTrayHost watches this provider for its unread badge even while the
  // app is locked. Do not let that eager listener construct the messaging
  // pipeline or touch HiddenVolumeStorage before AppController has completed
  // open(). Watching the phase makes the provider restart automatically when
  // unlock reaches ready; without this guard the first locked read terminated
  // the stream with "storage is locked" and the chat list stayed on that error
  // after a successful unlock.
  final ready = ref.watch(
    appControllerProvider.select((state) => state.phase == AppPhase.ready),
  );
  if (!ready) {
    yield const <Conversation>[];
    return;
  }
  final service = ref.watch(messagingServiceProvider);
  final storage = ref.watch(storageProvider);
  yield await storage.loadConversations();
  await for (final _ in service.changes) {
    yield await storage.loadConversations();
  }
});

/// Reactions overlay for one conversation: msgId → (reactorHex → emoji).
/// Reloaded on every service change so a new reaction (local or inbound)
/// re-renders the affected bubble. `autoDispose` — scoped to an open chat.
final reactionsProvider = StreamProvider.autoDispose
    .family<Map<String, Map<String, String>>, String>((ref, convId) async* {
      final service = ref.watch(messagingServiceProvider);
      yield await service.loadReactions(convId);
      await for (final _ in service.changes) {
        yield await service.loadReactions(convId);
      }
    });

/// The user's chat folders, re-loaded whenever the service signals a change
/// (folders are mutated through the service, which signals on every write).
final chatFoldersProvider = StreamProvider<List<ChatFolder>>((ref) async* {
  final service = ref.watch(messagingServiceProvider);
  yield await service.loadFolders();
  await for (final _ in service.changes) {
    yield await service.loadFolders();
  }
});

/// The current visible window (a newest-N count) for a chat, grown by the chat
/// screen's "load earlier" action. The initial size (and the grow step) is the
/// user-configurable [chatPageSizeProvider]. `autoDispose` so it resets each
/// time the chat is (re)opened — reopening lands on the latest page, not a
/// previously-expanded one. Reading it inside [messagesProvider] makes the
/// window reactive: growing it re-yields a larger tail without re-subscribing
/// the changes stream by hand.
final chatWindowProvider = StateProvider.autoDispose.family<int, String>(
  (ref, _) => ref.watch(chatPageSizeProvider),
);

final messagesProvider = StreamProvider.autoDispose.family<List<Message>, String>((
  ref,
  conversationId,
) async* {
  final service = ref.watch(messagingServiceProvider);
  final storage = ref.watch(storageProvider);
  // Load only the newest `window` messages, not the whole conversation — bounds
  // the decrypt + the ListView build to the page the user actually sees.
  final window = ref.watch(chatWindowProvider(conversationId));
  yield _visibleChatMessages(
    await storage.loadMessages(conversationId, limit: window),
  );
  // Each `changes` tick re-loads + DECRYPTS the conversation window from the
  // container and rebuilds the ListView (+ auto-scroll). A burst of state
  // signals (sends, inbound re-sends, status flips) therefore thrashed the UI
  // isolate into a visible freeze. Coalesce bursts: reload at most ~5x/s
  // (trailing edge), so the latest state still renders within ~200ms but a
  // flurry collapses into ONE decrypt+rebuild.
  await for (final _ in service.changes.auditTrailing(
    const Duration(milliseconds: 200),
  )) {
    yield _visibleChatMessages(
      await storage.loadMessages(conversationId, limit: window),
    );
  }
});

List<Message> _visibleChatMessages(List<Message> messages) =>
    messages.where((m) => !isServiceEchoBody(m.body)).toList(growable: false);

extension _AuditTrailing<T> on Stream<T> {
  /// Trailing-edge throttle: collapses a burst of events into a single
  /// downstream event carrying the LATEST value, emitted at most once per
  /// [window]. Quiet periods pass through with at most [window] added latency;
  /// no event is emitted for an idle window.
  Stream<T> auditTrailing(Duration window) {
    StreamController<T>? controller;
    StreamSubscription<T>? sub;
    Timer? timer;
    late T latest;
    var has = false;
    controller = StreamController<T>(
      onListen: () {
        sub = listen(
          (e) {
            latest = e;
            has = true;
            timer ??= Timer(window, () {
              timer = null;
              if (has) {
                has = false;
                controller!.add(latest);
              }
            });
          },
          onError: (Object err, StackTrace st) => controller!.addError(err, st),
          onDone: () {
            timer?.cancel();
            controller!.close();
          },
        );
      },
      onCancel: () {
        timer?.cancel();
        final s = sub;
        sub = null;
        return s?.cancel();
      },
    );
    return controller.stream;
  }
}

/// The stored contact (with relationship status) for a peer, refreshed on
/// every change. Null until we have a record of them.
final contactProvider = StreamProvider.family<Contact?, String>((
  ref,
  peerHex,
) async* {
  final service = ref.watch(messagingServiceProvider);
  final storage = ref.watch(storageProvider);
  final id = NodeId.fromHex(peerHex);
  yield await storage.getContact(id);
  await for (final _ in service.changes) {
    yield await storage.getContact(id);
  }
});
