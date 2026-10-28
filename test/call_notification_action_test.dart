import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/features/calls/call_lifecycle_bridge.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/group_call_service.dart';
import 'package:xveil/state/messaging.dart';

void main() {
  testWidgets('background ringing does not require a Flutter frame', (
    tester,
  ) async {
    final wire = _Wire();
    final service = CallService(wire, media: _Media())..start();
    final container = ProviderContainer(
      overrides: [
        callServiceProvider.overrideWithValue(service),
        groupCallServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(service.dispose);
    var rings = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemSound.play') rings++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: CallLifecycleBridge()),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    wire.onCallSignal!(
      NodeId.fromHex('a' * 64),
      const CallSignal(
        callId: 'background-notification-call',
        type: CallSignalType.offer,
        media: CallMedia(audio: true),
        posture: CallPosture.direct,
        transport: CallTransportProposal(CallTransportKind.relay),
      ),
    );
    await tester.idle();
    expect(service.current?.status, CallStatus.ringing);
    expect(
      rings,
      1,
      reason: 'platform call effects must run without a UI frame',
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    await tester.pump();
  });

  for (final action in ['accept', 'hangup']) {
    testWidgets('delayed unscoped $action cannot act on the next call', (
      tester,
    ) async {
      final wire = _Wire();
      final service = CallService(wire, media: _Media())..start();
      final container = ProviderContainer(
        overrides: [
          callServiceProvider.overrideWithValue(service),
          groupCallServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(service.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: CallLifecycleBridge()),
        ),
      );
      final peer = NodeId.fromHex('a' * 64);
      void offer(String id) => wire.onCallSignal!(
        peer,
        CallSignal(
          callId: id,
          type: CallSignalType.offer,
          media: const CallMedia(audio: true),
          posture: CallPosture.direct,
          transport: const CallTransportProposal(CallTransportKind.relay),
          mediaKey: generateCallMediaKeyContribution(),
        ),
      );
      offer('old-notification-call');
      await tester.pump();
      await service.hangup();
      await tester.pump();
      offer('next-notification-call');
      await tester.pump();
      if (action == 'hangup') {
        await service.accept();
        await tester.pump();
      }
      final before = service.current;
      expect(before?.callId, 'next-notification-call');
      expect(
        before?.status,
        action == 'hangup' ? CallStatus.active : CallStatus.ringing,
      );
      // The native capability was valid when consumed for the previous call.
      // Delivery to Dart happens after that call ended and another began.
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'xveil/call_actions',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('callAction', action),
        ),
        (_) {},
      );
      await tester.pump();
      expect(service.current, same(before));
      await tester.pumpWidget(const SizedBox.shrink());
      service.dispose();
      await tester.pump();
    });
  }
}

class _Media extends CallMediaController {
  @override
  CallTransportKind get activeTransport => CallTransportKind.relay;
  @override
  Future<bool> start(Call call) async => true;
  @override
  Future<void> stop() async {}
}

class _Wire implements MessagingService {
  @override
  bool get isAnonymousIdentity => false;
  @override
  bool backgroundStashPaused = false;
  @override
  void Function(NodeId, CallSignal)? onCallSignal;
  @override
  bool Function(NodeId, CallSignal)? acceptsCallDeviceSignal;
  @override
  Future<void> sendCallSignal(NodeId peer, CallSignal signal) async {}
  @override
  Future<NodeId> localDeviceId() async => NodeId.fromHex('f' * 64);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
