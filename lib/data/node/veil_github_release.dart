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

class VeilGithubArtifact {
  const VeilGithubArtifact({
    required this.tag,
    required this.target,
    required this.binaryName,
    required this.downloadUrl,
    required this.sha256,
  });

  final String tag;
  final VeilLinuxReleaseTarget target;
  final String binaryName;
  final String downloadUrl;
  final String sha256;
}

class VeilReleaseException implements Exception {
  const VeilReleaseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The oldest veil release this build will install.
///
/// The floor under [VeilGithubReleaseResolver]: "latest" is whatever the API
/// says it is, and an API that can be made to answer with an old release is an
/// API that can hand this app a known-vulnerable binary to install as root.
/// Pinning the download URL to the tag does not help — an old release's assets
/// are genuine assets of that old release and pass every digest check.
///
/// Raise this whenever a veil release fixes something that matters. It is a
/// floor, not a pin: anything at or above it is accepted.
const String kMinimumVeilReleaseTag = 'v0.4.2';

/// A `vMAJOR.MINOR.PATCH[-pre]` release tag, ordered.
///
/// Only what is needed to say "this is older than that". A pre-release sorts
/// BELOW the release with the same numbers, as semver has it — so a tag like
/// `v0.4.2-rc1` cannot be served in place of `v0.4.2`.
class VeilReleaseVersion implements Comparable<VeilReleaseVersion> {
  const VeilReleaseVersion(
    this.major,
    this.minor,
    this.patch, {
    this.preRelease,
  });

  /// Null when [tag] is not a version at all. A tag this app cannot ORDER is a
  /// tag it cannot show is not a downgrade, so callers refuse it rather than
  /// letting an unrecognised shape through the check.
  static VeilReleaseVersion? tryParse(String tag) {
    final match = RegExp(
      r'^v?(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?:-([0-9A-Za-z.-]+))?$',
    ).firstMatch(tag.trim());
    if (match == null) return null;
    return VeilReleaseVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      preRelease: match.group(4),
    );
  }

  final int major;
  final int minor;
  final int patch;
  final String? preRelease;

  @override
  int compareTo(VeilReleaseVersion other) {
    final ordered = [
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
    ];
    for (final step in ordered) {
      if (step != 0) return step;
    }
    if ((preRelease == null) != (other.preRelease == null)) {
      return preRelease == null ? 1 : -1;
    }
    return (preRelease ?? '').compareTo(other.preRelease ?? '');
  }

  @override
  String toString() =>
      'v$major.$minor.$patch${preRelease == null ? '' : '-$preRelease'}';
}

/// Resolves veil binaries from the canonical veilnetwork/veil GitHub release.
///
/// Two digest sources, and it is worth being exact about what they are worth.
/// The GitHub-provided asset digest is preferred; older releases without that
/// API field fall back to the `sha256-<triple>.txt` asset. That manifest is
/// NOT an independent attestation: it is an asset of the SAME release as the
/// binary, downloaded from the same host under the same tag, and its URL is
/// pinned to that tag exactly like the binary's. Whoever can publish or alter a
/// release publishes both. A comment here used to call it "independently
/// published", which read like a second opinion and was not one (audit X-05).
///
/// What this does buy: the bytes that arrive are the bytes the release names,
/// so a substitution in transit or at a mirror is caught before
/// [buildNodeSoftwareUpdateScript] installs the file as root. What it does not
/// buy: any statement about who published the release. A signed manifest
/// (TUF/Sigstore) is the fix for that, and it lives mostly in veil's release
/// process, not here.
///
/// The one thing that IS enforced here is direction: see
/// [kMinimumVeilReleaseTag].
class VeilGithubReleaseResolver {
  VeilGithubReleaseResolver({
    ReleaseTextFetcher? fetcher,
    String minimumTag = kMinimumVeilReleaseTag,
  }) : _fetcher = fetcher ?? _httpGet,
       _minimumTag = minimumTag.trim();

  static final latestReleaseUri = Uri.https(
    'api.github.com',
    '/repos/veilnetwork/veil/releases/latest',
  );

  final ReleaseTextFetcher _fetcher;
  final String _minimumTag;
  Future<Map<String, dynamic>>? _latestReleaseData;

  /// Forces the next lookup to query GitHub again. Normal lookups share one
  /// response so selecting several components does not multiply API requests.
  void clearCache() => _latestReleaseData = null;

  Future<VeilCliRelease> resolve(VeilLinuxReleaseTarget target) async {
    final artifact = await resolveArtifact(
      target: target,
      binaryName: 'veil-cli',
    );
    return VeilCliRelease(
      tag: artifact.tag,
      target: artifact.target,
      downloadUrl: artifact.downloadUrl,
      sha256: artifact.sha256,
    );
  }

  Future<VeilGithubArtifact> resolveArtifact({
    required VeilLinuxReleaseTarget target,
    required String binaryName,
  }) async {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(binaryName)) {
      throw const VeilReleaseException('Invalid release binary name');
    }
    final decoded = await (_latestReleaseData ??= _loadLatestRelease());
    final tag = decoded['tag_name']! as String;
    final assets = decoded['assets']! as List<Object?>;

    final assetName = '$binaryName-${target.triple}';
    final binary = _assetNamed(assets, assetName);
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
        : await _shaFromManifest(
            assets,
            target: target,
            tag: tag,
            binaryName: binaryName,
          );

    return VeilGithubArtifact(
      tag: tag,
      target: target,
      binaryName: binaryName,
      downloadUrl: downloadUrl,
      sha256: sha256,
    );
  }

  Future<Map<String, dynamic>> _loadLatestRelease() async {
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
    _refuseDowngrade(tag);
    return decoded;
  }

  /// Refuse a "latest" that is older than this build's floor.
  ///
  /// Everything else in this class authenticates the BYTES: the URL is pinned
  /// to the tag and the digest is checked before the file is installed as root.
  /// None of that says anything about WHICH release was named. An API response
  /// that answers with an old release — a stale mirror, a rewritten reply, a
  /// re-pointed `latest` — hands over genuine, correctly-digested assets of a
  /// version whose bugs are public. Direction is the part that has to be
  /// checked here, because a signature would not check it either (audit X-05).
  void _refuseDowngrade(String tag) {
    final floor = VeilReleaseVersion.tryParse(_minimumTag);
    if (floor == null) {
      // A misconfigured floor must not silently mean "no floor".
      throw VeilReleaseException(
        'Minimum veil release "$_minimumTag" is not a version tag',
      );
    }
    final offered = VeilReleaseVersion.tryParse(tag);
    if (offered == null) {
      throw VeilReleaseException(
        'Latest GitHub release is tagged "$tag", which is not a version this '
        'build can compare — refusing it rather than guessing its age',
      );
    }
    if (offered.compareTo(floor) < 0) {
      throw VeilReleaseException(
        'Latest GitHub release is $tag, older than the minimum this build '
        'installs ($_minimumTag) — refusing a downgrade',
      );
    }
  }

  Future<String> _shaFromManifest(
    List<Object?> assets, {
    required VeilLinuxReleaseTarget target,
    required String tag,
    required String binaryName,
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
        '^([0-9a-fA-F]{64})\\s+\\*?${RegExp.escape(binaryName)}\$',
      ).firstMatch(line.trim());
      if (match != null) return match.group(1)!.toLowerCase();
    }
    throw VeilReleaseException(
      'Published checksum manifest does not contain $binaryName',
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

  static Future<String> _httpGet(Uri uri) => fetchGithubText(uri);
}

/// One hardened GET against the GitHub API, shared by everything here that
/// asks it anything.
///
/// Public because the app's own update check needs exactly this and nothing
/// else: a second copy would be a second set of timeouts and a second size cap
/// to keep in step, and the caps are the point — a response with no ceiling is
/// a memory bomb from a host nobody here controls.
Future<String> fetchGithubText(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 15));
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'xVeil-release-resolver');
    final response = await request.close().timeout(const Duration(seconds: 20));
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
