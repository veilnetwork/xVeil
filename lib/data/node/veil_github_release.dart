import 'dart:convert';
import 'dart:io';

typedef ReleaseTextFetcher = Future<String> Function(Uri uri);

/// Linux release targets supported by the SSH provisioner. The musl builds are
/// preferred because they do not depend on the server's glibc version.
enum VeilLinuxReleaseTarget {
  x86_64Musl('x86_64-unknown-linux-musl'),
  aarch64Musl('aarch64-unknown-linux-musl');

  const VeilLinuxReleaseTarget(this.triple);

  final String triple;
}

class VeilCliRelease {
  const VeilCliRelease({
    required this.tag,
    required this.target,
    required this.downloadUrl,
    required this.sha256,
  });

  final String tag;
  final VeilLinuxReleaseTarget target;
  final String downloadUrl;
  final String sha256;
}

class VeilReleaseException implements Exception {
  const VeilReleaseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Resolves veil-cli from the canonical veilnetwork/veil GitHub release.
///
/// The GitHub-provided asset digest is preferred. Older releases without that
/// API field fall back to the independently published target manifest.
class VeilGithubReleaseResolver {
  VeilGithubReleaseResolver({ReleaseTextFetcher? fetcher})
    : _fetcher = fetcher ?? _httpGet;

  static final latestReleaseUri = Uri.https(
    'api.github.com',
    '/repos/veilnetwork/veil/releases/latest',
  );

  final ReleaseTextFetcher _fetcher;

  Future<VeilCliRelease> resolve(VeilLinuxReleaseTarget target) async {
    final body = await _fetcher(latestReleaseUri);
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const VeilReleaseException('GitHub returned invalid release data');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const VeilReleaseException('GitHub returned invalid release data');
    }
    final tag = decoded['tag_name'];
    final assets = decoded['assets'];
    if (tag is! String || tag.isEmpty || assets is! List) {
      throw const VeilReleaseException('Latest GitHub release is incomplete');
    }

    final binaryName = 'veil-cli-${target.triple}';
    final binary = _assetNamed(assets, binaryName);
    final downloadUrl = binary['browser_download_url'];
    if (downloadUrl is! String || !_isCanonicalDownload(downloadUrl, tag)) {
      throw const VeilReleaseException(
        'GitHub release contains an unexpected download URL',
      );
    }

    final digest = binary['digest'];
    final apiSha = digest is String && digest.startsWith('sha256:')
        ? digest.substring('sha256:'.length)
        : null;
    final sha256 = apiSha != null && _isSha256(apiSha)
        ? apiSha.toLowerCase()
        : await _shaFromManifest(assets, target: target, tag: tag);

    return VeilCliRelease(
      tag: tag,
      target: target,
      downloadUrl: downloadUrl,
      sha256: sha256,
    );
  }

  Future<String> _shaFromManifest(
    List<Object?> assets, {
    required VeilLinuxReleaseTarget target,
    required String tag,
  }) async {
    final manifest = _assetNamed(assets, 'sha256-${target.triple}.txt');
    final manifestUrl = manifest['browser_download_url'];
    if (manifestUrl is! String || !_isCanonicalDownload(manifestUrl, tag)) {
      throw const VeilReleaseException(
        'GitHub release contains an unexpected checksum URL',
      );
    }
    final text = await _fetcher(Uri.parse(manifestUrl));
    for (final line in const LineSplitter().convert(text)) {
      final match = RegExp(
        r'^([0-9a-fA-F]{64})\s+\*?veil-cli$',
      ).firstMatch(line.trim());
      if (match != null) return match.group(1)!.toLowerCase();
    }
    throw const VeilReleaseException(
      'Published checksum manifest does not contain veil-cli',
    );
  }

  static Map<String, dynamic> _assetNamed(
    List<Object?> assets,
    String expectedName,
  ) {
    for (final asset in assets) {
      if (asset is Map<String, dynamic> && asset['name'] == expectedName) {
        return asset;
      }
    }
    throw VeilReleaseException(
      'Latest GitHub release has no $expectedName asset',
    );
  }

  static bool _isCanonicalDownload(String raw, String tag) {
    final uri = Uri.tryParse(raw);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'github.com' &&
        uri.path.startsWith('/veilnetwork/veil/releases/download/$tag/');
  }

  static bool _isSha256(String value) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

  static Future<String> _httpGet(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'xVeil-release-resolver');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw VeilReleaseException(
          'GitHub request failed with HTTP ${response.statusCode}',
        );
      }
      const maxBytes = 2 * 1024 * 1024;
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) {
          throw const VeilReleaseException('GitHub response is too large');
        }
      }
      return utf8.decode(bytes);
    } on VeilReleaseException {
      rethrow;
    } on Object catch (error) {
      throw VeilReleaseException('Could not load GitHub release: $error');
    } finally {
      client.close(force: true);
    }
  }
}
