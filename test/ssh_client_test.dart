import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/ssh_client.dart';

void main() {
  test('SshAuth holds the secret only in memory', () {
    const p = SshAuth.password('hunter2');
    expect(p.kind, SshAuthKind.password);
    expect(p.secret, 'hunter2');
    const k = SshAuth.key('-----BEGIN-----', passphrase: 'pp');
    expect(k.kind, SshAuthKind.key);
    expect(k.passphrase, 'pp');
  });

  test('SshResult.ok reflects the exit code', () {
    expect(
        const SshResult(stdout: '', stderr: '', exitCode: 0, hostFingerprint: '')
            .ok,
        isTrue);
    expect(
        const SshResult(
                stdout: '', stderr: 'x', exitCode: 1, hostFingerprint: '')
            .ok,
        isFalse);
    expect(
        const SshResult(
                stdout: '', stderr: '', exitCode: null, hostFingerprint: '')
            .ok,
        isFalse);
  });

  test('sshRun throws a typed SshException on an unreachable host', () async {
    // Bind+release a loopback port so nothing is listening on it.
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    expect(
      () => sshRun(
        host: '127.0.0.1',
        port: port,
        user: 'nobody',
        auth: const SshAuth.password('x'),
        command: 'true',
        timeout: const Duration(seconds: 3),
      ),
      throwsA(isA<SshException>()),
    );
  });
}
