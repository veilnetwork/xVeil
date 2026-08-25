import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/main.dart';

/// `no_subprocess_on_mobile_paths_test` allows `veil_node.dart` to spawn a
/// process and gives the reason: the veil-cli binary "only exists on the
/// desktop config-file dev path (XVEIL_VEIL_CLI); mobile boots the node
/// in-process". That file says of its own list: "A new entry here is a claim
/// about reachability — make it true."
///
/// It was not true. Two environment variables were the whole condition on that
/// branch, with no platform guard anywhere between them and the subprocess
/// launcher (report12 X-L5). On iOS a binary cannot be spawned at all, so what
/// a phone got out of trying was a half-started runtime.
void main() {
  test('the config-file dev boot is desktop-only', () {
    for (final (name, isMacOS, isLinux, isWindows) in const [
      ('macOS', true, false, false),
      ('Linux', false, true, false),
      ('Windows', false, false, true),
    ]) {
      expect(
        configFileDevBootAllowed(
          isMacOS: isMacOS,
          isLinux: isLinux,
          isWindows: isWindows,
        ),
        isTrue,
        reason: '$name is where this path is used and must keep working',
      );
    }

    expect(
      configFileDevBootAllowed(
        isMacOS: false,
        isLinux: false,
        isWindows: false,
      ),
      isFalse,
      reason:
          'a phone must not reach the subprocess launcher, whatever its '
          'environment says — which is what the allowlist elsewhere claims',
    );
  });
}
