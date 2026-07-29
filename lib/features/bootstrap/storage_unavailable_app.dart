import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// The whole app, when secure storage could not be opened in a shipped build.
///
/// Deliberately NOT a screen inside the normal app: it replaces the router
/// entirely (see `mustRefuseInsecureStorage`), so there is no unlock prompt to
/// reach, no onboarding to complete and no local API to start. The failure is
/// not recoverable from inside the process — the native library is missing or
/// does not match this build — so there is no retry button to offer honestly.
///
/// It names the cause without a stack trace: a stack on screen is an
/// information leak in a deniable app (the same reason [ErrorWidget.builder] is
/// replaced in release), and it would tell the user nothing they can act on.
class StorageUnavailableApp extends StatelessWidget {
  const StorageUnavailableApp({super.key});

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
      home: const _StorageUnavailableScreen(),
    );
  }
}

class _StorageUnavailableScreen extends StatelessWidget {
  const _StorageUnavailableScreen();

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
                Icon(Icons.lock_outline, size: 56, color: scheme.error),
                const SizedBox(height: 24),
                Text(
                  l.storageUnavailableTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text(
                  l.storageUnavailableBody,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                Text(
                  l.storageUnavailableAction,
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
