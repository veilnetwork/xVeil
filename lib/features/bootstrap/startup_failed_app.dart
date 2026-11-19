import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../settings/error_report.dart';

/// The whole app, when startup threw before it could put anything on screen.
///
/// Everything between `main()` and `runApp` runs inside the guarded zone, and
/// the zone handler LOGS an uncaught error — it cannot un-skip the `runApp` the
/// throw jumped over. So a failure anywhere in bootstrap (a preference store
/// that will not install, a container path that will not resolve, a provider
/// override that throws while it is being built) ended with an empty window and
/// nothing to read and no way to export diagnostics.
///
/// The screen offers diagnostic export and, when preferences are busy, a retry.
/// The stack trace stays in the log and error journal.
class StartupFailedApp extends StatelessWidget {
  const StartupFailedApp({super.key, this.retryPreferences});

  final Future<void> Function()? retryPreferences;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      home: _StartupFailedScreen(retryPreferences: retryPreferences),
    );
  }
}

class _StartupFailedScreen extends StatefulWidget {
  const _StartupFailedScreen({required this.retryPreferences});

  final Future<void> Function()? retryPreferences;

  @override
  State<_StartupFailedScreen> createState() => _StartupFailedScreenState();
}

class _StartupFailedScreenState extends State<_StartupFailedScreen> {
  bool _retrying = false;

  Future<void> _retry(Future<void> Function() retryPreferences) async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await retryPreferences();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final retryPreferences = widget.retryPreferences;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 56, color: scheme.error),
                const SizedBox(height: 24),
                Text(
                  l.startupFailedTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                const CopyErrorReportTile(phase: 'startup-failed'),
                Text(
                  retryPreferences == null
                      ? l.startupFailedAction
                      : l.startupPreferencesBusy,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (retryPreferences != null) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _retrying
                        ? null
                        : () => _retry(retryPreferences),
                    child: Text(l.startupRetry),
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
