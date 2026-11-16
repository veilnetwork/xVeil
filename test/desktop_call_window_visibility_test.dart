import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/features/calls/call_lifecycle_bridge.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/group_call_service.dart';
import 'package:xveil/state/messaging.dart';

void main() {
  test('call toast has a generic destination and no inline text reply', () {
    expect(
      notificationRouteForPayload(kNotificationPayloadIncomingCall),
      '/home',
    );
    expect(
      notificationPayloadSupportsReply(kNotificationPayloadIncomingCall),
      isFalse,
    );
    expect(
      kNotificationIdIncomingCall,
      isNot(notificationIdForIncomingMessage('')),
    );
    expect(kNotificationIdIncomingCall, isNot(kNotificationIdClearRequests));
  });

  for (final hidden in [true, false]) {
    testWidgets(
      'Windows incoming call alert follows hidden window=$hidden',
      (tester) async {
        final wire = _Wire();
        final service = CallService(wire, media: _Media())..start();
        final alerts = _Alerts();
        final container = ProviderContainer(
          overrides: [
            callServiceProvider.overrideWithValue(service),
            groupCallServiceProvider.overrideWithValue(null),
            notificationServiceProvider.overrideWithValue(alerts),
            notificationSettingsProvider.overrideWith(_Settings.new),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(service.dispose);
        const window = MethodChannel('window_manager');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(window, (
          call,
        ) async {
          if (call.method == 'isVisible' || call.method == 'isFocused') {
            return !hidden;
          }
          if (call.method == 'show' || call.method == 'focus') {
            fail('an incoming alert must never take over window focus');
          }
          return null;
        });
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            window,
            null,
          ),
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: CallLifecycleBridge()),
          ),
        );
        wire.onCallSignal!(
          NodeId.fromHex('a' * 64),
          const CallSignal(
            callId: 'private-call-reference',
            type: CallSignalType.offer,
            media: CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: CallTransportProposal(CallTransportKind.relay),
          ),
        );
        await tester.idle();
        expect(service.current?.status, CallStatus.ringing);
        expect(alerts.posts, hasLength(hidden ? 1 : 0));
        if (hidden) {
          final post = alerts.posts.single;
          expect(post.title, 'xVeil');
          expect(post.body, isNotEmpty);
          expect(post.payload, isNot(contains('private-call-reference')));
          expect(post.payload, isNot(contains('a' * 64)));
        }
        await service.hangup();
        await tester.idle();
        if (hidden) expect(alerts.cancelled, contains(alerts.posts.single.id));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.idle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
  for (final lateQuery in [false, true]) {
    testWidgets(
      'Windows visibility refresh invalidates alert lateQuery=$lateQuery',
      (tester) async {
        final wire = _Wire();
        final service = CallService(wire, media: _Media())..start();
        final alerts = _Alerts();
        final container = ProviderContainer(
          overrides: [
            callServiceProvider.overrideWithValue(service),
            groupCallServiceProvider.overrideWithValue(null),
            notificationServiceProvider.overrideWithValue(alerts),
            notificationSettingsProvider.overrideWith(_Settings.new),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(service.dispose);
        var focused = false;
        final query = Completer<void>();
        var queries = 0;
        const window = MethodChannel('window_manager');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(window, (
          call,
        ) async {
          if (call.method == 'isVisible') return true;
          if (call.method == 'isFocused') {
            queries++;
            if (lateQuery) await query.future;
            return focused;
          }
          if (call.method == 'show' || call.method == 'focus') {
            fail('background call handling must not activate a window');
          }
          return null;
        });
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            window,
            null,
          ),
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: CallLifecycleBridge()),
          ),
        );
        wire.onCallSignal!(
          NodeId.fromHex('a' * 64),
          CallSignal(
            callId: 'visibility-control',
            type: CallSignalType.offer,
            media: const CallMedia(audio: true),
            posture: CallPosture.direct,
            transport: const CallTransportProposal(CallTransportKind.relay),
            mediaKey: generateCallMediaKeyContribution(),
          ),
        );
        await tester.idle();
        expect(queries, greaterThan(0));
        if (lateQuery) {
          expect(alerts.posts, isEmpty);
          await service.hangup();
          query.complete();
          await tester.idle();
          expect(
            alerts.posts,
            isEmpty,
            reason: 'an old window query cannot revive an ended call',
          );
        } else {
          expect(
            alerts.posts,
            hasLength(1),
            reason: 'a visible unfocused window is still background',
          );
          focused = true;
          // Real window events, not a Flutter lifecycle transition or UI frame.
          for (final listener in windowManager.listeners.toList()) {
            listener.onWindowEvent('focus');
          }
          await tester.idle();
          expect(alerts.cancelled, contains(kNotificationIdIncomingCall));
          expect(alerts.posts, hasLength(1));
          await service.hangup();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.idle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
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

class _Settings extends NotificationSettingsController {
  @override
  NotificationSettings build() => NotificationSettings.defaults;
}

class _Alerts extends NotificationService {
  @override
  bool get isReady => true;
  @override
  Future<bool> waitUntilReady() async => true;

  final posts = <({int id, String title, String body, String? payload})>[];
  final cancelled = <int>[];
  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? replyLabel,
    String? replyHint,
  }) async {
    posts.add((id: id, title: title, body: body, payload: payload));
    return true;
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}
