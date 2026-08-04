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
  _RecordingOpener({this.directFailure});

  final String? directFailure;
  final List<_Open> opens = [];
  int _nextChannel = 100;

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
    if (direct && directFailure != null) throw StateError(directFailure!);
    return ++_nextChannel;
  }
}

Call _call({
  required CallTransportKind route,
  CallDirection direction = CallDirection.outgoing,
  NodeId? peer,
  String? localMediaKey,
  String? peerMediaKey,
  int? peerProtocolVersion = kCallSignalProtocolVersion,
  String callId = 'sealed-media',
}) => Call(
  callId: callId,
  peer: peer ?? _peer,
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
}
