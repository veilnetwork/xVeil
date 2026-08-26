import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/update/app_update.dart';

/// Telling somebody they are out of date when they are not is worse than
/// staying quiet: it sends them to a download page for no reason, and on a
/// build that cannot name itself it would do so on every single launch.
///
/// So most of what follows is about what the check REFUSES.
void main() {
  final now = DateTime.utc(2026, 8, 26, 12);

  group('when to ask', () {
    test('the first run asks', () {
      expect(shouldCheckForUpdate(lastCheck: null, now: now), isTrue);
    });

    test('a check a minute ago does not ask again', () {
      // Each request tells github.com that this device runs xVeil, from this
      // address, at this moment. Once a day, not once a launch.
      expect(
        shouldCheckForUpdate(
          lastCheck: now.subtract(const Duration(minutes: 1)),
          now: now,
        ),
        isFalse,
      );
    });

    test('a day later asks', () {
      expect(
        shouldCheckForUpdate(
          lastCheck: now.subtract(const Duration(hours: 24)),
          now: now,
        ),
        isTrue,
      );
      expect(
        shouldCheckForUpdate(
          lastCheck: now.subtract(const Duration(hours: 23, minutes: 59)),
          now: now,
        ),
        isFalse,
      );
    });

    test('a check stamped in the FUTURE asks', () {
      // The clock was moved back. The alternative is an app that stops
      // checking until the clock catches up, which after one trip to 2030 is
      // never.
      expect(
        shouldCheckForUpdate(
          lastCheck: now.add(const Duration(days: 400)),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('reading GitHub’s answer', () {
    const page = 'https://github.com/veilnetwork/xVeil/releases/tag/v0.14.0';

    Future<AppUpdateCheck> look(String body, {String running = '0.13.3+11'}) =>
        AppUpdateChecker(running: running, fetcher: (_) async => body).check();

    /// The release to offer, for the cases that are only about that.
    Future<AppUpdate?> ask(String body, {String running = '0.13.3+11'}) async =>
        (await look(body, running: running)).update;

    test('a newer published release is offered', () async {
      final update = await ask(
        '{"tag_name":"v0.14.0","html_url":"$page",'
        '"draft":false,"prerelease":false}',
      );

      expect(update, isNotNull);
      expect(update!.tag, 'v0.14.0');
    });

    test('a draft is never offered', () async {
      // This project's releases are drafts until somebody publishes them on
      // purpose, and a draft is not a thing to send people to.
      expect(
        await ask('{"tag_name":"v0.14.0","html_url":"$page","draft":true}'),
        isNull,
      );
    });

    test('a pre-release is not offered', () async {
      expect(
        await ask(
          '{"tag_name":"v0.14.0","html_url":"$page","prerelease":true}',
        ),
        isNull,
      );
    });

    test('a response missing what it needs is a refusal, not a crash', () async {
      for (final body in [
        '{}',
        '[]',
        'not json at all',
        '{"tag_name":123,"html_url":"$page"}',
        '{"tag_name":"v0.14.0"}',
      ]) {
        expect(await ask(body), isNull, reason: body);
      }
    });

    test('a network failure is silence, not an error on launch', () async {
      final checker = AppUpdateChecker(
        running: '0.13.3+11',
        fetcher: (_) async => throw const SocketException('offline'),
      );

      // Silence, not a thrown error — and now silence with a REASON attached:
      // nothing to offer, and the feed was never reached.
      final result = await checker.check();
      expect(result.update, isNull);
      expect(result.reached, isFalse);
    });

    test('the endpoint is the app’s own repository', () async {
      Uri? asked;
      await AppUpdateChecker(
        running: '0.13.3+11',
        fetcher: (uri) async {
          asked = uri;
          return '{}';
        },
      ).check();

      expect(asked?.host, 'api.github.com');
      expect(asked?.path, contains('veilnetwork/xVeil'));
      // `releases/latest` and not `releases`: that endpoint is what excludes
      // drafts and pre-releases in the first place.
      expect(asked?.path, endsWith('/releases/latest'));
    });
  });

  group('what to offer', () {
    const url = 'https://github.com/veilnetwork/xVeil/releases/tag/v0.13.4';

    AppUpdate? offer(String running, String tag, [String at = url]) =>
        newerRelease(running: running, latestTag: tag, releaseUrl: at);

    test('a newer release is offered', () {
      final update = offer('0.13.3+11', 'v0.13.4');

      expect(update, isNotNull);
      expect(update!.tag, 'v0.13.4');
      expect(update.url, url);
    });

    test('the build metadata does not decide anything', () {
      // pubspec hands over `0.13.3+11`; `+11` is not part of the ordering.
      expect(offer('0.13.3+99', 'v0.13.3'), isNull);
      expect(offer('0.13.3+1', 'v0.13.4'), isNotNull);
    });

    test('the same version is not an update', () {
      expect(offer('0.13.3+11', 'v0.13.3'), isNull);
    });

    test('an OLDER release is refused', () {
      // "latest" is whatever the API says it is, and an API that can be made
      // to answer with an old release is one that can walk somebody backwards.
      expect(offer('0.13.3+11', 'v0.12.0'), isNull);
      expect(offer('0.13.3+11', 'v0.13.2'), isNull);
    });

    test('a pre-release does not displace the release it precedes', () {
      expect(offer('0.13.4+1', 'v0.13.4-rc1'), isNull);
      expect(offer('0.13.3+1', 'v0.13.4-rc1'), isNotNull);
    });

    test('a build that cannot name itself is never told it is old', () {
      // `kAppVersion` falls back to `dev` when the define was not passed.
      // Offering an update there nags every developer build, every launch.
      expect(offer('dev', 'v9.9.9'), isNull);
      expect(offer('', 'v9.9.9'), isNull);
    });

    test('a tag this app cannot order is refused', () {
      for (final tag in ['latest', 'v1.2', 'nightly-2026-08-26', '']) {
        expect(offer('0.13.3+11', tag), isNull, reason: tag);
      }
    });

    test('a release page that is not https is refused', () {
      // The URL is handed to a browser. It comes from a network response.
      expect(offer('0.13.3+11', 'v0.13.4', 'http://example.org'), isNull);
      expect(
        offer('0.13.3+11', 'v0.13.4', 'javascript:alert(1)'),
        isNull,
      );
    });

    test('the offer is not vacuous', () {
      // Guard for the refusals above: a function that returned null for
      // everything would satisfy all of them.
      expect(offer('0.13.3+11', 'v0.14.0'), isNotNull);
      expect(offer('0.13.3+11', 'v1.0.0'), isNotNull);
    });
  });

  group('answered, versus not answered at all', () {
    // "Could not ask" and "nothing new" used to be the same answer — both null
    // — and they are not the same thing to say. A screen that shows a failed
    // request as "up to date" is making a claim about the release feed that
    // nothing supports (report16 XV-15).
    const page = 'https://github.com/veilnetwork/xVeil/releases/tag/v0.14.0';

    test('a feed that answered "nothing newer" was REACHED', () async {
      final result = await AppUpdateChecker(
        running: '0.13.3+11',
        fetcher: (_) async =>
            '{"tag_name":"v0.13.3","html_url":"$page",'
            '"draft":false,"prerelease":false}',
      ).check();

      expect(result.update, isNull);
      expect(result.reached, isTrue);
    });

    test('a request that failed was not', () async {
      final result = await AppUpdateChecker(
        running: '0.13.3+11',
        fetcher: (_) async => throw const SocketException('no route to host'),
      ).check();

      expect(result.update, isNull);
      expect(
        result.reached,
        isFalse,
        reason: 'a failed request reads as "up to date" on the screen',
      );
    });

    test('and neither is an answer that made no sense', () async {
      for (final body in ['not json', '[]', '{"tag_name":42}']) {
        final result = await AppUpdateChecker(
          running: '0.13.3+11',
          fetcher: (_) async => body,
        ).check();

        expect(result.reached, isFalse, reason: body);
      }
    });

    test('a draft or a pre-release IS an answer', () async {
      // The feed was reached and said there is nothing for this channel. That
      // is up to date, not a failure to ask.
      final result = await AppUpdateChecker(
        running: '0.13.3+11',
        fetcher: (_) async =>
            '{"tag_name":"v9.9.9","html_url":"$page",'
            '"draft":true,"prerelease":false}',
      ).check();

      expect(result.update, isNull);
      expect(result.reached, isTrue);
    });
  });
}
