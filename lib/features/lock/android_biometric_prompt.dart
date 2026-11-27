import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Offer authentication once when a lock screen becomes visible on Android.
/// A background lock can mount its screen before the activity returns.
class AndroidBiometricPrompt extends StatefulWidget {
  const AndroidBiometricPrompt({
    super.key,
    required this.enabled,
    required this.authenticate,
    required this.child,
  });

  final bool enabled;
  final VoidCallback authenticate;
  final Widget child;

  @override
  State<AndroidBiometricPrompt> createState() => _AndroidBiometricPromptState();
}

class _AndroidBiometricPromptState extends State<AndroidBiometricPrompt>
    with WidgetsBindingObserver {
  bool _attempted = false;
  late final bool _android = defaultTargetPlatform == TargetPlatform.android;

  bool get _ready =>
      _android &&
      !_attempted &&
      widget.enabled &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    if (_android) WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didUpdateWidget(AndroidBiometricPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _schedule();
  }

  void _schedule() {
    if (!_ready) return;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      if (!mounted || !_ready) return;
      _attempted = true;
      widget.authenticate();
    });
    binding.ensureVisualUpdate();
  }

  @override
  void dispose() {
    if (_android) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
