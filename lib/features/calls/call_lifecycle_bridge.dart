import 'dart:async';
import 'dart:ui' show PlatformDispatcher;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilBackground;

import '../../core/log.dart';
import '../../core/ids.dart';
import '../../data/storage/storage.dart';
import '../../domain/call.dart';
import '../../domain/group_call.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/router.dart' show rootNavigatorKey;
import '../../state/background_node_controller.dart';
import '../../state/call_service.dart';
import '../../state/call_screen_caller.dart';
import '../../state/call_notification_session.dart';
import '../../state/group_call_service.dart';
import '../../state/locale_controller.dart';
import '../../state/providers.dart';

final callPipMode = ValueNotifier<bool>(false);

class CallLifecycleBridge extends ConsumerStatefulWidget {
  const CallLifecycleBridge({super.key});

  @override
  ConsumerState<CallLifecycleBridge> createState() =>
      _CallLifecycleBridgeState();
}

class _CallLifecycleBridgeState extends ConsumerState<CallLifecycleBridge>
    with WidgetsBindingObserver {
  static const _pip = MethodChannel('xveil/pip');
  static const _pipEvents = MethodChannel('xveil/pip_events');
  static const _actions = MethodChannel('xveil/call_actions');

  Timer? _ringTimer;
  String? _lastServiceKey;
  String? _callerPresentationSession;
  bool _ownsForegroundService = false;
  bool _videoCallActive = false;
  bool _batteryPromptChecked = false;
  final _notificationSession = CallNotificationSession();
  StreamSubscription<Call?>? _directChanges;
  StreamSubscription<GroupCall?>? _groupChanges;

  static const _kBatteryPromptKey = 'call_battery_prompted';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _actions.setMethodCallHandler(_handleNativeCallAction);
    _pipEvents.setMethodCallHandler(_handlePipEvent);
    // Flutter can defer frames while the activity is in the background. Call
    // notifications and ringing must follow backend events, not widget builds.
    ref.listenManual(callServiceProvider, (_, service) {
      unawaited(_directChanges?.cancel());
      _directChanges = service.changes.listen((_) => _syncCallState());
      _syncCallState();
    }, fireImmediately: true);
    ref.listenManual(groupCallServiceProvider, (_, service) {
      unawaited(_groupChanges?.cancel());
      _groupChanges = service?.changes.listen((_) => _syncCallState());
      _syncCallState();
    }, fireImmediately: true);
    unawaited(_consumeInitialAction());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ringTimer?.cancel();
    _notificationSession.clear();
    unawaited(_directChanges?.cancel());
    unawaited(_groupChanges?.cancel());
    _actions.setMethodCallHandler(null);
    _pipEvents.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_videoCallActive) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_enterPip());
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  void _syncCallState() {
    if (!mounted) return;
    final call = ref.read(callServiceProvider).current;
    final groupCall = ref.read(groupCallServiceProvider)?.current;
    final wasVideoCallActive = _videoCallActive;
    _videoCallActive =
        _isVideoCallActive(call) || _isGroupVideoCallActive(groupCall);
    if (wasVideoCallActive != _videoCallActive) {
      // Arm the platform's own PiP transition (autoEnter on Android 12+,
      // onUserLeaveHint before that). The paused-lifecycle _enterPip below is
      // too late for the platform to honor — with nothing armed, backgrounding
      // a video call keeps the camera paused and the peer sees a frozen frame.
      unawaited(_setPipAuto(_videoCallActive));
      // A PiP window that outlives its video call must be dismissed, or it
      // keeps floating over the launcher showing the shrunk app UI (user-
      // observed: the chats screen crammed into the tiny window).
      if (!_videoCallActive && callPipMode.value) unawaited(_exitPip());
    }
    _syncRinger(call);
    _syncForegroundService(call, groupCall);
    // First time a call actually connects, offer the battery-optimization
    // exemption once: aggressive OEMs (MIUI et al.) kill a backgrounded call
    // even with the foreground service unless the app is whitelisted, which is
    // exactly when the user just discovered they want calls to survive.
    final connected =
        (call != null &&
            (call.status == CallStatus.connecting ||
                call.status == CallStatus.active)) ||
        (groupCall != null &&
            (groupCall.status == GroupCallStatus.connecting ||
                groupCall.status == GroupCallStatus.active));
    if (connected) unawaited(_maybeOfferBatteryExemption());
  }

  Future<void> _maybeOfferBatteryExemption() async {
    if (_batteryPromptChecked || !Platform.isAndroid) return;
    _batteryPromptChecked = true; // once per app run regardless of outcome
    try {
      final prefs = await ref.read(prefsProvider.future);
      if (prefs.getBool(_kBatteryPromptKey) ?? false) return;
      if (await VeilBackground.isIgnoringBatteryOptimizations()) {
        await prefs.setBool(_kBatteryPromptKey, true);
        return;
      }
      // Resolve the navigator AFTER the last await so the context never
      // crosses an async gap (the pref write is done above).
      if ((rootNavigatorKey.currentState?.context.mounted ?? false) == false) {
        _batteryPromptChecked = false; // navigator not ready — retry next call
        return;
      }
      await prefs.setBool(_kBatteryPromptKey, true);
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final l = AppL10n.of(ctx);
      await showDialog<void>(
        context: ctx,
        builder: (dialogCtx) => AlertDialog(
          title: Text(l.callBatteryAllowTitle),
          content: Text(l.callBatteryAllowBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(l.networkBackgroundLater),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogCtx);
                VeilBackground.requestIgnoreBatteryOptimizations();
              },
              child: Text(l.networkBackgroundAllowGrant),
            ),
          ],
        ),
      );
    } catch (_) {
      // Prefs closed / no navigator — never let the prompt break a call.
    }
  }

  Future<void> _exitPip() async {
    if (!Platform.isAndroid) return;
    try {
      final ok = await _pip.invokeMethod<bool>('exit');
      devLog(() => 'xVeil[call-pip]: exit ok=$ok');
    } catch (e) {
      devLog(() => 'xVeil[call-pip]: exit failed: $e');
    }
  }

  Future<void> _setPipAuto(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      final ok = await _pip.invokeMethod<bool>('setAuto', {
        'enabled': enabled,
        'width': 16,
        'height': 9,
      });
      devLog(() => 'xVeil[call-pip]: setAuto enabled=$enabled ok=$ok');
    } catch (e) {
      // PiP is best-effort and depends on Android/API/device policy.
      devLog(() => 'xVeil[call-pip]: setAuto enabled=$enabled failed: $e');
    }
  }

  Future<void> _handleNativeCallAction(MethodCall call) async {
    if (call.method == 'callAction') {
      await _applyCallAction(call.arguments);
    }
  }

  Future<void> _handlePipEvent(MethodCall call) async {
    if (call.method == 'pipChanged') {
      callPipMode.value = call.arguments == true;
    }
  }

  Future<void> _consumeInitialAction() async {
    if (!Platform.isAndroid) return;
    try {
      final action = await _actions.invokeMethod<Object?>(
        'consumeInitialAction',
      );
      await _applyCallAction(action);
    } catch (_) {
      // Older Android builds simply won't expose this channel.
    }
  }

  Future<void> _applyCallAction(Object? payload) async {
    if (!mounted) return;
    final svc = ref.read(callServiceProvider);
    // Native authentication is not enough: a consumed button can wait in the
    // channel while its call ends. Match its local session against the exact
    // live call, including the controller that owns the identity/group room.
    final groupSvc = ref.read(groupCallServiceProvider);
    final direct = svc.current;
    final group = groupSvc?.current;
    final action = direct != null && direct.isLive
        ? _notificationSession.actionFor(
            payload,
            owner: svc,
            callId: direct.callId,
            startedAt: direct.startedAt,
          )
        : group != null && group.isLive
        ? _notificationSession.actionFor(
            payload,
            owner: groupSvc!,
            callId: group.callId,
            startedAt: group.startedAt,
          )
        : null;
    switch (action) {
      case 'accept':
        if (direct != null && direct.isLive) {
          await svc.accept();
        } else if (groupSvc?.current?.isLive ?? false) {
          await groupSvc!.join();
        }
      case 'hangup':
        if (direct != null && direct.isLive) {
          await svc.hangup(origin: CallEndOrigin.androidNotification);
        } else if (groupSvc?.current?.isLive ?? false) {
          await groupSvc!.leave();
        }
    }
  }

  void _syncRinger(Call? call) {
    final shouldRing =
        call != null && call.isIncoming && call.status == CallStatus.ringing;
    if (!shouldRing) {
      _ringTimer?.cancel();
      _ringTimer = null;
      return;
    }
    if (_ringTimer != null) return;
    SystemSound.play(SystemSoundType.alert);
    _ringTimer = Timer.periodic(const Duration(milliseconds: 1400), (_) {
      SystemSound.play(SystemSoundType.alert);
    });
  }

  void _syncForegroundService(Call? call, GroupCall? groupCall) {
    final directLive = call != null && call.status != CallStatus.ended;
    final groupLive = groupCall != null && groupCall.isLive;
    final directCapture =
        directLive &&
        (call.status == CallStatus.connecting ||
            call.status == CallStatus.active);
    final groupCapture =
        groupLive &&
        (groupCall.status == GroupCallStatus.connecting ||
            groupCall.status == GroupCallStatus.active);
    final owner = directLive
        ? ref.read(callServiceProvider)
        : groupLive
        ? ref.read(groupCallServiceProvider)
        : null;
    final session = owner == null
        ? null
        : _notificationSession.bind(
            owner,
            directLive ? call.callId : groupCall!.callId,
            directLive ? call.startedAt : groupCall!.startedAt,
          );
    if (session == null) {
      _notificationSession.clear();
      _callerPresentationSession = null;
    }
    final key = directLive
        ? 'direct:$session:${call.status.name}:${call.mediaIdentity.short}:'
              '${directCapture && call.micOn}:${directCapture && call.cameraOn}'
        : groupLive
        ? 'group:$session:${groupCall.callId}:${groupCall.status.name}:'
              '${groupCapture && groupCall.micOn}:'
              '${groupCapture && groupCall.cameraOn}'
        : 'none';
    if (key == _lastServiceKey) return;
    _lastServiceKey = key;
    unawaited(_applyForegroundService(call, groupCall, session));
  }

  Future<void> _applyForegroundService(
    Call? call,
    GroupCall? groupCall,
    String? session,
  ) async {
    if (!Platform.isAndroid) return;
    final directLive = call != null && call.status != CallStatus.ended;
    final groupLive = groupCall != null && groupCall.isLive;
    if (!directLive && !groupLive) {
      if (!_ownsForegroundService) return;
      _ownsForegroundService = false;
      if (ref.read(backgroundNodeProvider)) {
        await VeilBackground.start();
      } else {
        await VeilBackground.stop();
      }
      return;
    }
    _ownsForegroundService = true;
    final storage = ref.read(storageProvider);
    final directOwner = ref.read(callServiceProvider);
    final groupOwner = ref.read(groupCallServiceProvider);
    if (directLive) {
      // The OS shows this in the notification shade, so it has to be in the
      // user's language — it was English in every build. There is no
      // Localizations in scope here (this is a listener, not a widget), so it
      // resolves the same way the desktop tray does: the chosen locale, or the
      // system one when the choice is "follow the system".
      final l = l10nFor(
        ref.read(localeProvider) ?? PlatformDispatcher.instance.locale,
      );
      final title = switch (call.status) {
        CallStatus.ringing when call.isIncoming => l.callNotificationIncoming,
        CallStatus.dialing => l.callNotificationDialing,
        _ => l.callNotificationActive,
      };
      await VeilBackground.start(
        title: title,
        text: call.mediaIdentity.short,
        hangupAction: true,
        callSession: session,
        ringing: call.isIncoming && call.status == CallStatus.ringing,
        microphone:
            (call.status == CallStatus.connecting ||
                call.status == CallStatus.active) &&
            call.micOn,
        camera:
            (call.status == CallStatus.connecting ||
                call.status == CallStatus.active) &&
            call.cameraOn &&
            call.media.video &&
            !call.media.screen,
      );
      if (session != null && _callerPresentationSession != session) {
        _callerPresentationSession = session;
        unawaited(
          _publishCaller(
            storage,
            call.mediaIdentity,
            session,
            () =>
                identical(ref.read(callServiceProvider), directOwner) &&
                directOwner.current?.isLive == true &&
                directOwner.current?.callId == call.callId &&
                directOwner.current?.startedAt == call.startedAt,
          ),
        );
      }
      return;
    }
    // A live GROUP room needs the same call-grade (microphone|camera)
    // foreground service: without it a backgrounded group call loses mic
    // capture and the process itself to the OS while the 1:1 path survives.
    final ringing = groupCall!.status == GroupCallStatus.ringing;
    final groupL = l10nFor(
      ref.read(localeProvider) ?? PlatformDispatcher.instance.locale,
    );
    await VeilBackground.start(
      title: ringing
          ? groupL.callNotificationGroupIncoming
          : groupL.callNotificationGroup,
      text: groupCall.groupId.short,
      hangupAction: true,
      callSession: session,
      ringing: ringing,
      microphone:
          (groupCall.status == GroupCallStatus.connecting ||
              groupCall.status == GroupCallStatus.active) &&
          groupCall.micOn,
      camera:
          (groupCall.status == GroupCallStatus.connecting ||
              groupCall.status == GroupCallStatus.active) &&
          groupCall.cameraOn &&
          groupCall.media.video &&
          !groupCall.media.screen,
    );
    if (session != null && _callerPresentationSession != session) {
      _callerPresentationSession = session;
      unawaited(
        _publishCaller(
          storage,
          groupCall.initiator,
          session,
          () =>
              identical(ref.read(groupCallServiceProvider), groupOwner) &&
              groupOwner?.current?.isLive == true &&
              groupOwner?.current?.callId == groupCall.callId &&
              groupOwner?.current?.startedAt == groupCall.startedAt,
        ),
      );
    }
  }

  Future<void> _publishCaller(
    Storage storage,
    NodeId peer,
    String session,
    bool Function() stillCurrent,
  ) async {
    bool ours() =>
        mounted &&
        identical(ref.read(storageProvider), storage) &&
        stillCurrent();
    try {
      if (!ours()) return;
      final caller = await loadCallScreenCaller(storage, peer);
      if (!ours()) return;
      await VeilBackground.setCallPresentation(
        callSession: session,
        callerName: caller.label,
        avatar: caller.avatar,
      );
    } catch (_) {
      // A closed/unreadable identity keeps the already shown fallback. Caller
      // data is never added to diagnostics or plaintext preferences.
    }
  }

  Future<void> _enterPip() async {
    if (!Platform.isAndroid) return;
    try {
      await _pip.invokeMethod<bool>('enter', {'width': 16, 'height': 9});
    } catch (_) {
      // PiP is best-effort and depends on Android/API/device policy.
    }
  }

  static bool _isVideoCallActive(Call? call) {
    if (call == null || !(call.media.video || call.media.screen)) return false;
    return call.status == CallStatus.connecting ||
        call.status == CallStatus.active;
  }

  /// Group twin of [_isVideoCallActive]: a JOINED room carrying video —
  /// connecting/active only, a ringing invite must not arm PiP.
  static bool _isGroupVideoCallActive(GroupCall? call) {
    if (call == null || !(call.media.video || call.media.screen)) return false;
    return call.status == GroupCallStatus.connecting ||
        call.status == GroupCallStatus.active;
  }
}
