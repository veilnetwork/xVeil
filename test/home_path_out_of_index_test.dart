import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The builder's account name must never reach the index.
///
/// This is the requirement that outranks the binaries. An artifact carrying a
/// home path is something its owner chooses to hand out; a home path committed
/// to a tracked file is in the history permanently, is public the moment the
/// repository is, and cannot be taken back by rebuilding anything. So it gets
/// a gate rather than care — care protects the commit somebody is thinking
/// about, and a gate protects every commit after this one.
///
/// WHAT IS MATCHED, and why it is not the generic pattern.
///
/// The obvious gate is "does any tracked file contain something home-path
/// shaped" — `(/Users/|/home/|C:\Users\)…`. Measured against this tree, that
/// matches 25 tracked files: `/home/docs` and `/home/u/sync` in the folder-sync
/// tests, `alice` and `someone` in the error-report tests, `/home/runner` in
/// two workflows, `<user>` in a submodule's cargo config, and so on. Every one
/// is a deliberate placeholder. A gate that starts red is a gate somebody
/// silences with an allow-list, and an allow-list is where the next real leak
/// hides — which is exactly the failure mode the artifact step was designed
/// away from too.
///
/// So this asks the precise question instead: does any tracked file contain
/// the home path of the account running the suite. Zero false positives by
/// construction, nothing to allow-list, and it fires on the machine where the
/// commit is being made — which is the only machine that can leak that name.
///
/// WHAT IS DELIBERATELY NOT MATCHED: the bare account name. In one macOS
/// binary in this tree the letters of this account occur 17 times, and sixteen
/// of them are a word in the translation table and a BoringSSL constant-time
/// symbol suffix. A gate on the bare name would be red for reasons that have
/// nothing to do with anyone's home directory. scripts/scan-artifacts.py says
/// the same thing at length about artifacts — and deliberately quotes no real
/// example, because a version of it that did flagged itself. This is the index
/// half of that. There is a test below that holds the line, so the gate cannot
/// later be "tightened" into uselessness.
///
/// The account name is derived from the environment at run time and appears
/// nowhere in this file — putting it in the source to test for it would be the
/// leak.
///
/// WHY THE TREE SCAN STEPS ASIDE ON A CI RUNNER, and only there.
///
/// The note above lists `/home/runner` in two workflows among the deliberate
/// placeholders the generic pattern would trip over. On a GitHub runner the
/// account running this suite IS `runner`, so `/home/runner/` is precisely the
/// form this gate looks for, and release.yml names it on purpose — in the
/// comment explaining that a CI build does NOT carry the builder's home. The
/// gate found its own documentation and failed the release for it.
///
/// A shared, ephemeral build account has no home path worth protecting: it is
/// published in the runner documentation and appears in every log. The
/// question this gate asks is meaningful only where a PERSON commits, which is
/// also the only machine that can leak that person's name. So on a recognised
/// CI account the tree scan is skipped WITH ITS REASON PRINTED, and the
/// matcher tests below still run, because they need no tree.
///
/// Recognition is narrow on purpose — an explicit account name AND `CI` set —
/// so it cannot become a way to switch the gate off. `_isSharedCiAccount` is
/// asserted both ways below.
void main() {
  group("the builder's home path", () {
    final home = _homeDirectory();
    final account = home == null ? null : _lastSegment(home);

    test('is derivable, or this gate cannot do its job', () {
      // Not skipped when it cannot answer. A security gate that goes quiet is
      // indistinguishable from one that passed, and "63 skipped" is a list of
      // things nobody checked.
      expect(
        home,
        isNotNull,
        reason: 'neither HOME nor USERPROFILE is set, so this gate cannot '
            'know what it is looking for',
      );
      expect(
        account,
        isNotNull,
        reason: 'HOME has no final path segment to take an account name from',
      );
      expect(account, isNot(isEmpty));
    });

    test('appears in no tracked file, in this repo or either submodule', () {
      if (_isSharedCiAccount(account!, onCi: _onCi())) {
        // Not silence: the reason travels with the skip, so a reader of the
        // run sees WHY this did not run rather than a blank.
        markTestSkipped(
          'running as the shared CI account "$account", whose home path is '
          'public and is named on purpose in release.yml. This gate guards a '
          "person's home path and only a developer machine can leak one.",
        );
        return;
      }

      final forms = _homePathForms(account);
      final tracked = _trackedFiles();

      // The file list itself is an assertion. `git ls-files` returning nothing
      // — no git, no repository, a working directory somewhere unexpected —
      // would otherwise make this pass by scanning zero bytes, which is how a
      // gate quietly stops guarding anything.
      expect(
        tracked.length,
        greaterThan(500),
        reason: 'only ${tracked.length} tracked files found; this gate is not '
            'looking at the repository it thinks it is',
      );

      final offenders = <String>[];
      for (final relative in tracked) {
        final file = File(relative);
        if (!file.existsSync()) continue; // submodule not checked out; symlink
        final String text;
        try {
          text = latin1.decode(file.readAsBytesSync(), allowInvalid: true);
        } on FileSystemException {
          continue;
        }
        for (final form in forms) {
          if (text.contains(form)) {
            offenders.add(relative);
            break;
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'these tracked files contain this account\'s home directory '
            'path. It must not be committed — derive it at run time the way '
            'builder.py does, or use a placeholder: ${offenders.join(', ')}',
      );
    });

    test('would be caught if it were planted', () {
      // The gate's matcher, exercised against content rather than against the
      // tree — so this stays honest without anything being written into a
      // tracked file. A gate nobody has seen go red is a gate nobody knows
      // works.
      final forms = _homePathForms(account!);
      const shapes = [
        '/Users/%s/Projects/veilnetwork/xVeil/lib/main.dart',
        '/home/%s/xVeil/build/app',
        r'C:\Users\%s\src\xVeil\',
      ];
      for (final shape in shapes) {
        final planted = shape.replaceAll('%s', account);
        expect(
          forms.any(planted.contains),
          isTrue,
          reason: 'a home path spelled "$shape" would slip past this gate',
        );
      }
    });

    test('steps aside for a build account, and for nothing else', () {
      // The escape hatch, held to its width. If this ever widens — a bare
      // `CI` check, a name like "build", an env var — the gate can be turned
      // off by the environment and nobody would see it happen.
      expect(_isSharedCiAccount('runner', onCi: true), isTrue);
      expect(_isSharedCiAccount('root', onCi: true), isTrue);

      // A person's account is never a build account, on CI or off it. The
      // names here are the placeholders this repository already uses in its
      // fixtures, so no real one is written down.
      for (final person in const ['alice', 'someone', 'u', 'docs']) {
        expect(_isSharedCiAccount(person, onCi: true), isFalse,
            reason: '"$person" is a person, and CI is not a reason to stop '
                'looking for a person\'s home path');
        expect(_isSharedCiAccount(person, onCi: false), isFalse);
      }

      // And off CI, not even the build names excuse it: a developer whose
      // account happens to be called `runner` still gets the full scan.
      expect(_isSharedCiAccount('runner', onCi: false), isFalse);
      expect(_isSharedCiAccount('root', onCi: false), isFalse);
    });

    test('is not confused with the bare account name inside an identifier', () {
      // The trap that made a whole-name scan unusable: a four-letter handle is
      // a substring of ordinary identifiers. If someone ever "strengthens"
      // this gate into matching the name alone, this goes red and says why.
      final forms = _homePathForms(account!);
      final innocent = [
        'ecp_nistz256_scalar_to_montgomery_inv_${account}time',
        'k${account}al',
        'package:xveil/features/home/home_shell.dart',
        'import \'../home/home_section_scaffold.dart\';',
      ];
      for (final text in innocent) {
        expect(
          forms.any(text.contains),
          isFalse,
          reason: '"$text" is not a home path and must not be treated as one',
        );
      }
    });
  });
}

String? _homeDirectory() {
  final environment = Platform.environment;
  final home = environment['HOME'] ?? environment['USERPROFILE'];
  if (home == null || home.trim().isEmpty) return null;
  return home.trim();
}

String? _lastSegment(String path) {
  final parts = path
      .split(RegExp(r'[/\\]'))
      .where((part) => part.isNotEmpty)
      .toList();
  return parts.isEmpty ? null : parts.last;
}

/// Whether this suite is running as a shared build account rather than as a
/// person.
///
/// Deliberately narrow, and BOTH conditions are required. The account names
/// are the ones GitHub-hosted and container runners actually use; `CI` alone
/// would let any environment switch the gate off, and the name alone would
/// excuse a developer whose account is called `root`.
bool _isSharedCiAccount(String account, {required bool onCi}) =>
    onCi && const {'runner', 'runneradmin', 'root'}.contains(account);

bool _onCi() {
  final ci = Platform.environment['CI'];
  return ci == 'true' || ci == '1';
}

/// The three spellings a home directory has, as a PATH — never the bare name.
List<String> _homePathForms(String account) => [
      '/Users/$account/',
      '/home/$account/',
      'C:\\Users\\$account\\',
    ];

/// Every file git is tracking here, submodules included.
///
/// Asked of git rather than walked: a walk would have to reimplement
/// .gitignore, and the whole question is what is IN the index — `build/`,
/// `.dart_tool/` and the artifacts under them are full of this path by design
/// and are not tracked.
List<String> _trackedFiles() {
  final result = Process.runSync(
    'git',
    ['ls-files', '-z', '--recurse-submodules'],
    workingDirectory: Directory.current.path,
    stdoutEncoding: null,
  );
  if (result.exitCode != 0) {
    return const [];
  }
  return latin1
      .decode(result.stdout as List<int>)
      .split('\u0000')
      .where((entry) => entry.isNotEmpty)
      .toList();
}
