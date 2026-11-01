import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';

/// Android 14+ full-screen access is independent of battery exemption and
/// notification permission. Refresh after returning from its system settings.
class CallScreenPermission extends StatefulWidget {
  const CallScreenPermission({super.key});
  @override
  State<CallScreenPermission> createState() => _CallScreenPermissionState();
}

class _CallScreenPermissionState extends State<CallScreenPermission>
    with WidgetsBindingObserver {
  static const channel = MethodChannel('xveil/call_screen');
  bool? allowed;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final value = await channel.invokeMethod<bool>('allowed');
      if (mounted) setState(() => allowed = value);
    } catch (_) {
      // No claim that an unavailable platform query means permission granted.
      if (mounted) setState(() => allowed = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return ListTile(
      leading: Icon(
        allowed == false
            ? Icons.warning_amber_rounded
            : Icons.phone_locked_outlined,
      ),
      title: Text(l.callLockScreenTitle),
      subtitle: Text(
        allowed == true
            ? l.callLockScreenAllowed
            : l.callLockScreenPermissionHint,
      ),
      onTap: () async {
        try {
          final opened = await channel.invokeMethod<bool>('request') ?? false;
          if (!opened && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l.callLockScreenSettingsFailed)),
            );
          }
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l.callLockScreenSettingsFailed)),
            );
          }
        }
      },
    );
  }
}
