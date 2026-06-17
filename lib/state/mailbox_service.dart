// `prefer_initializing_formals` suppressed: external NAMED params with private
// fields can't use `this._x` formals (Dart forbids private named args across
// libraries), so an explicit initializer list is required.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:veil_flutter/veil_flutter.dart';

import '../core/ids.dart';
import '../data/transport/veil_addressing.dart';
import '../data/transport/veil_transport.dart';
import 'mailbox_orchestrator.dart';

/// Runs the offline-delivery side of messaging alongside [MessagingService]:
///
///  * **register** — advertise an always-on relay as THIS node's mailbox host
///    (resolve the relay's KEM key by node_id via [VeilClient.lookupRelayX25519],
///    then [VeilClient.registerRendezvousPublisher]) so senders can deposit for
///    us while we're offline.
///  * **drain** — periodically fetch + open our pending blobs ([MailboxOrchestrator.drain])
///    and hand each recovered message to [deliver] as if it had arrived live;
///    the messaging layer dedups by content id (= message uuid), so a blob that
///    was ALSO delivered live is a no-op.
///  * **stash** — seal + deposit a message for an offline recipient at THEIR
///    advertised relay ([MailboxOrchestrator.stash]).
///
/// The mailbox-relay [node_id] this node advertises is injected (`start`) — the
/// POLICY for choosing an always-on [mailbox]-capable relay (a connected relay
/// peer, a configured set, or a daemon auto-selection) is a separate decision;
/// resolving its KEM key by node_id is the part veil now provides.
class MailboxService {
  MailboxService({
    required VeilClient client,
    required NodeId me,
    required MailboxOrchestrator orchestrator,
    required void Function(InboundMessage) deliver,
    int ourCertVersion = 0,
    Duration drainInterval = const Duration(seconds: 30),
  })  : _client = client,
        _me = me,
        _orchestrator = orchestrator,
        _deliver = deliver,
        _ourCertVersion = ourCertVersion,
        _drainInterval = drainInterval;

  final VeilClient _client;
  final NodeId _me;
  final MailboxOrchestrator _orchestrator;
  final void Function(InboundMessage) _deliver;
  final int _ourCertVersion;
  final Duration _drainInterval;

  /// 16-byte rendezvous auth-cookie for our published mailbox ad. The NETWORK
  /// FETCH path authorizes by our cryptographic identity (NOT this cookie — see
  /// the no-cookie finding), so this is just the rendezvous-registration token.
  final Uint8List _cookie = _randomBytes(16);

  Timer? _drainTimer;
  bool _draining = false;
  bool _registered = false;

  /// Whether we have successfully advertised a mailbox relay this session.
  bool get isRegistered => _registered;

  /// Advertise an always-on mailbox host (the first of [relays] whose relay-key
  /// record resolves) and begin draining. Safe to call again (e.g. after a
  /// reconnect): registration is re-attempted until one candidate sticks, and
  /// the drain timer is only armed once. Candidates that aren't relay-capable
  /// (no resolvable relay-key record) are simply skipped — the resolve itself
  /// validates the choice, so a wrong/derived node_id is non-fatal.
  Future<void> start({required List<NodeId> relays}) async {
    for (final relay in relays) {
      if (_registered) break;
      await _register(relay);
    }
    _drainTimer ??= Timer.periodic(_drainInterval, (_) => _drainTick());
    unawaited(_drainTick()); // don't wait a full interval for the first drain
  }

  Future<void> _register(NodeId relay) async {
    if (_registered) return;
    try {
      final kem = await _client.lookupRelayX25519(relay.bytes);
      if (kem == null) {
        // The relay advertises no resolvable relay-key record yet — a later
        // start()/reconnect retries.
        return;
      }
      await _client.registerRendezvousPublisher(
        rendezvousNodeId: relay.bytes,
        authCookie: _cookie,
        validityWindowSecs: 86400,
        relayKemAlgo: 0,
        relayKemPk: kem,
      );
      _registered = true;
    } catch (_) {
      // Transient (relay unresolved / IPC hiccup) — retried on the next start().
    }
  }

  /// Seal [payload] (the same `WireEnvelope` bytes we'd send live) for offline
  /// [recipient] under [contentId] (the message uuid) and deposit it at the
  /// recipient's advertised relay. Best-effort: throws on no-route / no relay so
  /// the caller's outbox retries.
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) {
    return _orchestrator.stash(
      me: _me,
      recipient: recipient,
      appId: chatAppIdFor(recipient),
      endpointId: veilChatEndpointId,
      data: payload,
      contentId: contentId,
    );
  }

  Future<void> _drainTick() async {
    if (_draining) return;
    _draining = true;
    try {
      final recovered = await _orchestrator.drain(
        me: _me,
        authCookie: Uint8List(0), // ignored on the network path
        ourCertVersion: _ourCertVersion,
        // Dedup is enforced downstream by the messaging layer (it stores by the
        // same content id), so we re-deliver everything the relay returns and
        // let that gate duplicates — keeps this layer storage-free.
        alreadyHave: (_) async => false,
      );
      for (final m in recovered) {
        _deliver(InboundMessage(src: m.sender, payload: m.data));
      }
    } catch (_) {
      // Transient drain failure (DHT lookup / circuit not ready) — next tick.
    } finally {
      _draining = false;
    }
  }

  Future<void> dispose() async {
    _drainTimer?.cancel();
    _drainTimer = null;
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = r.nextInt(256);
    }
    return b;
  }
}
