import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/veil_github_release.dart';

void main() {
  const x64Sha =
      'de5f630023cdd7753bce89aae8b56b7ea2c410e2b0f7c40233b9d0ff939af069';
  const armSha =
      '5406a992a4d81777c8bcdd5534a72f40fd9bc6d7863f5eed5751701c6c3249df';

  Map<String, Object?> releaseJson({String? digest = 'sha256:$x64Sha'}) => {
    'tag_name': 'v0.3.1',
    'assets': [
      {
        'name': 'veil-cli-x86_64-unknown-linux-musl',
        'browser_download_url':
            'https://github.com/veilnetwork/veil/releases/download/v0.3.1/'
            'veil-cli-x86_64-unknown-linux-musl',
        'digest': ?digest,
      },
      {
        'name': 'sha256-x86_64-unknown-linux-musl.txt',
        'browser_download_url':
            'https://github.com/veilnetwork/veil/releases/download/v0.3.1/'
            'sha256-x86_64-unknown-linux-musl.txt',
      },
    ],
  };

  test('uses the SHA-256 supplied with the GitHub release asset', () async {
    final resolver = VeilGithubReleaseResolver(
      fetcher: (uri) async => jsonEncode(releaseJson()),
    );

    final result = await resolver.resolve(VeilLinuxReleaseTarget.x86_64Musl);

    expect(result.tag, 'v0.3.1');
    expect(result.sha256, x64Sha);
    expect(result.downloadUrl, endsWith('x86_64-unknown-linux-musl'));
  });

  test('falls back to the published target checksum manifest', () async {
    final resolver = VeilGithubReleaseResolver(
      fetcher: (uri) async {
        if (uri == VeilGithubReleaseResolver.latestReleaseUri) {
          return jsonEncode(releaseJson(digest: null));
        }
        return '$armSha  ogate\n$x64Sha  veil-cli\n';
      },
    );

    final result = await resolver.resolve(VeilLinuxReleaseTarget.x86_64Musl);

    expect(result.sha256, x64Sha);
  });

  test('rejects a release asset outside the canonical GitHub repo', () async {
    final json = releaseJson();
    final assets = json['assets']! as List<Object?>;
    (assets.first! as Map<String, Object?>)['browser_download_url'] =
        'https://attacker.example/veil-cli';
    final resolver = VeilGithubReleaseResolver(
      fetcher: (uri) async => jsonEncode(json),
    );

    expect(
      () => resolver.resolve(VeilLinuxReleaseTarget.x86_64Musl),
      throwsA(isA<VeilReleaseException>()),
    );
  });
}
