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
  });
  final String stdout;
  final String stderr;
  final int? exitCode;
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
Future<SshResult> sshRun({
  required String host,
  required int port,
  required String user,
  required SshAuth auth,
  required String command,
  Duration timeout = const Duration(seconds: 30),
}) async {
  SSHClient? client;
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
    );
  } on SshException {
    rethrow;
  } on TimeoutException {
    throw const SshException('timed out');
  } catch (e) {
    throw SshException('$e');
  } finally {
    client?.close();
  }
}
