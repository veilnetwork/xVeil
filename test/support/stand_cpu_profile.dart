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

  void close() => _client.close(force: true);
}
