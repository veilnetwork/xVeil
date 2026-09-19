import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/call_video_prompt.dart';
import 'package:xveil/state/messaging_core.dart';

/// Minimal [MessagingService] stand-in — only what the control-plane FSM
/// touches is real; everything else is never reached from these tests.
class _FakeMessaging implements MessagingService {
  @override
  bool backgroundStashPaused = false;
  final List<(NodeId, CallSignal)> sentTo = [];

  @override
  bool get isAnonymousIdentity => false;

  @override
  void Function(NodeId, CallSignal)? onCallSignal;

  @override
  Future<void> sendCallSignal(NodeId peer, CallSignal signal) async {
    sentTo.add((peer, signal));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final peer = NodeId.fromHex('a' * 64);
  final stranger = NodeId.fromHex('b' * 64);

  ({_FakeMessaging messaging, CallService svc}) liveVideoCall() {
    final messaging = _FakeMessaging();
    final svc = CallService(messaging)..start();
    messaging.onCallSignal!(
      peer,
      const CallSignal(
        callId: 'weak-link',
        type: CallSignalType.offer,
        media: CallMedia(audio: true, video: true),
        posture: CallPosture.direct,
      ),
    );
    svc.accept();
    return (messaging: messaging, svc: svc);
  }

  setUp(() => callVideoPrompt.value = null);
  tearDown(() => callVideoPrompt.value = null);

  test('a peer asking for audio-only raises the offer, it does not act', () {
    final h = liveVideoCall();
    expect(callVideoPrompt.value, isNull);
    h.messaging.onCallSignal!(
      peer,
      const CallSignal(callId: 'weak-link', type: CallSignalType.askVideoOff),
    );
    expect(callVideoPrompt.value, CallVideoPromptCause.peerAsked);
    // THE POINT: a remote party must not be able to switch off a local
    // camera. The request raises an offer; the user decides.
    expect(h.svc.current!.cameraOn, isTrue);
    h.svc.dispose();
  });

  test('a request naming another call is not about this one', () {
    final h = liveVideoCall();
    h.messaging.onCallSignal!(
      peer,
      const CallSignal(callId: 'some-other', type: CallSignalType.askVideoOff),
    );
    expect(callVideoPrompt.value, isNull);
    h.svc.dispose();
  });

  test('a request from someone who is not the peer is ignored', () {
    final h = liveVideoCall();
    h.messaging.onCallSignal!(
      stranger,
      const CallSignal(callId: 'weak-link', type: CallSignalType.askVideoOff),
    );
    expect(callVideoPrompt.value, isNull);
    h.svc.dispose();
  });

  test('nothing is offered when there is no video to drop', () async {
    final messaging = _FakeMessaging();
    final svc = CallService(messaging)..start();
    messaging.onCallSignal!(
      peer,
      const CallSignal(
        callId: 'audio-only',
        type: CallSignalType.offer,
        media: CallMedia(audio: true),
        posture: CallPosture.direct,
      ),
    );
    svc.accept();
    messaging.onCallSignal!(
      peer,
      const CallSignal(callId: 'audio-only', type: CallSignalType.askVideoOff),
    );
    expect(callVideoPrompt.value, isNull);
    svc.dispose();
  });

  test('asking the peer sends exactly one request, to the peer', () async {
    final h = liveVideoCall();
    h.messaging.sentTo.clear();
    await h.svc.askPeerToStopVideo();
    final asks = h.messaging.sentTo
        .where((s) => s.$2.type == CallSignalType.askVideoOff)
        .toList();
    expect(asks.length, 1);
    expect(asks.single.$1, peer);
    expect(asks.single.$2.callId, 'weak-link');
    h.svc.dispose();
  });

  test('there is nobody to ask when no call is live', () async {
    final messaging = _FakeMessaging();
    final svc = CallService(messaging)..start();
    await svc.askPeerToStopVideo();
    expect(messaging.sentTo, isEmpty);
    svc.dispose();
  });

  test('the offer does not outlive the call that raised it', () {
    final h = liveVideoCall();
    h.messaging.onCallSignal!(
      peer,
      const CallSignal(callId: 'weak-link', type: CallSignalType.askVideoOff),
    );
    expect(callVideoPrompt.value, isNotNull);
    h.messaging.onCallSignal!(
      peer,
      const CallSignal(callId: 'weak-link', type: CallSignalType.end),
    );
    expect(
      callVideoPrompt.value,
      isNull,
      reason: 'a banner about a finished call still offers to act on it',
    );
    h.svc.dispose();
  });
}
