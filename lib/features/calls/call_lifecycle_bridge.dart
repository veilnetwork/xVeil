import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilBackground;

import '../../core/log.dart';
import '../../domain/call.dart';
import '../../state/background_node_controller.dart';
import '../../state/call_service.dart';

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
    final wasVideoCallActive = _videoCallActive;
    _videoCallActive = _isVideoCallActive(call);
    if (wasVideoCallActive != _videoCallActive) {
      // Arm the platform's own PiP transition (autoEnter on Android 12+,
      // onUserLeaveHint before that). The paused-lifecycle _enterPip below is
      // too late for the platform to honor — with nothing armed, backgrounding
      // a video call keeps the camera paused and the peer sees a frozen frame.
      unawaited(_setPipAuto(_videoCallActive));
    }
    _syncRinger(call);
    _syncForegroundService(call);
    return const SizedBox.shrink();
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
    switch (action) {
      case 'accept':
        await svc.accept();
      case 'hangup':
        await svc.hangup();
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

  void _syncForegroundService(Call? call) {
    final key = call == null || call.status == CallStatus.ended
        ? 'none'
        : '${call.callId}:${call.status.name}:${call.peer.short}';
    if (key == _lastServiceKey) return;
    _lastServiceKey = key;
    unawaited(_applyForegroundService(call));
  }

  Future<void> _applyForegroundService(Call? call) async {
    if (!Platform.isAndroid) return;
    if (call == null || call.status == CallStatus.ended) {
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
}
