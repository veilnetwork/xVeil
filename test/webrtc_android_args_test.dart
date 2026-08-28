import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Android engine is built from the same gn arguments in two places, and
/// this test exists because they drifted once already: the workflow gained
/// `--export-compile-commands` while the script did not, and the comment went
/// on describing a state of affairs that had been fixed.
///
/// One of those two places has MOVED. `webrtc-linux.yml` no longer runs `gn`
/// at all — it downloads a prebuilt WebRTC bundle from
/// veilnetwork/libwebrtc-builds, and the arguments that bundle was configured
/// with are recorded in its manifest as `gn_args`. The workflow pins the
/// expected value in `WEBRTC_GN_ARGS_ANDROID` and compares it against the real
/// manifest at fetch time, before anything is compiled.
///
/// The duplication therefore did not go away, it changed shape:
/// `build_libwebrtc_android_linux.sh` is still what a person runs on a Linux
/// host to build WebRTC from source, and if its arguments and the bundle's
/// diverge, a locally built engine and the one CI publishes stop being the
/// same engine — silently, because both link and both load.
///
/// So this compares the script against the pinned expectation, and the
/// workflow compares the pinned expectation against the bundle. Between them
/// the script, the pin and the published artefact are one list.
///
/// Drift here is still expensive to notice: a wrong argument list compiles
/// WebRTC for fifteen minutes before failing, and it fails in the Java tooling,
/// which looks like a broken runner rather than a missing flag.

/// `key = value` (gn's own normalised form, which the manifest carries) and
/// `key=value` (how a command line spells it) are the same argument. Compare
/// the pairs, not the punctuation.
Set<String> _args(String text, RegExp pattern, String what) {
  final match = pattern.firstMatch(text);
  expect(match, isNotNull, reason: 'no gn args found in $what — it moved or the shape changed');
  return match!
      .group(1)!
      .replaceAll(RegExp(r'\s*=\s*'), '=')
      .split(RegExp(r'\s+'))
      .where((a) => a.isNotEmpty)
      .toSet();
}

void main() {
  test('the Android engine builds from one argument list, in both places', () async {
    final script = await File(
      'third_party/veil/flutter/veil_media/android/build_libwebrtc_android_linux.sh',
    ).readAsString();
    final workflow = await File('.github/workflows/webrtc-linux.yml').readAsString();

    final fromScript = _args(
      script,
      RegExp(r"^ARGS='([^']*)'", multiLine: true),
      'build_libwebrtc_android_linux.sh',
    );
    final pinned = _args(
      workflow,
      RegExp(r"^  WEBRTC_GN_ARGS_ANDROID: '([^']*)'", multiLine: true),
      'webrtc-linux.yml',
    );

    // Identity, not "both contain the important ones": a list that grows in one
    // place only is exactly the failure this exists to catch.
    expect(pinned, equals(fromScript));

    // Not an optimisation. WebRTC defaults this to "build_server", which hands
    // the Java lint/ErrorProne/bytecode checks to a daemon that exists only
    // under depot_tools' autoninja. Under plain ninja — which the local script
    // uses — every *__validate_deps action dies on "AUTONINJA_BUILD_ID is not
    // set", after the whole native build has already been compiled.
    expect(fromScript, contains('android_static_analysis="off"'));

    // The flag the original drift was about. The workflow no longer passes it,
    // because it no longer runs gn: the bundle ships the compile_commands.json
    // that flag produces, and the workflow asserts it carries call/call.cc.
    // The local script still has to ask for it, and build_veil_media_so.sh
    // still refuses to start without the file.
    //
    // Asserted on the `gn gen` INVOCATION rather than on the file, because the
    // script also explains the flag in a comment three lines above the command.
    // A whole-file `contains` is satisfied by that comment on its own, so
    // deleting the flag from the line that runs — while leaving the paragraph
    // saying it is load-bearing — passed. Break-checked: it now fails.
    final gnGen = RegExp(r'^gn gen .*$', multiLine: true).firstMatch(script);
    expect(gnGen, isNotNull,
        reason: 'no `gn gen` invocation in the script — it moved or changed shape');
    expect(gnGen!.group(0), contains('--export-compile-commands'));

    // Guards the parse itself: if a regex ever matched something that is not an
    // argument list, the comparison above could pass on nonsense.
    expect(fromScript, contains('target_os="android"'));
    expect(fromScript.length, greaterThan(10));
  });

  /// The three Android ABIs build from ONE list, one argument apart.
  ///
  /// Each ABI's expectation is spelled out in the workflow rather than derived
  /// from the others, because it is what a published bundle is COMPARED
  /// against: an expectation generated from the same rule as the bundle would
  /// agree by construction, and agreeing is the whole thing being checked.
  ///
  /// Spelled out means it can drift. A flag added for arm64 and forgotten for
  /// x86_64 compiles WebRTC for fifteen minutes before failing, in the Java
  /// tooling, which looks like a broken runner rather than a missing flag —
  /// so the difference between the lists is held to exactly `target_cpu`.
  test('the three Android ABIs differ in target_cpu and nothing else', () async {
    final workflow =
        await File('.github/workflows/webrtc-linux.yml').readAsString();

    Set<String> pinned(String name) => _args(
      workflow,
      RegExp("^  $name: '([^']*)'", multiLine: true),
      '$name in webrtc-linux.yml',
    );

    const wanted = <String, String>{
      'WEBRTC_GN_ARGS_ANDROID': 'arm64',
      'WEBRTC_GN_ARGS_ANDROID_ARM': 'arm',
      'WEBRTC_GN_ARGS_ANDROID_X64': 'x64',
    };

    for (final entry in wanted.entries) {
      expect(
        pinned(entry.key),
        contains('target_cpu="${entry.value}"'),
        reason: '${entry.key} does not build for ${entry.value} — the name '
            'and the argument list disagree about which ABI this is',
      );
    }

    // Every pair, compared as sets: what differs must be the two target_cpu
    // arguments and nothing besides.
    final names = wanted.keys.toList();
    for (var i = 0; i < names.length; i++) {
      for (var j = i + 1; j < names.length; j++) {
        final a = pinned(names[i]);
        final b = pinned(names[j]);
        final only = a.difference(b).union(b.difference(a));
        expect(
          only,
          {'target_cpu="${wanted[names[i]]}"', 'target_cpu="${wanted[names[j]]}"'},
          reason: '${names[i]} and ${names[j]} differ by more than the cpu: '
              '$only',
        );
      }
    }
  });
}
