import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_service.dart';

void main() {
  group('negotiateCallTransport — anonymity matrix', () {
    test('anon ↔ anon → full onion', () {
      expect(
        negotiateCallTransport(
            local: CallPosture.anonymous, peer: CallPosture.anonymous),
        CallTransportKind.onion,
      );
    });

    test('mixed (anon ↔ direct) → relay, both orderings', () {
      expect(
        negotiateCallTransport(
            local: CallPosture.anonymous, peer: CallPosture.direct),
        CallTransportKind.relay,
      );
      expect(
        negotiateCallTransport(
            local: CallPosture.direct, peer: CallPosture.anonymous),
        CallTransportKind.relay,
      );
    });

    test('direct ↔ direct with mutual consent + reachable → p2p', () {
      expect(
        negotiateCallTransport(
          local: CallPosture.direct,
          peer: CallPosture.direct,
          localConsentsP2P: true,
          peerConsentsP2P: true,
          peerReachable: true,
        ),
        CallTransportKind.p2p,
      );
    });

    test('direct ↔ direct falls back to relay without consent/reachability', () {
      // no consent
      expect(
        negotiateCallTransport(
            local: CallPosture.direct, peer: CallPosture.direct),
        CallTransportKind.relay,
      );
      // one-sided consent
      expect(
        negotiateCallTransport(
          local: CallPosture.direct,
          peer: CallPosture.direct,
          localConsentsP2P: true,
          peerReachable: true,
        ),
        CallTransportKind.relay,
      );
      // both consent but unreachable
      expect(
        negotiateCallTransport(
          local: CallPosture.direct,
          peer: CallPosture.direct,
          localConsentsP2P: true,
          peerConsentsP2P: true,
        ),
        CallTransportKind.relay,
      );
    });

    test('INVARIANT: an anonymous party is NEVER put on P2P, even with every '
        'consent/reachability flag set', () {
      for (final pair in [
        (CallPosture.anonymous, CallPosture.anonymous),
        (CallPosture.anonymous, CallPosture.direct),
        (CallPosture.direct, CallPosture.anonymous),
      ]) {
        final t = negotiateCallTransport(
          local: pair.$1,
          peer: pair.$2,
          localConsentsP2P: true,
          peerConsentsP2P: true,
          peerReachable: true,
        );
        expect(t, isNot(CallTransportKind.p2p),
            reason: 'anonymity must never yield a location-revealing P2P path');
      }
    });
  });

  group('CallSignal encode/decode', () {
    test('offer round-trips through the wire body', () {
      final sig = CallSignal(
        callId: 'abc-123',
        type: CallSignalType.offer,
        media: const CallMedia(audio: true, video: true, screen: false),
        posture: CallPosture.anonymous,
        transport: const CallTransportProposal(CallTransportKind.onion),
        mediaKey: 'a2V5',
        sentAtMs: 1234567,
      );
      final back = CallSignal.tryDecode(sig.encode())!;
      expect(back.callId, 'abc-123');
      expect(back.type, CallSignalType.offer);
      expect(back.wantsAudio, isTrue);
      expect(back.wantsVideo, isTrue);
      expect(back.wantsScreen, isFalse);
      expect(back.posture, CallPosture.anonymous);
      expect(back.transport?.kind, CallTransportKind.onion);
      expect(back.mediaKey, 'a2V5');
      expect(back.sentAtMs, 1234567);
    });

    test('end carries a reason and no media', () {
      final sig = CallSignal(
        callId: 'x',
        type: CallSignalType.end,
        reason: CallEndReason.hangup,
      );
      final back = CallSignal.tryDecode(sig.encode())!;
      expect(back.type, CallSignalType.end);
      expect(back.reason, CallEndReason.hangup);
      expect(back.media, isNull);
    });

    test('an out-of-range enum index decodes to the .unknown sentinel', () {
      // Simulate a newer peer's added type/posture (indices past this build).
      final body =
          '{"c":"id","k":9999,"p":9999,"t":{"k":9999},"v":1}';
      final back = CallSignal.tryDecode(body)!;
      expect(back.type, CallSignalType.unknown);
      expect(back.posture, CallPosture.unknown);
      expect(back.transport?.kind, CallTransportKind.unknown);
    });

    test('a malformed / non-call body decodes to null', () {
      expect(CallSignal.tryDecode('not json'), isNull);
      expect(CallSignal.tryDecode('{"no":"callId"}'), isNull);
    });
  });
}
