import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/translation_github_catalog.dart';
import '../../l10n/app_localizations.dart';
import '../../state/translation_model_controller.dart';

final translationGithubCatalogProvider = Provider<TranslationGithubCatalog>(
  (ref) => TranslationGithubCatalog(),
);

Future<void> showTranslationGithubSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _TranslationGithubSheet(),
    );

class _TranslationGithubSheet extends ConsumerStatefulWidget {
  const _TranslationGithubSheet();

  @override
  ConsumerState<_TranslationGithubSheet> createState() =>
      _TranslationGithubSheetState();
}

class _TranslationGithubSheetState
    extends ConsumerState<_TranslationGithubSheet> {
  late Future<List<TranslationGithubBundle>> _listing;
  String? _downloading;
  double? _progress;
  String? _error;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _listing = ref.read(translationGithubCatalogProvider).load();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _download(TranslationGithubBundle bundle) async {
    if (_downloading != null) return;
    final l = AppL10n.of(context);
    setState(() {
      _downloading = bundle.name;
      _progress = 0;
      _error = null;
    });
    try {
      final root = await ref.read(translationModelsRootProvider)();
      if (root == null) throw StateError(l.translationGithubNoStorage);
      final downloaded = await TranslationGithubCatalog.download(
        bundle: bundle,
        root: root,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted || downloaded.wasCancelled) return;
      if (!downloaded.succeeded) {
        throw StateError(downloaded.error ?? l.translationGithubFailed);
      }
      final installed = await ref
          .read(translationModelsControllerProvider.notifier)
          .importBundle(downloaded.path!);
      // The installed five files are the durable copy. Keeping the archive as
      // well would silently double the storage cost of every downloaded pair.
      try {
        await File(downloaded.path!).delete();
      } on FileSystemException {
        // Installation succeeded even if cache cleanup must wait.
      }
      if (!mounted) return;
      if (installed) {
        Navigator.of(context).pop();
      } else {
        final reason = ref.read(translationModelsControllerProvider).error;
        setState(
          () => _error = reason == null
              ? l.translationModelsFailed
              : '${l.translationModelsFailed}: $reason',
        );
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _downloading = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _openRelease(TranslationGithubBundle bundle) async {
    try {
      if (!await launchUrl(
        bundle.releasePage,
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('Could not open release');
      }
    } on Object {
      if (mounted) {
        setState(
          () => _error = AppL10n.of(context).translationGithubOpenFailed,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(l.translationGithubTitle),
            subtitle: Text(l.translationGithubHint),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          FutureBuilder<List<TranslationGithubBundle>>(
            future: _listing,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return ListTile(
                  title: Text(l.translationGithubFailed),
                  subtitle: Text('${snapshot.error}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () => setState(() {
                      _listing = ref
                          .read(translationGithubCatalogProvider)
                          .load();
                    }),
                  ),
                );
              }
              final bundles = snapshot.data!;
              if (bundles.isEmpty) {
                return ListTile(title: Text(l.translationGithubEmpty));
              }
              return Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final bundle in bundles)
                      ListTile(
                        title: Text(bundle.pair.replaceFirst('-', ' → ')),
                        subtitle: Text(
                          '${bundle.tag} · '
                          '${(bundle.artifact.bytes / (1024 * 1024)).round()} MB',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.info_outline),
                              tooltip: l.translationGithubSourceLicense,
                              onPressed: () => _openRelease(bundle),
                            ),
                            if (_downloading == bundle.name)
                              SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  value: _progress,
                                ),
                              )
                            else
                              const Icon(Icons.download_outlined),
                          ],
                        ),
                        onTap: _downloading == null
                            ? () => _download(bundle)
                            : null,
                      ),
                  ],
                ),
              );
            },
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
