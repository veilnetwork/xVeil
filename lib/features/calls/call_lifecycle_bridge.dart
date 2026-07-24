import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilBackground;

import '../../core/log.dart';
import '../../domain/call.dart';
import '../../domain/group_call.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/router.dart' show rootNavigatorKey;
import '../../state/background_node_controller.dart';
import '../../state/call_service.dart';
import '../../state/group_call_service.dart';
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
  bool _ownsForegroundService = false;
  bool _videoCallActive = false;
  bool _batteryPromptChecked = false;

  static const _kBatteryPromptKey = 'call_battery_prompted';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _actions.setMethodCallHandler(_handleNativeCallAction);
    _pipEvents.setMethodCallHandler(_handlePipEvent);
    unawaited(_consumeInitialAction());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ringTimer?.cancel();
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
  Widget build(BuildContext context) {
    final call = ref.watch(currentCallProvider);
    final groupCall = ref.watch(currentGroupCallProvider).value;
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
    return const SizedBox.shrink();
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
      await _applyCallAction(call.arguments as String?);
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
      final action = await _actions.invokeMethod<String>(
        'consumeInitialAction',
      );
      await _applyCallAction(action);
    } catch (_) {
      // Older Android builds simply won't expose this channel.
    }
  }

  Future<void> _applyCallAction(String? action) async {
    final svc = ref.read(callServiceProvider);
    // The notification's buttons belong to whichever call is actually live:
    // the 1:1 FSM when it holds a call, else the group room (its foreground
    // service reuses the same action channel).
    final groupSvc = ref.read(groupCallServiceProvider);
    final direct = svc.current;
    switch (action) {
      case 'accept':
        if (direct != null && direct.isLive) {
          await svc.accept();
        } else if (groupSvc?.current?.isLive ?? false) {
          await groupSvc!.join();
        }
      case 'hangup':
        if (direct != null && direct.isLive) {
          await svc.hangup();
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
    final key = directLive
        ? 'direct:${call.callId}:${call.status.name}:${call.peer.short}:'
              '${directCapture && call.micOn}:${directCapture && call.cameraOn}'
        : groupLive
        ? 'group:${groupCall.callId}:${groupCall.status.name}:'
              '${groupCapture && groupCall.micOn}:'
              '${groupCapture && groupCall.cameraOn}'
        : 'none';
    if (key == _lastServiceKey) return;
    _lastServiceKey = key;
    unawaited(_applyForegroundService(call, groupCall));
  }

  Future<void> _applyForegroundService(Call? call, GroupCall? groupCall) async {
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
    if (directLive) {
      final title = switch (call.status) {
        CallStatus.ringing when call.isIncoming => 'Incoming xVeil call',
        CallStatus.dialing => 'Calling with xVeil',
        _ => 'xVeil call in progress',
      };
      await VeilBackground.start(
        title: title,
        text: call.peer.short,
        hangupAction: true,
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
      return;
    }
    // A live GROUP room needs the same call-grade (microphone|camera)
    // foreground service: without it a backgrounded group call loses mic
    // capture and the process itself to the OS while the 1:1 path survives.
    final ringing = groupCall!.status == GroupCallStatus.ringing;
    await VeilBackground.start(
      title: ringing ? 'Incoming xVeil group call' : 'xVeil group call',
      text: groupCall.groupId.short,
      hangupAction: true,
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
