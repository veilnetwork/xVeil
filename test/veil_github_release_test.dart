import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/veil_github_release.dart';

void main() {
  const x64Sha =
      'de5f630023cdd7753bce89aae8b56b7ea2c410e2b0f7c40233b9d0ff939af069';
  const armSha =
      '5406a992a4d81777c8bcdd5534a72f40fd9bc6d7863f5eed5751701c6c3249df';

  // The tag rides in every asset URL, because the resolver refuses a download
  // URL that is not under `releases/download/<tag>/`.
  Map<String, Object?> releaseJson({
    String? digest = 'sha256:$x64Sha',
    String tag = kMinimumVeilReleaseTag,
  }) => {
    'tag_name': tag,
    'assets': [
      {
        'name': 'veil-cli-x86_64-unknown-linux-musl',
        'browser_download_url':
            'https://github.com/veilnetwork/veil/releases/download/$tag/'
            'veil-cli-x86_64-unknown-linux-musl',
        'digest': ?digest,
      },
      {
        'name': 'sha256-x86_64-unknown-linux-musl.txt',
        'browser_download_url':
            'https://github.com/veilnetwork/veil/releases/download/$tag/'
            'sha256-x86_64-unknown-linux-musl.txt',
      },
      {
        'name': 'ogate-x86_64-unknown-linux-musl',
        'browser_download_url':
            'https://github.com/veilnetwork/veil/releases/download/$tag/'
            'ogate-x86_64-unknown-linux-musl',
        'digest': 'sha256:$armSha',
      },
    ],
  };

  test('uses the SHA-256 supplied with the GitHub release asset', () async {
    final resolver = VeilGithubReleaseResolver(
      fetcher: (uri) async => jsonEncode(releaseJson()),
    );

    final result = await resolver.resolve(VeilLinuxReleaseTarget.x86_64Musl);

    expect(result.tag, kMinimumVeilReleaseTag);
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

  test('resolves optional tools and reuses one GitHub API response', () async {
    var apiRequests = 0;
    final resolver = VeilGithubReleaseResolver(
      fetcher: (uri) async {
        apiRequests++;
        return jsonEncode(releaseJson());
      },
    );

    final cli = await resolver.resolve(VeilLinuxReleaseTarget.x86_64Musl);
    final ogate = await resolver.resolveArtifact(
      target: VeilLinuxReleaseTarget.x86_64Musl,
      binaryName: 'ogate',
    );

    expect(cli.sha256, x64Sha);
    expect(ogate.downloadUrl, endsWith('ogate-x86_64-unknown-linux-musl'));
    expect(ogate.sha256, armSha);
    expect(apiRequests, 1);
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

  group('which release "latest" is allowed to be', () {
    // Everything else here authenticates the bytes: the URL is pinned to the
    // tag, the digest is checked before the binary is installed with sudo. None
    // of it says which release was named. An answer of "latest = v0.1.0" hands
    // over genuine, correctly-digested assets of a version whose bugs are
    // public — a rollback that passes every existing check (audit X-05).

    Future<VeilCliRelease> resolveTag(String tag, {String? minimum}) {
      final resolver = VeilGithubReleaseResolver(
        fetcher: (uri) async => jsonEncode(releaseJson(tag: tag)),
        minimumTag: minimum ?? kMinimumVeilReleaseTag,
      );
      return resolver.resolve(VeilLinuxReleaseTarget.x86_64Musl);
    }

    test('an older release is refused, and the error says why', () async {
      await expectLater(
        resolveTag('v0.3.1'),
        throwsA(
          isA<VeilReleaseException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('v0.3.1'),
              contains(kMinimumVeilReleaseTag),
              contains('downgrade'),
            ),
          ),
        ),
        reason: 'a stale or rewritten "latest" must not install an old binary',
      );
    });

    test('the floor itself and anything above it are accepted', () async {
      expect(
        (await resolveTag(kMinimumVeilReleaseTag)).tag,
        kMinimumVeilReleaseTag,
      );
      expect((await resolveTag('v9.9.9')).tag, 'v9.9.9');
      // Across a component boundary, not just the patch digit.
      expect((await resolveTag('v0.5.0', minimum: 'v0.4.2')).tag, 'v0.5.0');
      // And the pair that a string comparison gets backwards: '10' sorts
      // before '9' as text, so a lexical check would call the NEWER release a
      // downgrade and refuse every upgrade past x.9.
      expect((await resolveTag('v0.10.0', minimum: 'v0.9.0')).tag, 'v0.10.0');
      await expectLater(
        resolveTag('v0.4.9', minimum: 'v0.5.0'),
        throwsA(isA<VeilReleaseException>()),
      );
    });

    test('a pre-release cannot stand in for the release it precedes', () async {
      // `v0.4.2-rc1` is not `v0.4.2`, and semver puts it below.
      await expectLater(
        resolveTag('v0.4.2-rc1', minimum: 'v0.4.2'),
        throwsA(isA<VeilReleaseException>()),
      );
      expect(
        (await resolveTag('v0.4.3-rc1', minimum: 'v0.4.2')).tag,
        'v0.4.3-rc1',
      );
    });

    test(
      'a tag that cannot be ordered is refused, not waved through',
      () async {
        // "nightly" is not older than the floor and not newer either — it is
        // unknown, and an unknown age is exactly what the check exists to stop.
        for (final tag in ['nightly', 'latest', 'v0.4', 'release-2026-08-01']) {
          await expectLater(
            resolveTag(tag),
            throwsA(
              isA<VeilReleaseException>().having(
                (e) => e.message,
                'message',
                contains('not a version'),
              ),
            ),
            reason: '"$tag" was accepted',
          );
        }
      },
    );

    test('a floor that is not a version fails closed', () async {
      await expectLater(
        resolveTag('v9.9.9', minimum: 'not-a-tag'),
        throwsA(isA<VeilReleaseException>()),
        reason: 'a misconfigured floor must not quietly mean "no floor"',
      );
    });

    test('the shipped floor is a real, parseable version', () {
      expect(
        VeilReleaseVersion.tryParse(kMinimumVeilReleaseTag),
        isNotNull,
        reason: 'the default would fail closed on every lookup otherwise',
      );
    });
  });

  group('version ordering', () {
    VeilReleaseVersion v(String tag) => VeilReleaseVersion.tryParse(tag)!;

    test('orders by component, not lexically', () {
      // '10' < '9' as text. This is why the tag is parsed rather than compared.
      expect(v('v0.10.0').compareTo(v('v0.9.0')), greaterThan(0));
      expect(v('v1.0.0').compareTo(v('v0.99.99')), greaterThan(0));
      expect(v('v0.4.2').compareTo(v('v0.4.2')), 0);
      expect(v('0.4.2').compareTo(v('v0.4.2')), 0, reason: 'the v is optional');
    });

    test('a pre-release sorts below its own release', () {
      expect(v('v0.4.2-rc1').compareTo(v('v0.4.2')), lessThan(0));
      expect(v('v0.4.2').compareTo(v('v0.4.2-rc1')), greaterThan(0));
      expect(v('v0.4.2-rc1').compareTo(v('v0.4.1')), greaterThan(0));
    });
  });

  /// A lookup that failed must not be remembered as the answer.
  ///
  /// The shared response is stored as a FUTURE, and a Future that completed
  /// with an error is a Future: one request made while the network was down
  /// was re-thrown to every later caller for as long as the resolver lived —
  /// including the explicit Check somebody pressed after the network came
  /// back. The fleet screen has no `clearCache` on that path, so the only way
  /// out was closing the screen (report15 X15-L6).
  test(
    'a failed lookup is not cached, and the next call really asks',
    () async {
      var calls = 0;
      final resolver = VeilGithubReleaseResolver(
        fetcher: (uri) async {
          calls++;
          if (calls == 1) throw const VeilReleaseException('offline');
          return jsonEncode(releaseJson());
        },
      );

      await expectLater(
        resolver.resolve(VeilLinuxReleaseTarget.x86_64Musl),
        throwsA(isA<VeilReleaseException>()),
        reason: 'premise: the first lookup fails',
      );

      final second = await resolver.resolve(VeilLinuxReleaseTarget.x86_64Musl);

      expect(calls, 2, reason: 'the failure was served again from the cache');
      expect(second.sha256, x64Sha);
    },
  );

  /// Vacuity guard: a SUCCESSFUL response is still shared, or the fix above is
  /// "stop caching", which multiplies API requests per selected component.
  test('and a successful response is still shared', () async {
    var calls = 0;
    final resolver = VeilGithubReleaseResolver(
      fetcher: (uri) async {
        calls++;
        return jsonEncode(releaseJson());
      },
    );

    await resolver.resolve(VeilLinuxReleaseTarget.x86_64Musl);
    await resolver.resolve(VeilLinuxReleaseTarget.x86_64Musl);

    expect(calls, 1, reason: 'the shared response stopped being shared');
  });
}
