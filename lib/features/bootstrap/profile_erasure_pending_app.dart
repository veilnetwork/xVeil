import 'dart:async';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Outside the ordinary provider/router tree: neither saved-entry prompts nor
/// onboarding, networking or ordinary storage readers can start here.
/// This screen reports a pending operation; it does not claim cleanup finished.
class ProfileErasurePendingApp extends StatelessWidget {
  const ProfileErasurePendingApp({
    super.key,
    this.recover,
    this.onRecovered,
    this.close,
  });
  final Future<void> Function()? recover;
  final Future<void> Function()? onRecovered;
  final Future<void> Function()? close;

  @override
  Widget build(BuildContext context) => MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0E6B5C),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    home: _RecoveryBody(
      key: recover == null ? null : ObjectKey(recover),
      recover: recover,
      onRecovered: onRecovered,
      close: close,
    ),
  );
}

class _RecoveryBody extends StatefulWidget {
  const _RecoveryBody({super.key, this.recover, this.onRecovered, this.close});
  final Future<void> Function()? recover, onRecovered, close;
  @override
  State<_RecoveryBody> createState() => _RecoveryBodyState();
}

class _RecoveryBodyState extends State<_RecoveryBody> {
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    if (widget.recover != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_resume());
      });
    }
  }

  Future<void> _resume() async {
    if (_busy || widget.recover == null) return;
    final recover = widget.recover!, completed = widget.onRecovered;
    setState(() => _busy = true);
    try {
      await recover();
      if (mounted && identical(widget.onRecovered, completed)) {
        await completed?.call();
      }
    } catch (_) {
      /* Keep the recovery boundary; a user can retry this owner. */
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    final close = widget.close;
    if (close != null) unawaited(close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.delete_outline,
                  size: 56,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 24),
                Text(
                  l.profileErasurePendingTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text(
                  l.profileErasurePendingBody,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                if (_busy) ...[
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(),
                ] else if (widget.recover != null) ...[
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _resume,
                    icon: const Icon(Icons.refresh),
                    label: Text(l.lockWipeRetry),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
