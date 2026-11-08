part of 'messaging_core.dart';

({String call, int stamp, bool? upgrade})? _queuedCallRoute(OutboxFrame frame) {
  if (frame.wire.length > 4096 ||
      !frame.frameId.startsWith('call:') ||
      !frame.frameId.contains(':transportInfo:')) {
    return null;
  }
  try {
    final envelope = WireEnvelope.decode(frame.wire);
    if (envelope.kind != WireKind.callSignal ||
        envelope.frameId != frame.frameId ||
        envelope.seq != null) {
      return null;
    }
    // Capture, forwarding and future fields may carry independent obligations.
    // Only the current sender's pure route snapshot is supersedable.
    final body = jsonDecode(envelope.body);
    if (body is! Map<String, dynamic> ||
        body.keys.any(
          (k) => !const {'c', 'k', 't', 'pu', 'v', 'ts'}.contains(k),
        )) {
      return null;
    }
    final transport = body['t'];
    if (transport is! Map<String, dynamic> ||
        transport.keys.any((k) => !const {'k', 'r', 'e'}.contains(k))) {
      return null;
    }
    final signal = CallSignal.tryDecode(envelope.body);
    final stamp = signal?.sentAtMs;
    final route = signal?.transport;
    if (signal == null ||
        signal.type != CallSignalType.transportInfo ||
        stamp == null ||
        stamp < 0 ||
        route == null ||
        !const {
          CallTransportKind.relay,
          CallTransportKind.p2p,
        }.contains(route.kind) ||
        frame.frameId !=
            'call:${signal.callId}:transportInfo:$stamp:'
                '${route.kind.index}:${frame.peerHex}') {
      return null;
    }
    return (
      call: signal.callId,
      stamp: stamp,
      upgrade: signal.p2pUpgradeAllowed,
    );
  } catch (_) {
    return null;
  }
}

Future<void> _retireSupersededCallRoutes(
  _MessagingOutbox outbox,
  List<OutboxFrame> pending,
  _OutboxFlushSnapshot snapshot,
) async {
  final owner = outbox._owner;
  final storage = owner._storage;
  if (owner._disposed || storage is! GuardedOutboxRetirement) return;
  final guarded = storage as GuardedOutboxRetirement;
  final groups =
      <
        (String, String),
        List<({OutboxFrame frame, int stamp, bool? upgrade})>
      >{};
  for (final frame in pending) {
    if (!snapshot.contains(frame.peerHex, frame.frameId)) continue;
    final route = _queuedCallRoute(frame);
    if (route == null) continue;
    groups.putIfAbsent((frame.peerHex, route.call), () => []).add((
      frame: frame,
      stamp: route.stamp,
      upgrade: route.upgrade,
    ));
  }
  var attempts = 0;
  for (final rows in groups.values) {
    if (owner._disposed || attempts >= 4) break;
    final latest = rows.reduce((a, b) => a.stamp >= b.stamp ? a : b);
    if (owner._now().millisecondsSinceEpoch - latest.stamp >
            _MessagingOutbox._callSignalTtl.inMilliseconds ||
        !snapshot.contains(latest.frame.peerHex, latest.frame.frameId)) {
      continue;
    }
    final old = rows
        .where(
          (r) =>
              r.stamp < latest.stamp &&
              // Revocation of P2P consent is sticky; an ambiguous later grant must
              // never erase the durable withdrawal.
              (r.upgrade != false || latest.upgrade == false) &&
              snapshot.contains(r.frame.peerHex, r.frame.frameId),
        )
        .take(64)
        .map((r) => r.frame)
        .toList();
    if (old.isEmpty) continue;
    attempts++;
    // An uncertain commit cannot authorize sends from the old captured image.
    // Failure retains durable rows and the next flush reads them again.
    for (final frame in old) {
      snapshot.invalidate(_MessagingOutbox._key(frame.peerHex, frame.frameId));
    }
    try {
      final retired = await guarded.retireOutboxFramesIfCurrent(
        obsolete: old,
        retained: latest.frame,
      );
      if (owner._disposed) return;
      if (!retired) continue;
      for (final frame in old) {
        outbox._forgetRetiredFrame(frame.peerHex, frame.frameId);
      }
    } catch (error) {
      if (owner._disposed) return;
      devLog(
        () =>
            'xVeil[call-sig]: route queue cleanup deferred '
            '(${error.runtimeType})',
      );
    }
  }
}
