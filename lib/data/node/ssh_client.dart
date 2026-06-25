import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// How to authenticate an SSH connection. The secret is held only for the
/// duration of one call — it is NOT persisted (a leaked node registry must never
/// leak an SSH credential).
enum SshAuthKind { password, key }

class SshAuth {
  const SshAuth.password(this.secret)
      : kind = SshAuthKind.password,
        passphrase = null;
  const SshAuth.key(this.secret, {this.passphrase}) : kind = SshAuthKind.key;

  final SshAuthKind kind;

  /// A password, or a PEM-encoded private key.
  final String secret;

  /// Optional passphrase for an encrypted private key.
  final String? passphrase;
}

class SshResult {
  const SshResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.hostFingerprint,
  });
  final String stdout;
  final String stderr;
  final int? exitCode;

  /// The server's `SHA256:…` host-key fingerprint observed on THIS connection.
  /// The caller pins it (trust-on-first-use) and passes it back as
  /// [sshRun]'s `expectedHostFingerprint` on later connects, and/or shows it to
  /// the user to verify out-of-band.
  final String hostFingerprint;
  bool get ok => exitCode == 0;
}

class SshException implements Exception {
  const SshException(this.message);
  final String message;
  @override
  String toString() => 'SshException: $message';
}

/// Open an SSH connection, run [command], and return its stdout/stderr/exit
/// code. Single-shot: connects, runs, disconnects. Throws [SshException] on any
/// connect/auth/transport failure (never leaks the underlying error type).
///
/// Host-key verification: when [expectedHostFingerprint] (a `SHA256:…` string)
/// is given, the connection is REFUSED unless the server presents exactly that
/// key — defeating a man-in-the-middle that would otherwise transparently proxy
/// the session and capture the SSH password / run arbitrary commands. When it is
/// null (first contact) the key is accepted trust-on-first-use and surfaced via
/// [SshResult.hostFingerprint] so the caller can pin it for next time and show
/// it to the user to verify out-of-band. dartssh2 verifies the key SIGNATURE
/// against the presented host key independently; this adds the identity pin on
/// top, which is what stops MITM.
Future<SshResult> sshRun({
  required String host,
  required int port,
  required String user,
  required SshAuth auth,
  required String command,
  String? expectedHostFingerprint,
  Duration timeout = const Duration(seconds: 30),
}) async {
  SSHClient? client;
  // Populated by onVerifyHostKey during the handshake (fires before execute).
  String observedFingerprint = '';
  var pinMismatch = false;
  try {
    final socket = await SSHSocket.connect(host, port, timeout: timeout);
    final identities = auth.kind == SshAuthKind.key
        ? SSHKeyPair.fromPem(auth.secret, auth.passphrase)
        : null;
    client = SSHClient(
      socket,
      username: user,
      identities: identities,
      onPasswordRequest:
          auth.kind == SshAuthKind.password ? () => auth.secret : null,
      // dartssh2 hands us the standard "SHA256:<base64>" fingerprint of the
      // server's host key. Without this callback the library accepts ANY key.
      onVerifyHostKey: (type, fingerprint) {
        observedFingerprint = utf8.decode(fingerprint);
        if (expectedHostFingerprint == null) return true; // trust-on-first-use
        // The fingerprint is public, so a plain compare leaks nothing sensitive.
        final ok = observedFingerprint == expectedHostFingerprint;
        if (!ok) pinMismatch = true;
        return ok;
      },
    );
    final session = await client.execute(command);
    final outF = session.stdout
        .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
    final errF = session.stderr
        .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
    final collected = await Future.wait([outF, errF]).timeout(timeout);
    await session.done.timeout(timeout);
    return SshResult(
      stdout: utf8.decode(collected[0].takeBytes(), allowMalformed: true),
      stderr: utf8.decode(collected[1].takeBytes(), allowMalformed: true),
      exitCode: session.exitCode,
      hostFingerprint: observedFingerprint,
    );
  } on SshException {
    rethrow;
  } on TimeoutException {
    throw const SshException('timed out');
  } catch (e) {
    // A pin mismatch surfaces as a generic handshake failure from the library;
    // give the user the unambiguous reason instead, so a changed host key reads
    // as the security event it is rather than a flaky connection.
    if (pinMismatch) {
      throw SshException(
        'host key mismatch — possible MITM. expected $expectedHostFingerprint, '
        'server presented $observedFingerprint',
      );
    }
    throw SshException('$e');
  } finally {
    client?.close();
  }
}
