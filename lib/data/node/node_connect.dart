import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'ssh_client.dart' show SshResult;

enum NodeConnectFailure {
  invalidInvite,
  expired,
  certificate,
  unavailable,
  protocol,
  rejected,
  identityChanged,
}

/// Safe for diagnostics: never contains a URI, token, command or remote text.
class NodeConnectException implements Exception {
  const NodeConnectException(this.failure);
  final NodeConnectFailure failure;
  @override
  String toString() => 'NodeConnectException(${failure.name})';
}

String _random(int count) => base64UrlEncode(
  List.generate(count, (_) => Random.secure().nextInt(256)),
).replaceAll('=', '');

bool _token(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
    return false;
  }
  try {
    return base64UrlEncode(base64Url.decode('$value=')).replaceAll('=', '') ==
        value;
  } catch (_) {
    return false;
  }
}

Uri _endpoint(Object? value) {
  if (value is! String ||
      value.length > 1024 ||
      value.contains(RegExp(r'[\s\\]'))) {
    throw const NodeConnectException(NodeConnectFailure.invalidInvite);
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.port < 1 ||
      uri.port > 65535) {
    throw const NodeConnectException(NodeConnectFailure.invalidInvite);
  }
  return uri.replace(path: '');
}

class NodeConnectInvite {
  NodeConnectInvite._(this.endpoint, this.pin, this.token, this.expires);
  final Uri endpoint;
  final String pin;
  final String token;
  final DateTime expires;

  factory NodeConnectInvite.parse(String text, {DateTime? now}) {
    try {
      return _parse(text, now: now);
    } on NodeConnectException {
      rethrow;
    } catch (_) {
      throw const NodeConnectException(NodeConnectFailure.invalidInvite);
    }
  }

  static NodeConnectInvite _parse(String text, {DateTime? now}) {
    if (text.length > 4096) {
      throw const NodeConnectException(NodeConnectFailure.invalidInvite);
    }
    final uri = Uri.tryParse(text.trim());
    if (uri == null ||
        uri.scheme != 'xveil' ||
        uri.path != 'node' ||
        uri.hasAuthority ||
        uri.hasFragment ||
        uri.queryParametersAll.length != 5 ||
        !{
          'v',
          'endpoint',
          'pin',
          'token',
          'expires',
        }.every((key) => uri.queryParametersAll[key]?.length == 1)) {
      throw const NodeConnectException(NodeConnectFailure.invalidInvite);
    }
    final fields = uri.queryParameters;
    final timestamp = int.tryParse(fields['expires'] ?? '');
    if (fields['v'] != '1' ||
        !_token(fields['token']) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fields['pin'] ?? '') ||
        timestamp == null ||
        timestamp < 0 ||
        timestamp > 4102444800) {
      throw const NodeConnectException(NodeConnectFailure.invalidInvite);
    }
    final expires = DateTime.fromMillisecondsSinceEpoch(
      timestamp * 1000,
      isUtc: true,
    );
    final current = now ?? DateTime.now();
    if (!expires.isAfter(current)) {
      throw const NodeConnectException(NodeConnectFailure.expired);
    }
    if (expires.difference(current) > const Duration(minutes: 16)) {
      throw const NodeConnectException(NodeConnectFailure.invalidInvite);
    }
    return NodeConnectInvite._(
      _endpoint(fields['endpoint']),
      fields['pin']!,
      fields['token']!,
      expires,
    );
  }

  @override
  String toString() => 'NodeConnectInvite(redacted)';
}

/// Kept only in the active identity's encrypted per-node settings, never the
/// node catalog. Closing the helper/restarting it invalidates this capability.
class NodeConnectSession {
  NodeConnectSession({
    required this.endpoint,
    required this.pin,
    required this.token,
    required this.expires,
  });
  final Uri endpoint;
  final String pin;
  final String token;
  final DateTime expires;

  String encode() => jsonEncode({
    'endpoint': endpoint.toString(),
    'pin': pin,
    'token': token,
    'expires': expires.millisecondsSinceEpoch,
  });

  static NodeConnectSession? decode(String? raw) {
    try {
      if (raw == null || raw.length > 4096) return null;
      final value = jsonDecode(raw) as Map<String, dynamic>;
      if (!_token(value['token']) ||
          value['pin'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['pin']) ||
          value['expires'] is! int) {
        return null;
      }
      return NodeConnectSession(
        endpoint: _endpoint(value['endpoint']),
        pin: value['pin'],
        token: value['token'],
        expires: DateTime.fromMillisecondsSinceEpoch(
          value['expires'],
          isUtc: true,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'NodeConnectSession(redacted)';
}

class NodeConnectClient {
  NodeConnectClient({
    required this.endpoint,
    required this.pin,
    bool Function()? isCurrent,
  }) : _isCurrent = isCurrent ?? (() => true) {
    _http = HttpClient(context: SecurityContext(withTrustedRoots: false));
    _http.findProxy = (_) => 'DIRECT';
    _http.connectionTimeout = const Duration(seconds: 10);
    _http.badCertificateCallback = (certificate, host, port) {
      final matches =
          host == endpoint.host &&
          port == endpoint.port &&
          sha256.convert(certificate.der).toString() == pin;
      if (!matches) _pinRejected = true;
      return matches && _isCurrent();
    };
  }

  final Uri endpoint;
  final String pin;
  final bool Function() _isCurrent;
  late final HttpClient _http;
  bool _pinRejected = false;
  void close() => _http.close(force: true);
  void _guard() {
    if (!_isCurrent()) {
      throw const NodeConnectException(NodeConnectFailure.identityChanged);
    }
  }

  Future<Map<String, dynamic>> _request(
    String path,
    String token, [
    Map<String, Object>? body,
  ]) async {
    _guard();
    try {
      return await (() async {
        final request = await _http.openUrl(
          body == null ? 'GET' : 'POST',
          endpoint.replace(path: path),
        );
        _guard();
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        if (body != null) {
          final payload = utf8.encode(jsonEncode(body));
          request.headers.contentType = ContentType.json;
          request.contentLength = payload.length;
          request.add(payload);
        }
        final response = await request.close();
        _guard();
        // Empty trust store + callback pins BEFORE the Authorization header.
        // Also refuse any response whose actual peer certificate differs.
        if (response.certificate == null ||
            sha256.convert(response.certificate!.der).toString() != pin) {
          throw const NodeConnectException(NodeConnectFailure.certificate);
        }
        const limit = 3 * 1024 * 1024;
        if (response.contentLength > limit) {
          throw const NodeConnectException(NodeConnectFailure.protocol);
        }
        final bytes = <int>[];
        await for (final block in response) {
          _guard();
          if (bytes.length + block.length > limit) {
            throw const NodeConnectException(NodeConnectFailure.protocol);
          }
          bytes.addAll(block);
        }
        final data = jsonDecode(utf8.decode(bytes));
        if (data is! Map<String, dynamic> ||
            data['schema'] != 'xveil-node-connect/1') {
          throw const NodeConnectException(NodeConnectFailure.protocol);
        }
        if (response.statusCode != 200) {
          throw NodeConnectException(
            response.statusCode == 410
                ? NodeConnectFailure.expired
                : NodeConnectFailure.rejected,
          );
        }
        return data;
      })().timeout(const Duration(seconds: 15));
    } on NodeConnectException {
      rethrow;
    } catch (_) {
      throw NodeConnectException(
        _pinRejected
            ? NodeConnectFailure.certificate
            : NodeConnectFailure.unavailable,
      );
    }
  }

  Future<NodeConnectSession> claim(NodeConnectInvite invite) async {
    final clientId = _random(32);
    // Same nonce on retry: a lost response must not strand the first claimant.
    final data = await _retry(
      () => _request('/v1/claim', invite.token, {'client': clientId}),
    );
    final remaining = data['remaining_seconds'];
    if (!_token(data['session']) ||
        remaining is! int ||
        remaining <= 0 ||
        remaining > 900) {
      throw const NodeConnectException(NodeConnectFailure.protocol);
    }
    return NodeConnectSession(
      endpoint: endpoint,
      pin: pin,
      token: data['session'],
      expires: DateTime.now().add(Duration(seconds: remaining)),
    );
  }

  Future<Map<String, dynamic>> info(NodeConnectSession session) =>
      _request('/v1/info', session.token);

  Future<T> _retry<T>(Future<T> Function() request) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await request();
      } on NodeConnectException catch (error) {
        if (error.failure != NodeConnectFailure.unavailable || attempt >= 1) {
          rethrow;
        }
        _guard();
      }
    }
  }

  Future<SshResult> run(
    NodeConnectSession session,
    String script, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    _guard();
    if (!session.expires.isAfter(DateTime.now())) {
      throw const NodeConnectException(NodeConnectFailure.expired);
    }
    if (script.isEmpty ||
        script.contains('\u0000') ||
        utf8.encode(script).length > 128 * 1024 ||
        timeout.inMilliseconds <= 0 ||
        timeout > const Duration(minutes: 6)) {
      throw const NodeConnectException(NodeConnectFailure.protocol);
    }
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final body = <String, Object>{
      'id': id,
      'script': script,
      'timeout_ms': timeout.inMilliseconds,
    };
    final deadline = DateTime.now().add(timeout + const Duration(seconds: 35));
    var data = await _retry(() => _request('/v1/jobs', session.token, body));
    while (true) {
      _guard();
      if (data['id'] != id || data['done'] is! bool) {
        throw const NodeConnectException(NodeConnectFailure.protocol);
      }
      if (data['done'] == true) break;
      if (DateTime.now().isAfter(deadline)) {
        throw const NodeConnectException(NodeConnectFailure.unavailable);
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      data = await _retry(() => _request('/v1/jobs/$id', session.token));
    }
    try {
      String output(String key) {
        final encoded = data[key];
        if (encoded is! String || encoded.length > 1398104) {
          throw const FormatException();
        }
        final bytes = base64Decode(encoded);
        if (bytes.length > 1024 * 1024) throw const FormatException();
        return utf8.decode(bytes, allowMalformed: true);
      }

      final code = data['exit_code'];
      if (code is! int ||
          data['truncated'] is! bool ||
          data['timed_out'] is! bool ||
          data['cancelled'] is! bool) {
        throw const FormatException();
      }
      if ((data['timed_out'] == true || data['cancelled'] == true) &&
          code == 0) {
        throw const FormatException();
      }
      return SshResult(
        stdout: output('stdout_b64'),
        stderr: output('stderr_b64'),
        exitCode: code,
        hostFingerprint: '',
        truncated: data['truncated'],
      );
    } catch (_) {
      throw const NodeConnectException(NodeConnectFailure.protocol);
    }
  }
}
