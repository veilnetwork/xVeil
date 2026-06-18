import 'dart:async';
import 'dart:io';

/// Result of a reachability probe against a managed node's host:port.
enum ProbeResult { reachable, unreachable }

/// Best-effort TCP reachability check — opens a connection to [host]:[port] and
/// closes it immediately. Confirms the server is up and accepting connections
/// on that port (e.g. SSH), WITHOUT authenticating or sending anything. A
/// dependency-free stand-in for full SSH status until the provisioning layer
/// lands; never throws (returns [ProbeResult.unreachable] on any failure).
Future<ProbeResult> probeTcp(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  Socket? sock;
  try {
    sock = await Socket.connect(host, port, timeout: timeout);
    return ProbeResult.reachable;
  } catch (_) {
    return ProbeResult.unreachable;
  } finally {
    try {
      sock?.destroy();
    } catch (_) {/* already gone */}
  }
}
