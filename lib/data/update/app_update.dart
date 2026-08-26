import 'dart:convert';

import '../node/veil_github_release.dart';

/// A release newer than the one running.
class AppUpdate {
  const AppUpdate({required this.tag, required this.url});

  /// The release tag, as GitHub spells it (`v0.13.4`).
  final String tag;

  /// The release page, for a person to read before deciding.
  final String url;
}

/// What a look at the release feed found.
///
/// Three answers, not two. The feed said there is something newer; the feed
/// answered and there is not; or the feed could not be asked. The last is not
/// evidence about the release at all, and a screen that shows it as "up to
/// date" is making a claim on nothing.
class AppUpdateCheck {
  const AppUpdateCheck.found(AppUpdate this.update) : reached = true;
  const AppUpdateCheck.upToDate() : update = null, reached = true;
  const AppUpdateCheck.unreachable() : update = null, reached = false;

  /// The release to offer, or null when there is none to offer.
  final AppUpdate? update;

  /// Whether the feed answered at all.
  final bool reached;
}

/// How often to ask. First run asks immediately; after that, once a day.
const Duration kUpdateCheckInterval = Duration(hours: 24);

/// Whether to ask GitHub now.
///
/// [lastCheck] null means nothing has ever been recorded — the first run — and
/// that asks. Afterwards the answer is time alone: the app must not ask on
/// every launch, because each request tells github.com that this device runs
/// xVeil, from this address, at this moment.
///
/// A [lastCheck] in the FUTURE also asks. That happens when the clock is moved
/// back, and the alternative is an app that silently stops checking until the
/// clock catches up — which on a device whose owner set the year to 2030 once
/// is never.
bool shouldCheckForUpdate({
  required DateTime? lastCheck,
  required DateTime now,
  Duration every = kUpdateCheckInterval,
}) {
  if (lastCheck == null) return true;
  if (lastCheck.isAfter(now)) return true;
  return now.difference(lastCheck) >= every;
}

/// The release to offer, or null when there is nothing to offer.
///
/// Refuses more than it accepts, and each refusal is a case where telling
/// somebody they are out of date would be wrong:
///
/// * a build that cannot say what it is. `kAppVersion` falls back to `dev` when
///   `XVEIL_VERSION` was not passed, and a build with no version cannot be
///   SHOWN to be older than anything. Offering an update there means every
///   developer build nags on every launch.
/// * a tag this app cannot order. Same rule the node's release resolver
///   applies: an unrecognised shape is not evidence of anything.
/// * a release that is the same or older. GitHub's "latest" is whatever the
///   API says it is, and an API that can be made to answer with an old release
///   is one that can walk somebody backwards.
///
/// The build metadata is dropped before comparing: the running version arrives
/// as `0.13.3+11` from pubspec, and `+11` is not part of the ordering.
AppUpdate? newerRelease({
  required String running,
  required String latestTag,
  required String releaseUrl,
}) {
  final mine = VeilReleaseVersion.tryParse(running.split('+').first);
  if (mine == null) return null;
  final theirs = VeilReleaseVersion.tryParse(latestTag);
  if (theirs == null) return null;
  if (theirs.compareTo(mine) <= 0) return null;
  final url = releaseUrl.trim();
  if (!url.startsWith('https://')) return null;
  return AppUpdate(tag: latestTag.trim(), url: url);
}

/// Asks GitHub whether there is a newer xVeil, once and without side effects.
///
/// Deliberately thin: everything that decides anything is in [newerRelease] and
/// [shouldCheckForUpdate], which are pure. This part only fetches and reads
/// two fields, so a broken response is a refusal rather than a surprise.
///
/// `releases/latest` is the right endpoint and not just the convenient one: it
/// excludes drafts and pre-releases by definition, and this project's releases
/// are drafts until somebody publishes them on purpose. A draft must never be
/// offered to anyone.
class AppUpdateChecker {
  AppUpdateChecker({ReleaseTextFetcher? fetcher, required this.running})
    : _fetch = fetcher ?? fetchGithubText;

  static final latestReleaseUri = Uri.https(
    'api.github.com',
    '/repos/veilnetwork/xVeil/releases/latest',
  );

  /// The version of the build asking. See [newerRelease] for why a build that
  /// cannot name itself is never told it is old.
  final String running;

  final ReleaseTextFetcher _fetch;

  /// What the last look found. Never throws: a check nobody asked for must not
  /// turn a launch into an error.
  ///
  /// "Could not ask" and "nothing new" used to be the same answer — both null
  /// — and they are not the same thing to say. The screen reads this to decide
  /// between "up to date" and "could not check", and calling a failed request
  /// up to date is a statement about the release feed that nothing supports
  /// (report16 XV-15).
  Future<AppUpdateCheck> check() async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await _fetch(latestReleaseUri));
    } on Object {
      return const AppUpdateCheck.unreachable();
    }
    if (decoded is! Map<String, dynamic>) {
      return const AppUpdateCheck.unreachable();
    }
    // Answered, and the answer is "nothing for you": a draft, a pre-release,
    // or a tag that is not newer. The feed was reached either way.
    if (decoded['draft'] == true || decoded['prerelease'] == true) {
      return const AppUpdateCheck.upToDate();
    }
    final tag = decoded['tag_name'];
    final url = decoded['html_url'];
    if (tag is! String || url is! String) {
      return const AppUpdateCheck.unreachable();
    }
    final update = newerRelease(
      running: running,
      latestTag: tag,
      releaseUrl: url,
    );
    return update == null
        ? const AppUpdateCheck.upToDate()
        : AppUpdateCheck.found(update);
  }
}
