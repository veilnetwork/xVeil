import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Outside the ordinary provider/router tree: neither saved-entry prompts nor
/// onboarding, networking or ordinary storage readers can start here.
/// This screen reports a pending operation; it does not claim cleanup finished.
class ProfileErasurePendingApp extends StatelessWidget {
  const ProfileErasurePendingApp({super.key});

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
    home: Builder(
      builder: (context) {
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
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
