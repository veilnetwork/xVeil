import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import '../api/api_server.dart';
import '../core/ids.dart';
import '../core/log.dart';
import '../data/node/node_controller.dart';
import '../data/native_libs.dart';
import '../data/serve_source.dart';
import '../data/storage/async_kv_log_store.dart';
import '../data/storage/hidden_volume_storage.dart';
import '../data/transport/bootstrap_invite.dart';
import '../data/transport/relay_key_cache.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../data/veil_stack.dart';
import '../domain/chat.dart';
import '../domain/identity.dart';
import '../state/mailbox_orchestrator.dart';
import '../state/mailbox_service.dart';
import '../state/messaging_core.dart';
import 'headless_config.dart';

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
  final ApiServer api;
  final List<ApiToken> tokens;

  final MailboxService? _mailbox;
  final StreamSubscription<NodeStatus>? _nodeStatus;
  final _WebhookPump _webhook;
  bool _closed = false;

  static Future<HeadlessRuntime> start({
    required HeadlessConfig config,
    required String password,
    bool createIfMissing = false,
    String? identityPhrase,
    String? apiToken,
  }) async {
    if (password.isEmpty) throw ArgumentError('password must not be empty');
    await Directory(config.storePath).parent.create(recursive: true);
    await Directory(config.blobDir).create(recursive: true);

    final storage = HiddenVolumeStorage.async(
      workerSpaceOpener(config.storePath),
    )..useOnDiskTier(Directory(config.blobDir));
    RealVeilStack? stack;
    MessagingService? messaging;
    ApiServer? api;
    MailboxService? mailbox;
    StreamSubscription<NodeStatus>? nodeStatus;
    _WebhookPump? webhookPump;
    try {
      final opened = await storage.open(
        password: password,
        createIfMissing: createIfMissing,
      );
      if (!opened) throw StateError('unable to unlock deniable store');

      String? psk;
      final pskPath = config.obfs4PskFile;
      if (pskPath != null) {
        psk = (await File(pskPath).readAsString()).trim();
        if (psk.isEmpty) throw StateError('obfs4 PSK file is empty');
      }

      stack = await RealVeilStack.startDeniable(
        storage: storage,
        runtimeDir: config.runtimeDir,
        listenPort: config.listenPort,
        anonymous: config.anonymous,
        bootstrapPeers: config.bootstrapPeers,
        obfs4Psk: psk,
        identityPhrase: identityPhrase,
        lib: _veilNativeHandle(),
      );
      final nodeId = await stack.transport.nodeId();
      final storedIdentity = await storage.loadIdentity();
      if (storedIdentity == null) {
        await storage.saveIdentity(Identity(nodeId: nodeId));
      } else if (storedIdentity.nodeId != nodeId) {
        throw StateError('stored identity does not match running veil node');
      }

      messaging = MessagingService(
        stack.transport,
        storage,
        anonymous: config.anonymous,
      )..sourceOpener = veilSourceOpener;
      messaging.start();

      final relays = mailboxRelayCandidates(config.bootstrapPeers);
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
      if (apiToken != null && apiToken.isNotEmpty) {
        if (!loadedTokens.any((t) => _constantTimeEqual(t.token, apiToken))) {
          loadedTokens.add(
            ApiToken(
              id: _mintId(),
              name: 'headless',
              token: apiToken,
              readOnly: false,
            ),
          );
          await _persistTokens(storage, loadedTokens);
        }
      } else if (loadedTokens.isEmpty) {
        throw StateError(
          'no API token is provisioned; supply --api-token-file',
        );
      }

      var webhookUrl = await storage.getSetting(_webhookKey);
      if (webhookUrl?.isEmpty ?? false) webhookUrl = null;
      final events = messaging.incoming.map(
        (n) => <String, dynamic>{
          'type': 'message',
          'from': n.from.hex,
          'preview': n.preview,
          'isFile': n.isFile,
        },
      );
      webhookPump = _WebhookPump(events);

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
        contacts: () => _contacts(storage),
        requestContact: (target, greeting) =>
            _requestContact(stack!, messaging!, target, greeting),
        contactAction: (peer, action) =>
            _contactAction(messaging!, peer, action),
        send: (to, body) => _send(messaging!, to, body),
        messages: (peer, limit) => _messages(storage, peer, limit),
        sendFile: (to, path, name) => _sendFile(messaging!, to, path, name),
        loadFile: storage.loadFile,
        placeCall: (_, _) async => 'calls unavailable in headless mode',
        callState: () => null,
        callAction: (_) async {},
        callsAvailable: false,
        groups: () async => const [],
        createGroup: (_) async => null,
        groupMessages: (_, _) async => null,
        sendGroupMessage: (_, _, _) async => 'groups unavailable',
        // GroupService still imports Flutter/Riverpod. Keep the headless
        // binary honestly Flutter-free and return machine-detectable 501 until
        // the pure group core is split out and can be wired here.
        groupsAvailable: false,
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
        api: api,
        tokens: List.unmodifiable(loadedTokens),
        mailbox: mailbox,
        nodeStatus: nodeStatus,
        webhook: webhookPump,
      );
    } catch (_) {
      await api?.stop();
      await webhookPump?.close();
      await nodeStatus?.cancel();
      await mailbox?.dispose();
      await messaging?.dispose();
      await stack?.dispose();
      await storage.close();
      rethrow;
    }
  }

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

  static Future<List<Map<String, dynamic>>> _contacts(
    HiddenVolumeStorage storage,
  ) async => [
    for (final c in await storage.loadConversations())
      if (c.peer.status == ContactStatus.accepted)
        {
          'nodeId': c.peer.nodeId.hex,
          'short': c.peer.nodeId.short,
          if (c.peer.name != null) 'name': c.peer.name,
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

  static Future<String?> _requestContact(
    RealVeilStack stack,
    MessagingService messaging,
    String target,
    String greeting,
  ) async {
    try {
      final NodeId peer;
      if (target.startsWith('veil:bootstrap?')) {
        final invite = BootstrapInvite.parse(target);
        peer = invite.nodeId;
        await stack.addContact(invite);
      } else {
        peer = NodeId.fromHex(target);
      }
      await messaging.sendRequest(peer, greeting);
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

  static Future<String?> _sendFile(
    MessagingService messaging,
    String toHex,
    String path,
    String? name,
  ) async {
    final NodeId peer;
    try {
      peer = NodeId.fromHex(toHex);
    } catch (_) {
      return 'invalid peer';
    }
    final file = File(path);
    if (!await file.exists()) return 'source not found';
    final source = await veilSourceOpener(path);
    if (source == null) return 'source open failed';
    try {
      final cid = await messaging.sendFileStreaming(
        peer,
        name?.isNotEmpty == true ? name! : file.uri.pathSegments.last,
        await file.length(),
        source.read,
        close: source.close,
        sourcePath: file.absolute.path,
      );
      return cid == null ? 'peer not accepted' : null;
    } catch (e) {
      return '$e';
    }
  }

  static String _mintId() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(6, (_) => random.nextInt(256)))
        .replaceAll(RegExp('[=_-]'), '')
        .substring(0, 6);
  }

  static bool _constantTimeEqual(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static Future<void> _pushWebhookWithRetry(
    String url,
    Map<String, dynamic> event,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (await pushWebhookEvent(url, event)) return;
      if (attempt == 0) await Future<void>.delayed(const Duration(seconds: 2));
    }
    devLog(() => 'xVeil[headless]: webhook push failed twice, dropped');
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

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await api.stop();
    await _webhook.close();
    await _nodeStatus?.cancel();
    await _mailbox?.dispose();
    await messaging.dispose();
    await stack.dispose();
    await storage.close();
  }
}

class _WebhookPump {
  _WebhookPump(this._events);

  final Stream<Map<String, dynamic>> _events;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  Future<void> setTarget(String? target) async {
    await _subscription?.cancel();
    _subscription = null;
    if (target == null) return;
    _subscription = _events.listen((event) {
      unawaited(HeadlessRuntime._pushWebhookWithRetry(target, event));
    });
  }

  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
