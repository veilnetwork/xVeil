import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

// testWidgets substitutes a client returning 400 for every request. Bypass
// that override only for this loopback-only VM-service client, never globally.
class _StandHttpOverrides extends HttpOverrides {}

/// Opt-in CPU evidence for synthetic process stands only. This file is never
/// imported by the app or its diagnostic exporter. Profiles contain private
/// isolate/function metadata; keep the destination with the stand's raw logs.
class StandCpuProfile {
  final HttpClient _client = HttpOverrides.runWithHttpOverrides(
    () => HttpClient()..connectionTimeout = const Duration(seconds: 10),
    _StandHttpOverrides(),
  );
  Uri? _service;
  int? _origin;

  bool get hasWindow => _origin != null;

  Future<Map<String, dynamic>> _rpc(
    String method, [
    Map<String, String> parameters = const {},
  ]) async {
    _service ??= (await developer.Service.controlWebServer(
      enable: true,
      silenceOutput: true,
    )).serverUri;
    final base = _service;
    if (base == null || !base.host.startsWith('127.')) {
      throw StateError('stand profiler needs a local VM service');
    }
    final request = await _client.getUrl(
      base.resolve(method).replace(queryParameters: parameters),
    );
    final response = await request.close();
    final decoded = jsonDecode(await utf8.decodeStream(response)) as Map;
    if (decoded['error'] != null) {
      throw StateError(
        'stand profiler RPC $method failed: ${decoded['error']}',
      );
    }
    return Map<String, dynamic>.from(decoded['result'] as Map);
  }

  // Shared only by private stand tooling; never imported by the application.
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, String> parameters = const {},
  ]) => _rpc(method, parameters);

  Future<void> reset() async {
    await _rpc('setFlag', {'name': 'profile', 'value': 'true'});
    final vm = await _rpc('getVM');
    for (final isolate in vm['isolates'] as List) {
      await _rpc('clearCpuSamples', {'isolateId': isolate['id'] as String});
    }
    _origin = (await _rpc('getVMTimelineMicros'))['timestamp'] as int;
  }

  Future<Map<String, dynamic>> snapshot() async {
    final origin = _origin;
    if (origin == null) throw StateError('stand profiler was not reset');
    final end = (await _rpc('getVMTimelineMicros'))['timestamp'] as int;
    final vm = await _rpc('getVM');
    return {
      'schema': 'xveil-private-stand-cpu/1',
      'originMicros': origin,
      'endMicros': end,
      'isolates': [
        for (final isolate in vm['isolates'] as List)
          {
            'name': isolate['name'],
            'samples': await _rpc('getCpuSamples', {
              'isolateId': isolate['id'] as String,
              'timeOriginMicros': '$origin',
              'timeExtentMicros': '${end - origin}',
            }),
          },
      ],
    };
  }

  /// Local control capability for an external, private stand sampler. Never
  /// include this file in an application diagnostic artifact or public report.
  /// The caller owns a private evidence directory; one file is scoped to one
  /// worker PID so restarts cannot silently switch an existing capture.
  Future<void> writeEndpointWitness(File file) async {
    final service = _service;
    if (service == null || service.host != '127.0.0.1' || _origin == null) {
      throw StateError('stand profiler needs an initialized loopback endpoint');
    }
    final pending = File('${file.path}.new');
    await pending.writeAsString(
      jsonEncode({
        'schema': 'xveil-private-cpu-endpoint/1',
        'pid': pid,
        'uri': service.toString(),
        'originMicros': _origin,
      }),
    );
    await pending.rename(file.path);
  }

  void close() => _client.close(force: true);
}
