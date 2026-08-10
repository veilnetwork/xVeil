import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Android engine is built from the same gn arguments in two places: the
/// script a person runs on a Linux host, and the workflow that produces the
/// artifact everyone else downloads. The workflow's comment has always claimed
/// they are the same; nothing checked it, and they drifted — the workflow
/// gained `--export-compile-commands` while the script did not, and the comment
/// went on describing a state of affairs that had been fixed.
///
/// Drift here is expensive to notice: a wrong argument list still compiles
/// WebRTC for fifteen minutes before failing, and it fails in the Java tooling,
/// which looks like a broken runner rather than a missing flag.
Set<String> _gnArgs(String text, RegExp pattern) {
  final match = pattern.firstMatch(text);
  expect(match, isNotNull, reason: 'no gn args found — the file moved or the shape changed');
  return match!.group(1)!.split(RegExp(r'\s+')).where((a) => a.isNotEmpty).toSet();
}

void main() {
  test('the Android engine builds from one argument list, in both places', () async {
    final script = await File(
      'third_party/veil/flutter/veil_media/android/build_libwebrtc_android_linux.sh',
    ).readAsString();
    final workflow = await File('.github/workflows/webrtc-linux.yml').readAsString();

    final fromScript = _gnArgs(script, RegExp(r"^ARGS='([^']*)'", multiLine: true));
    final fromWorkflow = _gnArgs(
      workflow,
      RegExp(r"gn gen out/android-arm64 --export-compile-commands --args='([^']*)'"),
    );

    // Identity, not "both contain the important ones": a list that grows in one
    // place only is exactly the failure this exists to catch.
    expect(fromWorkflow, equals(fromScript));

    // Not an optimisation. WebRTC defaults this to "build_server", which hands
    // the Java lint/ErrorProne/bytecode checks to a daemon that exists only
    // under depot_tools' autoninja. Under plain ninja — which both of these
    // use — every *__validate_deps action dies on "AUTONINJA_BUILD_ID is not
    // set", after the whole native build has already been compiled.
    expect(fromScript, contains('android_static_analysis="off"'));

    // Guards the parse itself: if the regex ever matched something that is not
    // an argument list, the two comparisons above could both pass on nonsense.
    expect(fromScript, contains('target_os="android"'));
    expect(fromScript.length, greaterThan(10));
  });
}
