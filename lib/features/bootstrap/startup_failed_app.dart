import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// The whole app, when startup threw before it could put anything on screen.
///
/// Everything between `main()` and `runApp` runs inside the guarded zone, and
/// the zone handler LOGS an uncaught error — it cannot un-skip the `runApp` the
/// throw jumped over. So a failure anywhere in bootstrap (a preference store
/// that will not install, a container path that will not resolve, a provider
/// override that throws while it is being built) ended with an empty window and
/// nothing to read: the process alive, the log written where nobody looks, and
/// a user with no idea whether their data was touched.
///
/// It answers exactly that question and nothing else. No stack trace — a stack
/// on screen is an information leak in a deniable app (the same reason
/// [ErrorWidget.builder] is replaced in release builds) and there is nothing in
/// it a user can act on. The detail goes to the log and the error journal.
class StartupFailedApp extends StatelessWidget {
  const StartupFailedApp({super.key});

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
      home: const _StartupFailedScreen(),
    );
  }
}

class _StartupFailedScreen extends StatelessWidget {
  const _StartupFailedScreen();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
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
                Text(
                  l.startupFailedBody,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                Text(
                  l.startupFailedAction,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
