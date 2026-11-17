import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xveil/desktop/desktop_tray.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/close_to_tray_controller.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/features/calls/call_lifecycle_bridge.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/group_call_service.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/notifications.dart';

import 'support/queued_clear_notification_plugin.dart';

class _DesktopAlerts extends NotificationService {
  final visible = <int, ({String title, String body, String? payload})>{};
  Completer<void>? showGate;
  Completer<void>? showEntered;
  Completer<void>? readyGate;
  Completer<void>? readyEntered;
  int showCalls = 0;
  int refusedPosts = 0;
  bool throwPostFailure = false;
  bool backendReady = true;
  int readyCalls = 0;

  @override
  bool get isReady => backendReady;

  @override
  Future<bool> waitUntilReady() async {
    readyCalls++;
    if (readyEntered?.isCompleted == false) readyEntered!.complete();
    await readyGate?.future;
    return backendReady;
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
    if (refusedPosts > 0) {
      refusedPosts--;
      if (throwPostFailure) throw StateError('synthetic post refusal');
      return false;
    }
    visible[id] = (title: title, body: body, payload: payload);
    return true;
  }

  @override
  Future<void> cancel(int id) async => visible.remove(id);
}

class _CallerStorage implements Storage {
  _CallerStorage([this.name]);
  final String? name;
  @override
  Future<Contact?> getContact(NodeId peer) async =>
      Contact(nodeId: peer, name: name);
  @override
  Future<String?> getSetting(String key) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedCallerStorage extends _CallerStorage {
  _GatedCallerStorage({this.holdContact = false, this.holdAvatar = false})
    : super('Local caller');
  final bool holdContact, holdAvatar;
  final contactGate = Completer<void>();
  final avatarGate = Completer<void>();
  int contactReads = 0, avatarReads = 0;
  @override
  Future<Contact?> getContact(NodeId peer) async {
    contactReads++;
    if (holdContact && peer == NodeId.fromHex('a' * 64)) {
      await contactGate.future;
    }
    return Contact(
      nodeId: peer,
      name: peer == NodeId.fromHex('a' * 64) ? 'Local caller' : 'Second caller',
    );
  }

  @override
  Future<String?> getSetting(String key) async {
    avatarReads++;
    if (holdAvatar) await avatarGate.future;
    return null;
  }

  void release() {
    if (!contactGate.isCompleted) contactGate.complete();
    if (!avatarGate.isCompleted) avatarGate.complete();
  }
}

class _CallAlertSettings extends NotificationSettingsController {
  _CallAlertSettings([this.initial = NotificationSettings.defaults]);
  final NotificationSettings initial;
  @override
  NotificationSettings build() => initial;
  void replace(NotificationSettings next) => state = next;
}

class _TrayApp extends AppController {
  @override
  AppState build() => const AppState(AppPhase.ready);
}

class _HideToTray extends CloseToTrayController {
  @override
  bool build() => true;
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
    NotificationService alerts, {
    NotificationSettings settings = NotificationSettings.defaults,
    GroupCallService? group,
    bool withTray = false,
    String? callerName,
    Storage? callerStorage,
  }) async {
    final wire = _Wire();
    final service = CallService(wire, media: _Media())..start();
    final source = StateProvider<CallService>((_) => service);
    final container = ProviderContainer(
      overrides: [
        callServiceProvider.overrideWith((ref) => ref.watch(source)),
        groupCallServiceProvider.overrideWithValue(group),
        notificationServiceProvider.overrideWithValue(alerts),
        storageProvider.overrideWithValue(
          callerStorage ?? _CallerStorage(callerName),
        ),
        if (withTray) ...[
          appControllerProvider.overrideWith(_TrayApp.new),
          closeToTrayProvider.overrideWith(_HideToTray.new),
          conversationsProvider.overrideWith((ref) => Stream.value([])),
        ],
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
        child: withTray
            ? const DesktopTrayHost(
                child: MaterialApp(home: CallLifecycleBridge()),
              )
            : const MaterialApp(home: CallLifecycleBridge()),
      ),
    );
    return (service: service, wire: wire, container: container, source: source);
  }

  void readOnlyWindows(WidgetTester tester) {
    const channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'isVisible' || call.method == 'isFocused') {
        return false;
      }
      if (call.method == 'show' || call.method == 'focus') {
        fail('metadata must not activate a window');
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }

  for (final endsWhileClearing in [false, true]) {
    testWidgets(
      'queued global clear cannot erase a fresh call, ended=$endsWhileClearing',
      (tester) async {
        readOnlyWindows(tester);
        final plugin = QueuedClearNotificationPlugin()..holdFirstClear = true;
        final alerts = NotificationService(plugin: plugin);
        await alerts.init(onTap: (_) {});
        final storage = _GatedCallerStorage(holdContact: true);
        final f = await mountDesktop(
          tester,
          alerts,
          callerStorage: storage,
          settings: const NotificationSettings(
            enabled: true,
            preview: NotificationPreview.full,
          ),
        );
        f.wire.onCallSignal!(
          NodeId.fromHex('a' * 64),
          _desktopOffer('clear-admission'),
        );
        await tester.idle();
        expect(f.service.current?.status, CallStatus.ringing);
        expect(
          storage.contactReads,
          1,
          reason:
              'the actual bridge has passed readiness and is awaiting the label',
        );
        expect(plugin.posts, 0);
        final first = alerts.cancelAll();
        await tester.idle();
        expect(plugin.firstClearEntered.isCompleted, isTrue);
        final second = alerts.cancelAll();
        late int postsWhileClearing;
        try {
          storage.release();
          await tester.idle();
          postsWhileClearing = plugin.posts;
          if (endsWhileClearing) {
            await f.service.hangup();
            await tester.idle();
          }
        } finally {
          plugin.release();
          storage.release();
          await Future.wait([first, second]);
          await tester.idle();
        }
        expect(postsWhileClearing, 0);
        expect(
          plugin.visible,
          endsWhileClearing
              ? <int, String?>{}
              : {kNotificationIdIncomingCall: kNotificationPayloadIncomingCall},
        );
        expect(plugin.posts, endsWhileClearing ? 0 : 1);
        await f.service.hangup();
        await tester.idle();
        expect(plugin.visible, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.idle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    'caller metadata does not wait for an unused avatar',
    (tester) async {
      readOnlyWindows(tester);
      final storage = _GatedCallerStorage(holdAvatar: true);
      final alerts = _DesktopAlerts();
      final f = await mountDesktop(
        tester,
        alerts,
        callerStorage: storage,
        settings: NotificationSettings.defaults.copyWith(
          preview: NotificationPreview.full,
        ),
      );
      try {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        f.wire.onCallSignal!(
          NodeId.fromHex('a' * 64),
          _desktopOffer('avatar-blocked-call'),
        );
        await tester.idle();
        expect(alerts.visible, hasLength(1));
        expect(alerts.visible.values.single.body, 'Local caller');
        expect(
          storage.avatarReads,
          0,
          reason: 'text-only desktop alert never uses the image',
        );
      } finally {
        storage.release();
        await f.service.hangup();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'caller metadata cannot suppress a ringing alert indefinitely',
    (tester) async {
      readOnlyWindows(tester);
      final storage = _GatedCallerStorage(holdContact: true);
      final alerts = _DesktopAlerts();
      final f = await mountDesktop(
        tester,
        alerts,
        callerStorage: storage,
        settings: NotificationSettings.defaults.copyWith(
          preview: NotificationPreview.full,
        ),
      );
      final peer = NodeId.fromHex('a' * 64);
      try {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        f.wire.onCallSignal!(peer, _desktopOffer('slow-contact-call'));
        await tester.idle();
        expect(storage.contactReads, 1);
        await tester.pump(const Duration(seconds: 1));
        await tester.idle();
        expect(alerts.visible, hasLength(1));
        expect(alerts.visible.values.single.body, peer.short);
        storage.release();
        await tester.idle();
        expect(
          alerts.showCalls,
          1,
          reason: 'late metadata does not post a second ringing banner',
        );
      } finally {
        storage.release();
        await f.service.hangup();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'caller metadata for an ended call cannot hold the next caller',
    (tester) async {
      readOnlyWindows(tester);
      final storage = _GatedCallerStorage(holdContact: true);
      final alerts = _DesktopAlerts();
      final f = await mountDesktop(
        tester,
        alerts,
        callerStorage: storage,
        settings: NotificationSettings.defaults.copyWith(
          preview: NotificationPreview.full,
        ),
      );
      try {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        f.wire.onCallSignal!(
          NodeId.fromHex('a' * 64),
          _desktopOffer('old-caller-lookup'),
        );
        await tester.idle();
        expect(storage.contactReads, 1);
        await f.service.hangup();
        f.wire.onCallSignal!(
          NodeId.fromHex('b' * 64),
          _desktopOffer('next-caller-lookup'),
        );
        await tester.idle();
        expect(alerts.visible, hasLength(1));
        expect(alerts.visible.values.single.body, 'Second caller');
        storage.release();
        await tester.idle();
        expect(alerts.showCalls, 1);
      } finally {
        storage.release();
        await f.service.hangup();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'caller metadata fallback is reused by post retries and late errors are observed',
    (tester) async {
      readOnlyWindows(tester);
      final storage = _GatedCallerStorage(holdContact: true);
      final alerts = _DesktopAlerts()..refusedPosts = 1;
      final f = await mountDesktop(
        tester,
        alerts,
        callerStorage: storage,
        settings: NotificationSettings.defaults.copyWith(
          preview: NotificationPreview.full,
        ),
      );
      final peer = NodeId.fromHex('a' * 64);
      try {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        f.wire.onCallSignal!(peer, _desktopOffer('retry-metadata'));
        await tester.idle();
        await tester.pump(const Duration(seconds: 1));
        await tester.idle();
        expect(alerts.showCalls, 1);
        expect(alerts.visible, isEmpty);
        expect(storage.contactReads, 1);
        await tester.pump(const Duration(seconds: 1));
        await tester.idle();
        expect(alerts.showCalls, 2);
        expect(alerts.visible.values.single.body, peer.short);
        expect(
          storage.contactReads,
          1,
          reason: 'retry must not add another blocked metadata read',
        );
        expect(storage.avatarReads, 0);
        storage.contactGate.completeError(
          StateError('synthetic late storage error'),
        );
        await tester.idle();
        expect(tester.takeException(), isNull);
        expect(alerts.showCalls, 2);
      } finally {
        storage.release();
        await f.service.hangup();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final retire in ['privacy', 'dispose']) {
    testWidgets(
      'caller metadata wait is cancelled by $retire',
      (tester) async {
        readOnlyWindows(tester);
        final storage = _GatedCallerStorage(holdContact: true);
        final alerts = _DesktopAlerts();
        final f = await mountDesktop(
          tester,
          alerts,
          callerStorage: storage,
          settings: NotificationSettings.defaults.copyWith(
            preview: NotificationPreview.full,
          ),
        );
        try {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          f.wire.onCallSignal!(
            NodeId.fromHex('a' * 64),
            _desktopOffer('retiring-metadata'),
          );
          await tester.idle();
          expect(storage.contactReads, 1);
          if (retire == 'privacy') {
            (f.container.read(notificationSettingsProvider.notifier)
                    as _CallAlertSettings)
                .replace(NotificationSettings.defaults);
            await tester.idle();
            expect(
              alerts.showCalls,
              1,
              reason:
                  'hidden policy must post without waiting for the old name read',
            );
            expect(alerts.visible.values.single.title, 'xVeil');
            expect(
              alerts.visible.values.single.body,
              isNot(contains('Local caller')),
            );
          } else {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.idle();
            expect(alerts.showCalls, 0);
          }
          await tester.pump(const Duration(seconds: 1));
          storage.release();
          await tester.idle();
          expect(alerts.showCalls, retire == 'privacy' ? 1 : 0);
          expect(tester.takeException(), isNull);
        } finally {
          storage.release();
          await f.service.hangup();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    'full call alert uses the local name without activating a window',
    (tester) async {
      final alerts = _DesktopAlerts();
      final f = await mountDesktop(
        tester,
        alerts,
        settings: NotificationSettings.defaults.copyWith(
          preview: NotificationPreview.full,
        ),
        callerName: 'Local caller',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      f.wire.onCallSignal!(
        NodeId.fromHex('a' * 64),
        _desktopOffer('named-caller'),
      );
      await tester.idle();
      expect(alerts.showCalls, 1);
      expect(alerts.visible.values.single.body, 'Local caller');
      await f.service.hangup();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final throws in [false, true]) {
    testWidgets(
      'background call retries a transient post failure throws=$throws',
      (tester) async {
        final alerts = _DesktopAlerts()
          ..refusedPosts = 1
          ..throwPostFailure = throws;
        final f = await mountDesktop(tester, alerts);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        f.wire.onCallSignal!(
          NodeId.fromHex('a' * 64),
          _desktopOffer('retry-call'),
        );
        await tester.idle();
        expect(alerts.showCalls, 1);
        expect(alerts.visible, isEmpty);
        // No second offer, lifecycle transition or service event is required.
        await tester.pump(const Duration(seconds: 1));
        await tester.idle();
        expect(alerts.showCalls, 2);
        expect(alerts.visible.length, 1);
        await f.service.hangup();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('persistent post failure exhausts its bounded retry budget', (
    tester,
  ) async {
    final alerts = _DesktopAlerts()..refusedPosts = 100;
    final f = await mountDesktop(tester, alerts);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    f.wire.onCallSignal!(
      NodeId.fromHex('a' * 64),
      _desktopOffer('bounded-call'),
    );
    await tester.idle();
    expect(alerts.showCalls, 1);
    for (final seconds in [1, 2, 4]) {
      (f.container.read(notificationSettingsProvider.notifier)
              as _CallAlertSettings)
          .replace(NotificationSettings.defaults.copyWith());
      await tester.idle();
      await tester.pump(Duration(seconds: seconds));
      await tester.idle();
    }
    expect(alerts.showCalls, 4);
    expect(alerts.visible, isEmpty);
    expect(f.service.current?.status, CallStatus.ringing);
    await tester.pump(const Duration(seconds: 8));
    await tester.idle();
    expect(alerts.showCalls, 4);
    await f.service.hangup();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final stop in [
    'hangup',
    'foreground',
    'disabled',
    'identity',
    'dispose',
  ]) {
    testWidgets('pending call alert retry is revoked by $stop', (tester) async {
      final alerts = _DesktopAlerts()..refusedPosts = 1;
      final f = await mountDesktop(tester, alerts);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      f.wire.onCallSignal!(
        NodeId.fromHex('a' * 64),
        _desktopOffer('revoked-retry-call'),
      );
      await tester.idle();
      expect(alerts.showCalls, 1);
      switch (stop) {
        case 'hangup':
          await f.service.hangup();
        case 'foreground':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        case 'disabled':
          (f.container.read(notificationSettingsProvider.notifier)
                  as _CallAlertSettings)
              .replace(NotificationSettings.defaults.copyWith(enabled: false));
        case 'identity':
          final other = CallService(_Wire(), media: _Media())..start();
          addTearDown(other.dispose);
          f.container.read(f.source.notifier).state = other;
        case 'dispose':
          await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.idle();
      await tester.pump(const Duration(seconds: 8));
      await tester.idle();
      expect(alerts.showCalls, 1);
      expect(alerts.visible, isEmpty);
      await f.service.hangup();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('old failed post retry cannot overwrite the next caller', (
    tester,
  ) async {
    final alerts = _DesktopAlerts()..refusedPosts = 1;
    final f = await mountDesktop(
      tester,
      alerts,
      settings: NotificationSettings.defaults.copyWith(
        preview: NotificationPreview.full,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    f.wire.onCallSignal!(
      NodeId.fromHex('a' * 64),
      _desktopOffer('old-failed-call'),
    );
    await tester.idle();
    await f.service.hangup();
    final peer = NodeId.fromHex('b' * 64);
    f.wire.onCallSignal!(peer, _desktopOffer('next-caller'));
    await tester.idle();
    expect(alerts.showCalls, 2);
    expect(alerts.visible.values.single.body, peer.short);
    await tester.pump(const Duration(seconds: 8));
    await tester.idle();
    expect(alerts.showCalls, 2);
    expect(alerts.visible.values.single.body, peer.short);
    await f.service.hangup();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('retry uses the current privacy policy', (tester) async {
    final alerts = _DesktopAlerts()..refusedPosts = 1;
    final f = await mountDesktop(
      tester,
      alerts,
      settings: NotificationSettings.defaults.copyWith(
        preview: NotificationPreview.full,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    final peer = NodeId.fromHex('a' * 64);
    f.wire.onCallSignal!(peer, _desktopOffer('privacy-retry-call'));
    await tester.idle();
    (f.container.read(notificationSettingsProvider.notifier)
            as _CallAlertSettings)
        .replace(NotificationSettings.defaults);
    await tester.idle();
    expect(alerts.visible.values.single.title, 'xVeil');
    expect(alerts.visible.values.single.body, isNot(contains(peer.short)));
    await tester.pump(const Duration(seconds: 8));
    await tester.idle();
    expect(alerts.showCalls, 2);
    expect(alerts.visible.values.single.title, 'xVeil');
    await f.service.hangup();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'an unready backend is not repeatedly initialized by a ringing call',
    (tester) async {
      final alerts = _DesktopAlerts()..backendReady = false;
      final f = await mountDesktop(tester, alerts);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      f.wire.onCallSignal!(
        NodeId.fromHex('a' * 64),
        _desktopOffer('unready-call'),
      );
      await tester.idle();
      await tester.pump(const Duration(seconds: 8));
      await tester.idle();
      expect(alerts.showCalls, 0);
      expect(alerts.readyCalls, 1);
      await f.service.hangup();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a late post failure cannot retry an ended call', (tester) async {
    final alerts = _DesktopAlerts()
      ..refusedPosts = 1
      ..showGate = Completer<void>()
      ..showEntered = Completer<void>();
    final f = await mountDesktop(tester, alerts);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    f.wire.onCallSignal!(
      NodeId.fromHex('a' * 64),
      _desktopOffer('slow-failed-call'),
    );
    await tester.idle();
    expect(alerts.showEntered!.isCompleted, isTrue);
    await tester.pump(const Duration(seconds: 6));
    expect(alerts.showCalls, 1);
    await f.service.hangup();
    alerts.showGate!.complete();
    await tester.idle();
    await tester.pump(const Duration(seconds: 8));
    await tester.idle();
    expect(alerts.showCalls, 1);
    expect(alerts.visible, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'close-to-tray preserves ringing backend without showing or focusing the window',
    (tester) async {
      final windowCalls = <String>[];
      const windowChannel = MethodChannel('window_manager');
      const trayChannel = MethodChannel('tray_manager');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        windowCalls.add(call.method);
        return call.method == 'isPreventClose' ? true : null;
      });
      messenger.setMockMethodCallHandler(trayChannel, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowChannel, null);
        messenger.setMockMethodCallHandler(trayChannel, null);
      });
      final alerts = _DesktopAlerts();
      final f = await mountDesktop(tester, alerts, withTray: true);
      await tester.idle();
      expect(windowManager.listeners, hasLength(1));
      windowManager.listeners.single.onWindowClose();
      await tester.idle();
      expect(windowCalls.where((m) => m == 'hide'), hasLength(1));
      expect(windowCalls, isNot(contains('destroy')));
      // The OS lifecycle transition is supplied explicitly; native Windows
      // window events and actual toast visibility are outside this fixture.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      f.wire.onCallSignal!(
        NodeId.fromHex('a' * 64),
        _desktopOffer('closed-window-call'),
      );
      await tester.idle();
      expect(f.service.current?.status, CallStatus.ringing);
      expect(alerts.visible.length, 1);
      expect(windowCalls, isNot(contains('show')));
      expect(windowCalls, isNot(contains('focus')));
      await f.service.hangup();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(windowManager.listeners, isEmpty);
    },
  );

  testWidgets('group call retries a transient post refusal', (tester) async {
    final alerts = _DesktopAlerts()..refusedPosts = 1;
    final group = _GroupAlerts();
    addTearDown(group.events.close);
    await mountDesktop(tester, alerts, group: group);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    group.emit(
      GroupCall(
        groupId: NodeId.fromHex('c' * 64),
        callId: 'group-retry',
        initiator: NodeId.fromHex('a' * 64),
        membershipEpoch: 1,
        media: const CallMedia(audio: true),
        status: GroupCallStatus.ringing,
        startedAt: DateTime.utc(2026),
        participants: const {},
      ),
    );
    await tester.idle();
    expect(alerts.showCalls, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.idle();
    expect(alerts.showCalls, 2);
    expect(alerts.visible.length, 1);
    group.emit(null);
    await tester.idle();
    expect(alerts.visible, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
        notificationServiceProvider.overrideWithValue(_DesktopAlerts()),
        notificationSettingsProvider.overrideWith(_CallAlertSettings.new),
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
          notificationServiceProvider.overrideWithValue(_DesktopAlerts()),
          notificationSettingsProvider.overrideWith(_CallAlertSettings.new),
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
