import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The build entry points carry a distribution-safety decision.
///
/// `builder.py android --release` is where the signing check lives: the
/// difference between an APK a tester can be given and one that can never be
/// updated over. That check moved out of a shell script so it would also run
/// on Windows, which means a regression in this Python is a regression in
/// what gets handed to people — and nothing else in this repository would
/// notice.
///
/// These run the scripts in --dry-run, which executes nothing, so the suite
/// stays a suite. They assert the shape of the plan, not the wording of it.
void main() {
  final python = _python();

  group('build entry points', () {
    ProcessResult run(List<String> args) => Process.runSync(
      python!,
      args,
      workingDirectory: Directory.current.path,
    );

    test('EVERY platform names the version it was built as', () {
      // Written as one sweep over the targets rather than a line per platform,
      // because the per-platform version was exactly how three of them drifted:
      // android and macos were each asserted individually, and linux, ios and
      // windows shipped `dev` for as long as anyone had been looking.
      //
      // A build that cannot say what it is has two consequences, and the
      // second is the one that goes unnoticed: an error report ties to no
      // build, and the update check refuses to offer anything at all, because
      // a version it cannot order is not evidence that anybody is out of date.
      // The feature simply does nothing, quietly, on those hosts.
      for (final target in ['android', 'linux', 'ios', 'windows', 'macos']) {
        final plan = run(['builder.py', target, '--release', '--dry-run']);
        expect(plan.exitCode, 0, reason: '$target: ${plan.stderr}');
        final text = plan.stdout.toString();
        if (text.contains('build-macos-adhoc.sh')) {
          // A target may hand the build to a script. Then the script is what
          // has to name the version — excusing the branch because it delegates
          // is how a gap gets a comment written over it instead of a check.
          expect(
            File('scripts/build-macos-adhoc.sh').readAsStringSync(),
            contains('--dart-define=XVEIL_VERSION='),
            reason: 'the script the macOS plan delegates to drops the version',
          );
          continue;
        }
        expect(
          text,
          contains('XVEIL_VERSION=${_pubspecVersion()}'),
          reason: '$target builds an app that reports its version as "dev"',
        );
      }
    });

    test('and so does every branch this host cannot reach', () {
      // The sweep above only sees the branch the host takes. A signed iOS
      // build, a signed macOS bundle and the Windows plan pick different arms
      // on different machines, and a plan that is never printed here is a plan
      // nothing checks — which is the state the three broken platforms were
      // in.
      //
      // So this counts instead: every `flutter build` in the file against
      // every version define. Crude on purpose. It cannot say WHICH build lost
      // its version, but it cannot be satisfied by the branches that happen to
      // run on the machine running the suite.
      final source = File('builder.py').readAsStringSync();
      final builds = RegExp(r'"flutter",\s*\n?\s*"build"').allMatches(source);
      final defines = RegExp(
        '--dart-define=XVEIL_VERSION=',
      ).allMatches(source);

      expect(builds, isNotEmpty, reason: 'the build steps moved');
      expect(
        defines.length,
        builds.length,
        reason:
            'a flutter build with no XVEIL_VERSION ships an app that reports '
            'its version as "dev": the error report ties to no build, and the '
            'update check silently refuses to offer anything',
      );
    });

    test('an unknown target is refused, not guessed at', () {
      final result = run(['builder.py', 'nonsense', '--dry-run']);
      expect(result.exitCode, 2);
      expect(result.stderr.toString(), contains('unknown target'));
    });

    test('a target this host cannot build is refused BEFORE any work', () {
      // Written twice. The first version asserted only an exit code of 2 and
      // the word "host" somewhere in stderr — and removing the check did not
      // fail it, because the run then went ahead, built the native libraries,
      // and died in `flutter build linux` with an exit code of 2 and a message
      // that also says "host". Refusing late is the failure this guards
      // against, so the assertion has to be that nothing ran at all.
      final elsewhere = Platform.isMacOS ? 'linux' : 'macos';
      final result = run(['builder.py', elsewhere]);

      expect(result.exitCode, 2);
      expect(result.stderr.toString(), contains('needs a'));
      expect(
        result.stdout.toString(),
        isNot(contains('[1/')),
        reason:
            'the first step must never start — a twenty-minute native '
            'build before the refusal is the whole problem',
      );
    });

    test('...but a DRY run still shows its plan', () {
      // Deliberate: reviewing the Windows plan from a Mac is otherwise
      // impossible, and printing it executes nothing.
      final elsewhere = Platform.isMacOS ? 'windows' : 'macos';
      final result = run(['builder.py', elsewhere, '--dry-run']);
      expect(result.exitCode, 0);
      expect(result.stdout.toString(), contains('dry run'));
    });

    test('the android release plan keeps its two hard-won details', () {
      final result = run(['builder.py', 'android', '--release', '--dry-run']);
      expect(result.exitCode, 0);
      final plan = result.stdout.toString();

      expect(
        plan,
        contains('--split-per-abi'),
        reason: 'the universal APK is 136 MB against 33 MB for one ABI',
      );
      expect(
        plan,
        contains('android-arm64'),
        reason:
            'armeabi-v7a and x86_64 cannot carry the media engine, so they '
            'installed and then could not record a voice message or take a '
            'call — they are no longer built, let alone published',
      );
      expect(
        plan,
        contains('XVEIL_VERSION=${_pubspecVersion()}'),
        reason: 'a report saying "dev" cannot be tied to a build a tester has',
      );
      expect(
        plan,
        contains('signing check'),
        reason:
            'without it a debug-signed APK can be handed out, and an '
            'update can never be shipped over it',
      );
      expect(
        plan,
        contains('call media staged'),
        reason:
            'libveil_media.so is gitignored, so a fresh clone has none and '
            'the build goes green without it — v0.9.1 shipped that way',
      );
      expect(
        plan,
        contains('native libraries in the APKs'),
        reason:
            'the v0.9.1 pipeline was honestly green; only reading the APK '
            'itself can tell that what it produced can do its job',
      );
    });

    test('the APK check refuses an APK with no media engine', () {
      // The point of the check is that it FAILS on the artifact that shipped.
      // A check that only ever passes is why v0.9.1 was published at all, so
      // this builds that exact APK shape and requires a refusal.
      final temp = Directory.systemTemp.createTempSync('xveil_apk_check');
      addTearDown(() => temp.deleteSync(recursive: true));
      final repo = Directory.current.path;
      final probe = File('${temp.path}/probe.py')..writeAsStringSync('''
import sys, os, zipfile
sys.path.insert(0, ${_pyStr(repo)})
import builder
root = ${_pyStr(temp.path)}
apks = os.path.join(root, "build", "app", "outputs", "flutter-apk")
os.makedirs(apks, exist_ok=True)
# The one published APK, complete but for the media engine, so that is the ONLY
# defect left to refuse. When three ABIs were still published this had to build
# all three: with just one present the check refused because the OTHER TWO were
# missing, which passed just as happily with the media requirement removed.
abi = "arm64-v8a"
path = os.path.join(apks, "app-" + abi + "-release.apk")
with zipfile.ZipFile(path, "w") as z:
    z.writestr("lib/" + abi + "/libveilclient_ffi.so", "x")
    z.writestr("lib/" + abi + "/libhidden_volume_ffi.so", "x")
builder.ROOT = root
try:
    builder._check_android_native_libs()
    print("ACCEPTED")
except RuntimeError as error:
    print("REFUSED " + " | ".join(str(error).splitlines()[1:]))
''');
      final result = Process.runSync(python!, [probe.path]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(
        result.stdout.toString(),
        contains('arm64-v8a: missing libveil_media.so'),
        reason:
            'an APK that cannot record a voice message must not pass, and it '
            'has to be refused for THAT reason — a refusal that merely '
            'mentions arm64 survives deleting the media requirement',
      );
    });

    test('the windows plan refuses a bundle with no call engine', () {
      // Windows had NO engine at all until the veil_media windows/ port, and
      // nothing noticed: every zip through v0.9.1 started, looked healthy and
      // threw at the first voice message. The check has to FAIL on that shape,
      // not merely exist.
      final temp = Directory.systemTemp.createTempSync('xveil_win_engine');
      addTearDown(() => temp.deleteSync(recursive: true));
      final runner = 'build/windows/x64/runner/Release';
      Directory('${temp.path}/$runner').createSync(recursive: true);
      final probe = File('${temp.path}/probe.py')..writeAsStringSync('''
import sys, os
sys.path.insert(0, ${_pyStr(Directory.current.path)})
import builder
builder.ROOT = ${_pyStr(temp.path)}
runner = ${_pyStr(runner)}
try:
    builder._check_windows_engine(runner)
    print("ACCEPTED-EMPTY")
except RuntimeError as error:
    print("REFUSED " + str(error).splitlines()[0])
# ...and it accepts the bundle once the engine is there, so the check is a
# check and not a wall.
open(os.path.join(builder.ROOT, runner, "veil_media.dll"), "w").close()
try:
    builder._check_windows_engine(runner)
    print("ACCEPTED-WITH-ENGINE")
except RuntimeError as error:
    print("REFUSED-WITH-ENGINE " + str(error).splitlines()[0])
''');
      final result = Process.runSync(python!, [probe.path]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final out = result.stdout.toString();
      expect(out, contains('REFUSED MISSING veil_media.dll'));
      expect(out, contains('ACCEPTED-WITH-ENGINE'));
    });

    test('every step that compiles, on EVERY platform, carries the remap', () {
      // `_path_remap_env()` existed, was documented, and was attached to the
      // `flutter build apk` step only. That looked like the environment was
      // handled — but gradle does not build libhidden_volume_ffi.so (see the
      // comment on the first android step), so the one library the flutter
      // step cannot reach was also the one library nothing remapped. A release
      // APK built here carried 49 $HOME/.cargo paths inside it, one per panic
      // site in tokio, uniffi, argon2 and the rest, while the published APK
      // built on a runner carried none.
      //
      // Every platform, not only the one that was measured first: android was
      // fixed alone, and macOS, linux, ios and windows were then the same
      // defect sitting untouched — linux and windows worse than untouched,
      // because their flutter step DID carry an `env=` (the engine policy) and
      // so read as handled. Nothing about `env=` at a call site says which of
      // the two environments was meant.
      //
      // Asserted over EVERY argv step rather than by naming the ones that were
      // wrong: the defect is "a step that compiles was added without the
      // environment", so the next such step has to fail this too — on whichever
      // platform someone adds it to.
      final temp = Directory.systemTemp.createTempSync('xveil_remap');
      addTearDown(() => temp.deleteSync(recursive: true));
      final probe = File('${temp.path}/probe.py')..writeAsStringSync('''
import sys
sys.path.insert(0, ${_pyStr(Directory.current.path)})
import builder
# Both branches of the Apple ones, so the answer does not depend on whether
# THIS machine happens to have a provisioning profile — that is how the signed
# macOS branch went years without the debug-hook define.
for target in ("android", "linux", "macos", "ios", "windows"):
    plan = getattr(builder, "_" + target)
    for signing in (True, False):
        builder._apple_signing_available = lambda ok=signing: ok
        for step in plan(release=True):
            if not step.argv:
                continue
            rustflags = step.env.get("CARGO_BUILD_RUSTFLAGS", "")
            cxxflags = step.env.get("CXXFLAGS", "")
            ok = ("--remap-path-prefix=" in rustflags
                  and "-ffile-prefix-map=" in cxxflags)
            print(("REMAPPED " if ok else "BARE ") + target + ": " + step.title)
''');
      final result = Process.runSync(python!, [probe.path]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final lines = result.stdout.toString().split('\n');
      final bare = lines.where((line) => line.startsWith('BARE ')).toSet();
      expect(
        bare,
        isEmpty,
        reason:
            'these steps compile with no path remapping, so the builder\'s '
            'account name goes into what they produce: ${bare.join(' | ')}',
      );
      // A platform that contributed no argv steps would pass by checking
      // nothing, and `plan()` refusing a foreign target is exactly how that
      // could happen without anyone noticing.
      for (final target in ['android', 'linux', 'macos', 'ios', 'windows']) {
        expect(
          lines.any((line) => line.startsWith('REMAPPED $target:')),
          isTrue,
          reason: '$target contributed no steps at all to this check',
        );
      }
    });

    test('a debug android build does NOT claim to check signing', () {
      // The check belongs to the build that gets distributed. Running it on a
      // debug build would train people to ignore it.
      final result = run(['builder.py', 'android', '--debug', '--dry-run']);
      expect(result.exitCode, 0);
      expect(result.stdout.toString(), isNot(contains('signing check')));
    });

    test('a macOS stand build carries the hook on EITHER signing path', () {
      // The hook is compile-time, so a bundle built without the define cannot
      // be driven at all: nothing answers on the port and the stand looks like
      // a node that never bootstrapped. The ad-hoc script (no Apple account on
      // this machine) passed it through; the SIGNED branch never did. So the
      // machine with an Apple account produced the mute build, while the
      // comments in the Android and Linux branches said macOS already had it.
      //
      // Forced rather than observed: which branch runs depends on whether this
      // particular machine has a provisioning profile, and a test that asserts
      // whatever the host happens to do asserts nothing.
      final temp = Directory.systemTemp.createTempSync('xveil_macos_hook');
      addTearDown(() => temp.deleteSync(recursive: true));
      final probe = File('${temp.path}/probe.py')..writeAsStringSync('''
import sys
sys.path.insert(0, ${_pyStr(Directory.current.path)})
import builder
builder._apple_signing_available = lambda: True
for step in builder._macos(release=False):
    if step.argv[:3] == ["flutter", "build", "macos"]:
        print("SIGNED " + " ".join(step.argv))
builder._apple_signing_available = lambda: False
for step in builder._macos(release=False):
    print("ADHOC " + " ".join(step.argv))
''');
      ProcessResult probeWith(Map<String, String> env) => Process.runSync(
        python!,
        [probe.path],
        environment: env,
        workingDirectory: Directory.current.path,
      );

      final asked = probeWith({'XVEIL_DEBUG_HOOK': 'true'});
      expect(asked.exitCode, 0, reason: asked.stderr.toString());
      final signed = asked.stdout
          .toString()
          .split('\n')
          .firstWhere((line) => line.startsWith('SIGNED '), orElse: () => '');
      expect(
        signed,
        contains('--dart-define=XVEIL_DEBUG_HOOK=true'),
        reason:
            'XVEIL_DEBUG_HOOK=true builder.py macos --debug produced a mute '
            'stand on any machine with an Apple account',
      );
      expect(
        signed,
        contains('--dart-define=XVEIL_VERSION=${_pubspecVersion()}'),
        reason:
            'the ad-hoc script names the version; a signed bundle used to '
            'report as whatever the default is, which ties to no build',
      );
      // The ad-hoc branch reaches the script, which reads the same variable —
      // the pass-through is not duplicated into the argv here.
      expect(
        asked.stdout.toString(),
        contains('ADHOC bash'),
        reason: 'the ad-hoc path still goes through build-macos-adhoc.sh',
      );

      // ...and a build nobody asked for stays an ordinary build.
      final plain = probeWith({});
      expect(plain.exitCode, 0, reason: plain.stderr.toString());
      expect(
        plain.stdout.toString(),
        isNot(contains('XVEIL_DEBUG_HOOK')),
        reason:
            'the hook opens a loopback port that drives the whole app; it is '
            'opt-in per build, not on because the platform can',
      );
    });

    test('prepare names the target it prepares for', () {
      final result = run(['prepare.py', 'android', '--dry-run']);
      expect(result.exitCode, 0);
      expect(result.stdout.toString(), contains('target: android'));
    });
  }, skip: python == null ? 'no python3 on PATH' : null);
}

/// A path as a Python string literal. Windows paths carry backslashes, which
/// a bare quoted literal would read as escapes.
String _pyStr(String value) =>
    "'${value.replaceAll('\\', r'\\').replaceAll("'", r"\'")}'";

String? _python() {
  for (final candidate in ['python3', 'python']) {
    final result = Process.runSync(candidate, ['--version']);
    if (result.exitCode == 0) return candidate;
  }
  return null;
}

String _pubspecVersion() {
  for (final line in File('pubspec.yaml').readAsLinesSync()) {
    if (line.startsWith('version:')) return line.split(':')[1].trim();
  }
  fail('pubspec.yaml has no version');
}
