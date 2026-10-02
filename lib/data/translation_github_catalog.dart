import 'dart:convert';
import 'dart:io';

import 'node/veil_github_release.dart' show ReleaseTextFetcher, fetchGithubText;
import 'pinned_download.dart';
import 'veil_bundle.dart';

/// Translation bundles attached to published xVeil releases. GitHub's asset
/// digest pins the bytes; the bundle reader also checks every contained file.
class TranslationGithubBundle {
  const TranslationGithubBundle({
    required this.name,
    required this.tag,
    required this.artifact,
  });

  final String name;
  final String tag;
  final PinnedArtifact artifact;

  String get pair =>
      name.substring(0, name.length - kTranslateBundleExt.length);

  Uri get releasePage =>
      Uri.https('github.com', '/veilnetwork/xVeil/releases/tag/$tag');
}

class TranslationGithubCatalog {
  TranslationGithubCatalog({ReleaseTextFetcher? fetcher})
    : _fetcher = fetcher ?? fetchGithubText;

  static final releasesUri = Uri.https(
    'api.github.com',
    '/repos/veilnetwork/xVeil/releases',
    {'per_page': '30'},
  );
  // The first published pairs live here. The recent-release list is bounded
  // for GitHub response size, so without this anchor the first models would
  // disappear after enough app releases.
  static const firstModelsTag = 'v0.13.83';
  static final firstModelsUri = Uri.https(
    'api.github.com',
    '/repos/veilnetwork/xVeil/releases/tags/$firstModelsTag',
  );

  final ReleaseTextFetcher _fetcher;

  Future<List<TranslationGithubBundle>> load() async {
    final recent = parse(await _fetcher(releasesUri));
    if (recent.any((bundle) => bundle.tag == firstModelsTag)) return recent;
    try {
      final first = parse(await _fetcher(firstModelsUri));
      final knownNames = recent.map((bundle) => bundle.name).toSet();
      return [
        ...recent,
        ...first.where((bundle) => !knownNames.contains(bundle.name)),
      ];
    } on Object {
      if (recent.isNotEmpty) return recent;
      rethrow;
    }
  }

  static List<TranslationGithubBundle> parse(String body) {
    final Object? decoded = jsonDecode(body);
    if (decoded is! List && decoded is! Map) {
      throw const FormatException('Invalid releases');
    }
    final result = <TranslationGithubBundle>[];
    final seen = <String>{};
    for (final release in decoded is List ? decoded : [decoded]) {
      if (release is! Map ||
          release['draft'] == true ||
          release['prerelease'] == true) {
        continue;
      }
      final tag = release['tag_name'];
      final assets = release['assets'];
      if (tag is! String ||
          !RegExp(r'^v[0-9A-Za-z._-]{1,64}$').hasMatch(tag) ||
          assets is! List) {
        continue;
      }
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = asset['name'];
        final size = asset['size'];
        final digest = asset['digest'];
        final rawUrl = asset['browser_download_url'];
        if (name is! String ||
            !RegExp(r'^[a-z]{2,3}-[a-z]{2,3}\.veiltranslate$').hasMatch(name) ||
            size is! int ||
            size <= 0 ||
            size > kMaxReceivedBundleBytes ||
            digest is! String ||
            !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest) ||
            rawUrl is! String) {
          continue;
        }
        final url = Uri.tryParse(rawUrl);
        if (url == null ||
            url.scheme != 'https' ||
            url.host != 'github.com' ||
            url.path != '/veilnetwork/xVeil/releases/download/$tag/$name' ||
            url.hasQuery ||
            url.hasFragment ||
            !seen.add(name)) {
          continue;
        }
        result.add(
          TranslationGithubBundle(
            name: name,
            tag: tag,
            artifact: PinnedArtifact(
              url: rawUrl,
              bytes: size,
              sha256: digest.substring(7).toLowerCase(),
            ),
          ),
        );
      }
    }
    return result;
  }

  static Future<PinnedDownload> download({
    required TranslationGithubBundle bundle,
    required Directory root,
    void Function(double)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final downloads = Directory('${root.path}/.github-downloads')
      ..createSync(recursive: true);
    final target = File(
      '${downloads.path}/${bundle.artifact.sha256.substring(0, 16)}-${bundle.name}',
    );
    if (target.existsSync()) {
      if (target.lengthSync() == bundle.artifact.bytes &&
          await sha256OfFileStreaming(target) == bundle.artifact.sha256) {
        onProgress?.call(1);
        return PinnedDownload.ok(target.path);
      }
      target.deleteSync();
    }
    return fetchPinned(
      target: target,
      artifact: bundle.artifact,
      httpClient: HttpClient.new,
      stallTimeout: const Duration(seconds: 30),
      logTag: 'translate-github',
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }
}
