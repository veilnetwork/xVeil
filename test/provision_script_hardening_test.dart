import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_provisioner.dart';

/// The provisioning script stages a deployment obfs4 PSK, a TLS private key,
/// a systemd unit and the node config in a temp directory, then hands each to
/// `sudo install`. It used to do that at fixed `/tmp/xveil-*` names under the
/// login umask.
///
/// On a server with more than one account that is three problems at once:
/// another local user can read the PSK and the TLS key during the window
/// before install moves them; it can pre-create or symlink any of those names
/// and have a root-privileged install follow it; and cleanup ran only on the
/// success path, so a failed run left the secrets behind.
void main() {
  String script() => buildProvisionScript(
    const NodeProvisionConfig(
      releaseUrl: 'https://example.com/releases/veil-cli-x86_64-linux-musl',
      expectedSha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      obfs4PskB64: 'dGVzdC1maXh0dXJlLXBzay1ub3QtcmVhbC12YWx1ZSE=',
    ),
  );

  test('nothing is staged at a guessable path', () {
    // Comments are stripped first: the script's own preamble explains what it
    // replaced, and matching that prose would make this pass or fail on the
    // wording rather than on what the shell actually runs.
    final commands = script()
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('#'))
        .join('\n');
    expect(
      commands,
      isNot(contains('/tmp/')),
      reason: 'a fixed name under /tmp is a name an attacker can occupy first',
    );
  });

  test('the scratch directory is private, unguessable and always removed', () {
    final s = script();
    expect(s, contains('umask 077'));
    expect(s, contains(r'XVEIL_TMP="$(mktemp -d)"'));
    expect(
      s,
      contains(r'''trap 'rm -rf -- "$XVEIL_TMP"' EXIT INT TERM'''),
      reason:
          'cleanup on success only leaves the PSK and the TLS key on disk '
          'exactly when the run went wrong',
    );
  });

  test('the umask is set before anything is written', () {
    final s = script();
    expect(
      s.indexOf('umask 077'),
      lessThan(s.indexOf('mktemp -d')),
      reason: 'a directory created before the umask keeps the login mode',
    );
    expect(
      s.indexOf('mktemp -d'),
      lessThan(s.indexOf('PSK_EOF')),
      reason: 'the PSK must not be written before the private dir exists',
    );
  });
}
