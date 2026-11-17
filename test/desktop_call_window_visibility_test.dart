import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/diagnostic_journal.dart';
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
  for (final hiddenEvent in ['hide', 'minimize']) {
    for (final pending in [false, true]) {
      for (final ended in [false, if (pending) true]) {
        testWidgets(
          'Windows native hidden fallback $hiddenEvent pending=$pending ended=$ended',
          (tester) async {
            await _checkHiddenFallback(
              tester,
              hiddenEvent: hiddenEvent,
              pending: pending,
              ended: ended,
              expectedPosts: ended ? 0 : 1,
            );
          },
          variant: TargetPlatformVariant.only(TargetPlatform.windows),
        );
      }
    }
  }
  for (final clearingEvent in ['show', 'restore', 'focus']) {
    testWidgets(
      'Windows native hidden fallback is cleared by $clearingEvent',
      (tester) async {
        await _checkHiddenFallback(
          tester,
          hiddenEvent: 'hide',
          clearingEvent: clearingEvent,
          expectedPosts: 0,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
  testWidgets(
    'Windows native hidden fallback needs hidden evidence',
    (tester) async {
      await _checkHiddenFallback(tester, expectedPosts: 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
  testWidgets(
    'Windows native foreground observation supersedes hidden evidence',
    (tester) async {
      await _checkHiddenFallback(
        tester,
        hiddenEvent: 'hide',
        observeForeground: true,
        expectedPosts: 0,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
  for (final queryMethod in ['isVisible', 'isFocused']) {
    for (final background in [false, true]) {
      for (final ended in [false, true]) {
        for (final lateBackground in [false, if (!background && !ended) true]) {
          testWidgets(
            'pending Windows $queryMethod uses lifecycle background=$background ended=$ended lateBackground=$lateBackground',
            (tester) async {
              diagnosticJournal.clear();
              addTearDown(diagnosticJournal.clear);
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
              final query = Completer<bool>();
              var entered = false;
              var focusQueries = 0;
              const window = MethodChannel('window_manager');
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                window,
                (call) async {
                  if (call.method == 'isFocused') focusQueries++;
                  if (call.method == queryMethod) {
                    entered = true;
                    return query.future;
                  }
                  if (call.method == 'isVisible' ||
                      call.method == 'isFocused') {
                    return true;
                  }
                  if (call.method == 'show' || call.method == 'focus') {
                    fail('incoming call handling must not take window focus');
                  }
                  return null;
                },
              );
              addTearDown(() {
                tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                  window,
                  null,
                );
                if (!query.isCompleted) query.complete(true);
                tester.binding.handleAppLifecycleStateChanged(
                  AppLifecycleState.resumed,
                );
              });
              await tester.pumpWidget(
                UncontrolledProviderScope(
                  container: container,
                  child: const MaterialApp(home: CallLifecycleBridge()),
                ),
              );
              tester.binding.handleAppLifecycleStateChanged(
                background
                    ? AppLifecycleState.paused
                    : AppLifecycleState.resumed,
              );
              wire.onCallSignal!(
                NodeId.fromHex('a' * 64),
                CallSignal(
                  callId: 'pending-chrome-observation',
                  type: CallSignalType.offer,
                  media: const CallMedia(audio: true),
                  posture: CallPosture.direct,
                  transport: const CallTransportProposal(
                    CallTransportKind.relay,
                  ),
                  mediaKey: generateCallMediaKeyContribution(),
                ),
              );
              await tester.idle();
              expect(service.current?.status, CallStatus.ringing);
              expect(entered, isTrue);
              expect(alerts.posts, isEmpty);
              if (ended) await service.hangup();
              // Deterministic virtual-clock watchdog check. The platform future
              // remains pending throughout; no measured network/OS latency.
              await tester.pump(const Duration(seconds: 1));
              expect(alerts.posts, hasLength(background && !ended ? 1 : 0));
              if (!ended) expect(service.current?.status, CallStatus.ringing);
              if (background && !ended) {
                query.completeError(
                  PlatformException(code: 'PRIVATE_WINDOW_ERROR_CANARY'),
                );
              } else {
                query.complete(!lateBackground);
              }
              await tester.idle();
              expect(
                alerts.posts,
                hasLength((background && !ended) || lateBackground ? 1 : 0),
              );
              if (queryMethod == 'isVisible' && ended) {
                expect(
                  focusQueries,
                  0,
                  reason: 'retired visibility must not issue a focus query',
                );
              }
              if (kDiagnosticReportEnabled) {
                final report = diagnosticJournal.toJson();
                final evidence = report['last_evidence'] as Map;
                expect(evidence.containsKey('callAlertWindowQuery'), !ended);
                if (!ended) {
                  expect((evidence['callAlertWindowQuery'] as Map)['values'], {
                    'code': background ? 2 : 0,
                    'background': background || lateBackground ? 1 : 0,
                    'success': background ? 0 : 1,
                  });
                }
                expect(
                  jsonEncode(report),
                  isNot(contains('PRIVATE_WINDOW_ERROR_CANARY')),
                );
              }
              if (!ended) await service.hangup();
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.idle();
            },
            variant: TargetPlatformVariant.only(TargetPlatform.windows),
          );
        }
      }
    }
  }
}

Future<void> _windowEvent(WidgetTester tester, String name) async {
  final reply = Completer<void>();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'window_manager',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('onEvent', {'eventName': name}),
    ),
    (data) {
      try {
        const StandardMethodCodec().decodeEnvelope(data!);
        reply.complete();
      } catch (error, stack) {
        reply.completeError(error, stack);
      }
    },
  );
  await reply.future;
  await tester.idle();
}

Future<void> _checkHiddenFallback(
  WidgetTester tester, {
  String? hiddenEvent,
  String? clearingEvent,
  bool pending = false,
  bool ended = false,
  bool observeForeground = false,
  required int expectedPosts,
}) async {
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
  final query = Completer<bool>();
  var foreground = observeForeground;
  var queries = 0;
  const window = MethodChannel('window_manager');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(window, (
    call,
  ) async {
    if (call.method == 'isVisible' || call.method == 'isFocused') {
      queries++;
      if (foreground) return true;
      if (pending) return query.future;
      throw PlatformException(code: 'window_query_unavailable');
    }
    fail(
      'notification handling must not control a native window: ${call.method}',
    );
  });
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      window,
      null,
    );
    if (!query.isCompleted) query.complete(true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: CallLifecycleBridge()),
    ),
  );
  if (hiddenEvent != null) await _windowEvent(tester, hiddenEvent);
  if (clearingEvent != null) await _windowEvent(tester, clearingEvent);
  expect(tester.binding.lifecycleState, AppLifecycleState.resumed);
  wire.onCallSignal!(
    NodeId.fromHex('a' * 64),
    CallSignal(
      callId: 'native-hidden-window',
      type: CallSignalType.offer,
      media: const CallMedia(audio: true),
      posture: CallPosture.direct,
      transport: const CallTransportProposal(CallTransportKind.relay),
      mediaKey: generateCallMediaKeyContribution(),
    ),
  );
  await tester.idle();
  expect(service.current?.status, CallStatus.ringing);
  expect(queries, greaterThan(0));
  if (observeForeground) {
    expect(alerts.posts, isEmpty);
    foreground = false;
    await _windowEvent(tester, 'resized');
  }
  if (pending) {
    expect(alerts.posts, isEmpty);
    if (ended) await service.hangup();
    // The actual production watchdog, advanced with virtual time only.
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(alerts.posts, hasLength(expectedPosts));
  if (!ended) await service.hangup();
  await tester.idle();
  if (expectedPosts != 0) {
    expect(alerts.cancelled, contains(kNotificationIdIncomingCall));
  }
  // Even a late successful foreground result cannot revive a retired alert.
  if (pending) {
    query.complete(true);
    await tester.idle();
    expect(alerts.posts, hasLength(expectedPosts));
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.idle();
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
