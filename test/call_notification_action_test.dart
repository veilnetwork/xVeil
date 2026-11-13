import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/features/calls/call_lifecycle_bridge.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/group_call_service.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/notifications.dart';

class _DesktopAlerts extends NotificationService {
  final visible = <int, ({String title, String body, String? payload})>{};
  Completer<void>? showGate;
  Completer<void>? showEntered;
  Completer<void>? readyGate;
  Completer<void>? readyEntered;
  int showCalls = 0;

  @override
  bool get isReady => true;

  @override
  Future<bool> waitUntilReady() async {
    if (readyEntered?.isCompleted == false) readyEntered!.complete();
    await readyGate?.future;
    return true;
  }

  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? replyLabel,
    String? replyHint,
  }) async {
    showCalls++;
    if (showEntered?.isCompleted == false) showEntered!.complete();
    await showGate?.future;
    visible[id] = (title: title, body: body, payload: payload);
    return true;
  }

  @override
  Future<void> cancel(int id) async => visible.remove(id);
}

class _CallAlertSettings extends NotificationSettingsController {
  _CallAlertSettings([this.initial = NotificationSettings.defaults]);
  final NotificationSettings initial;
  @override
  NotificationSettings build() => initial;
  void replace(NotificationSettings next) => state = next;
}

class _GroupAlerts implements GroupCallService {
  final events = StreamController<GroupCall?>.broadcast(sync: true);
  @override
  GroupCall? current;
  @override
  Stream<GroupCall?> get changes => events.stream;
  void emit(GroupCall? call) {
    current = call;
    events.add(call);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CallSignal _desktopOffer(String id) => CallSignal(
  callId: id,
  type: CallSignalType.offer,
  media: const CallMedia(audio: true),
  posture: CallPosture.direct,
  transport: const CallTransportProposal(CallTransportKind.relay),
  mediaKey: generateCallMediaKeyContribution(),
);

void main() {
  Future<
    ({
      CallService service,
      _Wire wire,
      ProviderContainer container,
      StateProvider<CallService> source,
    })
  >
  mountDesktop(
    WidgetTester tester,
    _DesktopAlerts alerts, {
    NotificationSettings settings = NotificationSettings.defaults,
    GroupCallService? group,
  }) async {
    final wire = _Wire();
    final service = CallService(wire, media: _Media())..start();
    final source = StateProvider<CallService>((_) => service);
    final container = ProviderContainer(
      overrides: [
        callServiceProvider.overrideWith((ref) => ref.watch(source)),
        groupCallServiceProvider.overrideWithValue(group),
        notificationServiceProvider.overrideWithValue(alerts),
        notificationSettingsProvider.overrideWith(
          () => _CallAlertSettings(settings),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(service.dispose);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: CallLifecycleBridge()),
      ),
    );
    return (service: service, wire: wire, container: container, source: source);
  }

  testWidgets('group ringing posts without a frame and clears on join', (
    tester,
  ) async {
    final alerts = _DesktopAlerts();
    final group = _GroupAlerts();
    addTearDown(group.events.close);
    await mountDesktop(tester, alerts, group: group);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final call = GroupCall(
      groupId: NodeId.fromHex('c' * 64),
      callId: 'group-alert',
      initiator: NodeId.fromHex('a' * 64),
      membershipEpoch: 1,
      media: const CallMedia(audio: true),
      status: GroupCallStatus.ringing,
      startedAt: DateTime.utc(2026),
      participants: const {},
    );
    group.emit(call);
    await tester.idle();
    expect(alerts.visible.length, 1);
    expect(
      alerts.visible.values.single.payload,
      kNotificationPayloadIncomingCall,
    );
    group.emit(call.copyWith(status: GroupCallStatus.active));
    await tester.idle();
    expect(alerts.visible, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ringing surfaces on background and clears on foreground', (
    tester,
  ) async {
    final alerts = _DesktopAlerts();
    final f = await mountDesktop(tester, alerts);
    f.wire.onCallSignal!(
      NodeId.fromHex('a' * 64),
      _desktopOffer('visible-call'),
    );
    await tester.idle();
    expect(alerts.showCalls, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.idle();
    expect(alerts.visible.length, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.idle();
    expect(alerts.visible, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.idle();
    expect(alerts.showCalls, 2);
    await f.service.hangup();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('notification preference changes apply to a ringing call', (
    tester,
  ) async {
    final alerts = _DesktopAlerts();
    final f = await mountDesktop(
      tester,
      alerts,
      settings: NotificationSettings.defaults.copyWith(enabled: false),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    f.wire.onCallSignal!(
      NodeId.fromHex('a' * 64),
      _desktopOffer('preference-call'),
    );
    await tester.idle();
    expect(alerts.showCalls, 0);
    final settings =
        f.container.read(notificationSettingsProvider.notifier)
            as _CallAlertSettings;
    settings.replace(NotificationSettings.defaults);
    await tester.idle();
    expect(alerts.visible.length, 1);
    settings.replace(NotificationSettings.defaults.copyWith(enabled: false));
    await tester.idle();
    expect(alerts.visible, isEmpty);
    await f.service.hangup();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late post for an ended call cannot cancel its replacement', (
    tester,
  ) async {
    final alerts = _DesktopAlerts()
      ..showGate = Completer<void>()
      ..showEntered = Completer<void>();
    final f = await mountDesktop(
      tester,
      alerts,
      settings: NotificationSettings.defaults.copyWith(
        preview: NotificationPreview.full,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    f.wire.onCallSignal!(
      NodeId.fromHex('a' * 64),
      _desktopOffer('old-desktop-call'),
    );
    await tester.idle();
    expect(alerts.showEntered!.isCompleted, isTrue);
    await f.service.hangup();
    final replacement = NodeId.fromHex('b' * 64);
    f.wire.onCallSignal!(replacement, _desktopOffer('new-desktop-call'));
    await tester.idle();
    alerts.showGate!.complete();
    await tester.idle();
    expect(alerts.visible.length, 1);
    expect(alerts.visible.values.single.body, replacement.short);
    await f.service.hangup();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'identity change invalidates a post even if the old call still rings',
    (tester) async {
      final alerts = _DesktopAlerts()
        ..showGate = Completer<void>()
        ..showEntered = Completer<void>();
      final f = await mountDesktop(tester, alerts);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      f.wire.onCallSignal!(
        NodeId.fromHex('a' * 64),
        _desktopOffer('old-identity-call'),
      );
      await tester.idle();
      expect(alerts.showEntered!.isCompleted, isTrue);
      final other = CallService(_Wire(), media: _Media())..start();
      addTearDown(other.dispose);
      f.container.read(f.source.notifier).state = other;
      await tester.idle();
      expect(f.service.current?.status, CallStatus.ringing);
      alerts.showGate!.complete();
      await tester.idle();
      expect(alerts.visible, isEmpty);
      await f.service.hangup();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a call ended during notification startup is never posted', (
    tester,
  ) async {
    final alerts = _DesktopAlerts()
      ..readyGate = Completer<void>()
      ..readyEntered = Completer<void>();
    final f = await mountDesktop(tester, alerts);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    f.wire.onCallSignal!(
      NodeId.fromHex('a' * 64),
      _desktopOffer('startup-call'),
    );
    await tester.idle();
    expect(alerts.readyEntered!.isCompleted, isTrue);
    await f.service.hangup();
    alerts.readyGate!.complete();
    await tester.idle();
    expect(alerts.showCalls, 0);
    expect(alerts.visible, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'desktop background call posts an opaque OS alert without a frame',
    (tester) async {
      final wire = _Wire();
      final service = CallService(wire, media: _Media())..start();
      final alerts = _DesktopAlerts();
      final container = ProviderContainer(
        overrides: [
          callServiceProvider.overrideWithValue(service),
          groupCallServiceProvider.overrideWithValue(null),
          notificationServiceProvider.overrideWithValue(alerts),
          notificationSettingsProvider.overrideWith(_CallAlertSettings.new),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(service.dispose);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: CallLifecycleBridge()),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final peer = NodeId.fromHex('a' * 64);
      wire.onCallSignal!(
        peer,
        CallSignal(
          callId: 'desktop-alert-call',
          type: CallSignalType.offer,
          media: const CallMedia(audio: true),
          posture: CallPosture.direct,
          transport: const CallTransportProposal(CallTransportKind.relay),
          mediaKey: generateCallMediaKeyContribution(),
        ),
      );
      await tester.idle();
      expect(service.current?.status, CallStatus.ringing);
      expect(
        alerts.visible.length,
        1,
        reason: 'an incoming desktop call needs an OS alert while hidden',
      );
      final alert = alerts.visible.values.single;
      expect(alert.title, 'xVeil');
      expect(alert.body, isNotEmpty);
      expect(
        '${alert.title} ${alert.body} ${alert.payload}',
        isNot(contains(peer.hex)),
      );
      expect(alert.payload, isNot(contains('desktop-alert-call')));
      await service.hangup();
      await tester.idle();
      expect(alerts.visible, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
