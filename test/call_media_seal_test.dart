import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/veil_call_media.dart';

NodeId _node(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

final _self = _node(0x11);
final _peer = _node(0x22);

class _Open {
  _Open({
    required this.dstNode,
    required this.txKey,
    required this.rxKey,
    required this.direct,
    required this.relay,
  });

  final Uint8List dstNode;
  final Uint8List txKey;
  final Uint8List rxKey;
  final bool direct;
  final bool relay;
}

/// Records exactly what the media plane asked native to open. Every buffer is
/// COPIED on arrival, because the caller wipes its own the instant the open
/// returns — a fake that kept the reference would only ever see zeros.
class _RecordingOpener implements CallMediaChannelOpener {
  _RecordingOpener({this.directFailure, this.directFailureAttempts});

  final String? directFailure;
  final int? directFailureAttempts;
  final List<_Open> opens = [];
  int _nextChannel = 100;
  int _directAttempts = 0;

  @override
  Future<int> openMediaChannel(
    Uint8List dstNode, {
    required Uint8List txKey,
    required Uint8List rxKey,
    bool direct = false,
    bool relay = false,
  }) async {
    opens.add(
      _Open(
        dstNode: Uint8List.fromList(dstNode),
        txKey: Uint8List.fromList(txKey),
        rxKey: Uint8List.fromList(rxKey),
        direct: direct,
        relay: relay,
      ),
    );
    if (direct) {
      _directAttempts++;
      if (directFailure != null &&
          (directFailureAttempts == null ||
              _directAttempts <= directFailureAttempts!)) {
        throw StateError(directFailure!);
      }
    }
    return ++_nextChannel;
  }
}

Call _call({
  required CallTransportKind route,
  CallDirection direction = CallDirection.outgoing,
  NodeId? peer,
  NodeId? peerIdentity,
  NodeId? peerDevice,
  String? localMediaKey,
  String? peerMediaKey,
  int? peerProtocolVersion = kCallSignalProtocolVersion,
  String callId = 'sealed-media',
}) => Call(
  callId: callId,
  peer: peer ?? _peer,
  peerIdentity: peerIdentity,
  peerDevice: peerDevice,
  direction: direction,
  media: const CallMedia(audio: true),
  status: CallStatus.connecting,
  localPosture: CallPosture.direct,
  startedAt: DateTime.fromMillisecondsSinceEpoch(1),
  transport: route,
  peerProtocolVersion: peerProtocolVersion,
  localMediaKey: localMediaKey,
  peerMediaKey: peerMediaKey,
);

void main() {
  group('warm session media attribution', () {
    final device = _node(0xD2);
    Call warmCall(CallTransportKind route) => _call(
      route: route,
      peerDevice: device,
      localMediaKey: generateCallMediaKeyContribution(),
      peerMediaKey: generateCallMediaKeyContribution(),
    ).copyWith(mediaRoutePeer: _peer);

    test(
      'relay receives under the device even with an admitted session',
      () async {
        final call = warmCall(CallTransportKind.relay);
        expect(callMediaRoutePeer(call, sessionAdmitted: true), device);
        final opener = _RecordingOpener();
        final opened = await openSealedCallMediaChannel(
          call: call,
          opener: opener,
          localNodeId: _self.bytes,
        );
        expect(opener.opens.single.dstNode, device.bytes);
        expect(opened!.peer, device);
      },
    );

    test('direct media retains the authenticated identity address', () async {
      final call = warmCall(CallTransportKind.p2p);
      expect(callMediaRoutePeer(call, sessionAdmitted: true), _peer);
      expect(callMediaRoutePeer(call, sessionAdmitted: false), device);
      final opener = _RecordingOpener();
      final opened = await openSealedCallMediaChannel(
        call: call,
        opener: opener,
        localNodeId: _self.bytes,
      );
      expect(opener.opens.single.dstNode, _peer.bytes);
      expect(opened!.peer, _peer);
    });

    test(
      'cold admission retries the identity despite a stale device route',
      () async {
        final call = warmCall(
          CallTransportKind.p2p,
        ).copyWith(mediaRoutePeer: device);
        final opener = _RecordingOpener(
          directFailure: 'direct media session is not active',
          directFailureAttempts: 1,
        );
        final opened = await openSealedCallMediaChannel(
          call: call,
          opener: opener,
          localNodeId: _self.bytes,
          directRetryDelay: Duration.zero,
        );
        expect(opened!.transport, CallTransportKind.p2p);
        expect(opened.peer, _peer);
        expect(opened.fallbackReason, isNull);
        expect(opener.opens, hasLength(2));
        final keys = deriveCallMediaKeys(call: call, localNodeId: _self.bytes);
        for (final wire in opener.opens) {
          expect(wire.direct, isTrue);
          expect(wire.relay, isFalse);
          expect(wire.dstNode, _peer.bytes);
          expect(wire.txKey, keys.txKey);
          expect(wire.rxKey, keys.rxKey);
        }
      },
    );

    test(
      'failed direct media rebinds relay receive and repair to the device',
      () async {
        final call = warmCall(CallTransportKind.p2p);
        final opener = _RecordingOpener(
          directFailure: 'direct session not active',
        );
        final opened = await openSealedCallMediaChannel(
          call: call,
          opener: opener,
          localNodeId: _self.bytes,
        );
        expect(opener.opens.first.dstNode, _peer.bytes);
        expect(opener.opens.last.dstNode, device.bytes);
        expect(opened!.peer, device);
        expect(opened.transport, CallTransportKind.relay);
        expect(opener.opens.last.txKey, opener.opens.first.txKey);
        expect(opener.opens.last.rxKey, opener.opens.first.rxKey);
      },
    );
  });

  const routes = [
    CallTransportKind.p2p,
    CallTransportKind.relay,
    CallTransportKind.onion,
  ];

  group('call media is sealed on every transport', () {
    test('each negotiated route opens a channel under this call\'s keys', () async {
      for (final route in routes) {
        final call = _call(
          route: route,
          localMediaKey: generateCallMediaKeyContribution(),
          peerMediaKey: generateCallMediaKeyContribution(),
        );
        final opener = _RecordingOpener();

        final opened = await openSealedCallMediaChannel(
          call: call,
          opener: opener,
          localNodeId: _self.bytes,
        );

        expect(opened, isNotNull, reason: '${route.name} media must come up');
        expect(opened!.transport, route);
        expect(opened.channel, greaterThan(0));
        expect(opened.fallbackReason, isNull);
        expect(opener.opens, hasLength(1), reason: '${route.name}: one open');

        final wire = opener.opens.single;
        expect(wire.dstNode, _peer.bytes);
        expect(wire.direct, route == CallTransportKind.p2p);
        expect(wire.relay, route == CallTransportKind.relay);

        // The route carries THIS call's directional keys — not a placeholder,
        // not an empty buffer, not the same key in both directions.
        final expected = deriveCallMediaKeys(
          call: call,
          localNodeId: _self.bytes,
        );
        expect(wire.txKey, expected.txKey, reason: '${route.name} tx');
        expect(wire.rxKey, expected.rxKey, reason: '${route.name} rx');
        expect(wire.txKey, hasLength(32));
        expect(wire.rxKey, hasLength(32));
        expect(wire.txKey, isNot(wire.rxKey));
        expect(
          wire.txKey.any((byte) => byte != 0),
          isTrue,
          reason: '${route.name}: an all-zero key is not a key',
        );
        expect(wire.rxKey.any((byte) => byte != 0), isTrue);
      }
    });

    test('caller TX equals callee RX on every route', () async {
      final callerContribution = generateCallMediaKeyContribution();
      final calleeContribution = generateCallMediaKeyContribution();
      for (final route in routes) {
        final callerOpener = _RecordingOpener();
        final calleeOpener = _RecordingOpener();

        final callerOpened = await openSealedCallMediaChannel(
          call: _call(
            route: route,
            direction: CallDirection.outgoing,
            peer: _peer,
            localMediaKey: callerContribution,
            peerMediaKey: calleeContribution,
          ),
          opener: callerOpener,
          localNodeId: _self.bytes,
        );
        final calleeOpened = await openSealedCallMediaChannel(
          call: _call(
            route: route,
            direction: CallDirection.incoming,
            peer: _self,
            localMediaKey: calleeContribution,
            peerMediaKey: callerContribution,
          ),
          opener: calleeOpener,
          localNodeId: _peer.bytes,
        );

        expect(callerOpened, isNotNull);
        expect(calleeOpened, isNotNull);
        expect(
          callerOpener.opens.single.txKey,
          calleeOpener.opens.single.rxKey,
          reason: '${route.name}: the callee must be able to open what the '
              'caller sealed',
        );
        expect(
          callerOpener.opens.single.rxKey,
          calleeOpener.opens.single.txKey,
          reason: '${route.name}: and the other way round',
        );
      }
    });

    test('the permitted p2p→relay fallback reopens under the same keys', () async {
      final call = _call(
        route: CallTransportKind.p2p,
        localMediaKey: generateCallMediaKeyContribution(),
        peerMediaKey: generateCallMediaKeyContribution(),
      );
      final opener = _RecordingOpener(directFailure: 'direct session not active');

      final opened = await openSealedCallMediaChannel(
        call: call,
        opener: opener,
        localNodeId: _self.bytes,
        directRetryDelay: Duration.zero,
      );

      expect(opened, isNotNull);
      expect(opened!.transport, CallTransportKind.relay);
      expect(opened.fallbackReason, 'no direct session to peer');
      expect(opener.opens, hasLength(3));
      expect(opener.opens.take(2).every((wire) => wire.direct), isTrue);
      expect(opener.opens.last.relay, isTrue);
      final expected = deriveCallMediaKeys(call: call, localNodeId: _self.bytes);
      for (final wire in opener.opens) {
        expect(wire.txKey, expected.txKey);
        expect(wire.rxKey, expected.rxKey);
      }
    });
  });

  group('a channel that cannot be sealed does not open', () {
    test('a missing peer contribution opens nothing at all', () async {
      for (final route in routes) {
        final opener = _RecordingOpener();
        final opened = await openSealedCallMediaChannel(
          call: _call(
            route: route,
            localMediaKey: generateCallMediaKeyContribution(),
          ),
          opener: opener,
          localNodeId: _self.bytes,
        );
        expect(opened, isNull, reason: '${route.name} must not come up');
        expect(
          opener.opens,
          isEmpty,
          reason: '${route.name}: native was asked to open an unsealed channel',
        );
      }
    });

    test('a missing local contribution opens nothing at all', () async {
      final opener = _RecordingOpener();
      final opened = await openSealedCallMediaChannel(
        call: _call(
          route: CallTransportKind.relay,
          peerMediaKey: generateCallMediaKeyContribution(),
        ),
        opener: opener,
        localNodeId: _self.bytes,
      );
      expect(opened, isNull);
      expect(opener.opens, isEmpty);
    });

    test('a malformed peer contribution opens nothing at all', () async {
      for (final bad in ['', 'a2V5', '${generateCallMediaKeyContribution()}x']) {
        final opener = _RecordingOpener();
        final opened = await openSealedCallMediaChannel(
          call: _call(
            route: CallTransportKind.onion,
            localMediaKey: generateCallMediaKeyContribution(),
            peerMediaKey: bad,
          ),
          opener: opener,
          localNodeId: _self.bytes,
        );
        expect(opened, isNull, reason: 'contribution ${bad.length} chars');
        expect(opener.opens, isEmpty);
      }
    });

    test('derivation refuses a key pair it cannot bind to this node', () {
      expect(
        () => deriveCallMediaKeys(
          call: _call(
            route: CallTransportKind.relay,
            localMediaKey: generateCallMediaKeyContribution(),
            peerMediaKey: generateCallMediaKeyContribution(),
          ),
          localNodeId: Uint8List(16),
        ),
        throwsArgumentError,
      );
    });
  });

  group('the peer cannot talk the seal away', () {
    test('the advertised protocol version changes nothing', () async {
      final localContribution = generateCallMediaKeyContribution();
      final peerContribution = generateCallMediaKeyContribution();
      Uint8List? firstTx;
      Uint8List? firstRx;
      // 1 and 2 are the versions that used to mean "this peer cannot seal";
      // the field arrives unauthenticated, so it must not reach the decision.
      for (final version in <int?>[null, 1, 2, 3, 99]) {
        final opener = _RecordingOpener();
        final opened = await openSealedCallMediaChannel(
          call: _call(
            route: CallTransportKind.relay,
            localMediaKey: localContribution,
            peerMediaKey: peerContribution,
            peerProtocolVersion: version,
          ),
          opener: opener,
          localNodeId: _self.bytes,
        );
        expect(opened, isNotNull, reason: 'version $version must still seal');
        expect(opener.opens, hasLength(1));
        firstTx ??= opener.opens.single.txKey;
        firstRx ??= opener.opens.single.rxKey;
        expect(
          opener.opens.single.txKey,
          firstTx,
          reason: 'version $version moved the tx key',
        );
        expect(
          opener.opens.single.rxKey,
          firstRx,
          reason: 'version $version moved the rx key',
        );
      }
    });

    test('a different call id yields different keys', () {
      final localContribution = generateCallMediaKeyContribution();
      final peerContribution = generateCallMediaKeyContribution();
      final first = deriveCallMediaKeys(
        call: _call(
          route: CallTransportKind.relay,
          callId: 'call-one',
          localMediaKey: localContribution,
          peerMediaKey: peerContribution,
        ),
        localNodeId: _self.bytes,
      );
      final second = deriveCallMediaKeys(
        call: _call(
          route: CallTransportKind.relay,
          callId: 'call-two',
          localMediaKey: localContribution,
          peerMediaKey: peerContribution,
        ),
        localNodeId: _self.bytes,
      );
      expect(first.txKey, isNot(second.txKey));
      expect(first.rxKey, isNot(second.rxKey));
    });

    test('an unimplemented route is refused rather than opened', () async {
      final opener = _RecordingOpener();
      await expectLater(
        openSealedCallMediaChannel(
          call: _call(
            route: CallTransportKind.unknown,
            localMediaKey: generateCallMediaKeyContribution(),
            peerMediaKey: generateCallMediaKeyContribution(),
          ),
          opener: opener,
          localNodeId: _self.bytes,
        ),
        throwsStateError,
      );
      expect(opener.opens, isEmpty);
    });
  });

  group('the seal is keyed to the address the peer has for us', () {
    // The device ids are NOT the identity ids here, which is the whole point:
    // every earlier test in this file handed both ends the same pair of node
    // ids, so the derivation — symmetric by construction — could not fail. The
    // defect lived one level up, in WHICH id the call site handed it, and it
    // shipped green.
    final callerIdentity = _node(0x31);
    final callerDevice = _node(0xA1);
    final calleeIdentity = _node(0x32);
    final calleeDevice = _node(0xA2);

    test('both ends derive one pair when each uses its IDENTITY', () async {
      final callerContribution = generateCallMediaKeyContribution();
      final calleeContribution = generateCallMediaKeyContribution();

      final caller = deriveCallMediaKeys(
        call: _call(
          route: CallTransportKind.p2p,
          direction: CallDirection.outgoing,
          peer: calleeIdentity,
          localMediaKey: callerContribution,
          peerMediaKey: calleeContribution,
        ),
        localNodeId: callerIdentity.bytes,
      );
      final callee = deriveCallMediaKeys(
        call: _call(
          route: CallTransportKind.p2p,
          direction: CallDirection.incoming,
          peer: callerIdentity,
          localMediaKey: calleeContribution,
          peerMediaKey: callerContribution,
        ),
        localNodeId: calleeIdentity.bytes,
      );

      expect(caller.txKey, callee.rxKey);
      expect(caller.rxKey, callee.txKey);
    });

    test('a forked call routes to devices while sealing for identities', () async {
      final callerContribution = generateCallMediaKeyContribution();
      final calleeContribution = generateCallMediaKeyContribution();
      final caller = _call(
        route: CallTransportKind.relay,
        peer: calleeDevice,
        peerIdentity: calleeIdentity,
        peerDevice: calleeDevice,
        localMediaKey: callerContribution,
        peerMediaKey: calleeContribution,
      );
      final callee = _call(
        route: CallTransportKind.relay,
        direction: CallDirection.incoming,
        peer: callerIdentity,
        peerIdentity: callerIdentity,
        peerDevice: callerDevice,
        localMediaKey: calleeContribution,
        peerMediaKey: callerContribution,
      );
      final callerOpener = _RecordingOpener();
      final calleeOpener = _RecordingOpener();
      await openSealedCallMediaChannel(
        call: caller,
        opener: callerOpener,
        localNodeId: callerIdentity.bytes,
      );
      await openSealedCallMediaChannel(
        call: callee,
        opener: calleeOpener,
        localNodeId: calleeIdentity.bytes,
      );
      expect(callerOpener.opens.single.dstNode, calleeDevice.bytes);
      expect(calleeOpener.opens.single.dstNode, callerDevice.bytes);
      expect(callerOpener.opens.single.txKey, calleeOpener.opens.single.rxKey);
      expect(callerOpener.opens.single.rxKey, calleeOpener.opens.single.txKey);
    });

    test('a DEVICE id on one end seals what the other cannot open', () {
      // What production actually did, and what it cost: the caller asked the
      // transport for its own node id (the device) while the callee could only
      // put the caller's IDENTITY in the same slot. Measured on the stand
      // 2026-09-19 as `media.ingress.arrived n=1000` against
      // `media.ingress.drop reason=seal-open-failed n=1000` — every cell
      // delivered, every cell refused, on both sides of a live p2p call.
      final callerContribution = generateCallMediaKeyContribution();
      final calleeContribution = generateCallMediaKeyContribution();

      final callerOnItsDevice = deriveCallMediaKeys(
        call: _call(
          route: CallTransportKind.p2p,
          direction: CallDirection.outgoing,
          peer: calleeIdentity,
          localMediaKey: callerContribution,
          peerMediaKey: calleeContribution,
        ),
        localNodeId: callerDevice.bytes,
      );
      final calleeOnItsDevice = deriveCallMediaKeys(
        call: _call(
          route: CallTransportKind.p2p,
          direction: CallDirection.incoming,
          peer: callerIdentity,
          localMediaKey: calleeContribution,
          peerMediaKey: callerContribution,
        ),
        localNodeId: calleeDevice.bytes,
      );

      expect(
        callerOnItsDevice.txKey,
        isNot(calleeOnItsDevice.rxKey),
        reason: 'this is the silence, stated as an assertion',
      );
    });

    test('the transport offers the identity, and the device only without one', () {
      expect(
        peerFacingNodeIdOf(
          deviceNodeId: callerDevice,
          identityAddress: callerIdentity.bytes,
        ).hex,
        callerIdentity.hex,
      );
      // An identity with no document IS its own device key, and the two
      // coincide — which is exactly why every call between such peers kept
      // working and hid the defect for everyone else.
      expect(
        peerFacingNodeIdOf(
          deviceNodeId: callerDevice,
          identityAddress: null,
        ).hex,
        callerDevice.hex,
      );
    });
  });
}
