import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'stand_cpu_profile.dart';

typedef StandVmRequest =
    Future<Map<String, dynamic>> Function(
      String method, [
      Map<String, String> parameters,
    ]);

/// Private, opt-in VM evidence for a synthetic stand. No application imports.
/// HandleMessage spans include native work AND the Dart worker adapter; they
/// must never be reported as a pure native/disk/fsync measurement.
class StandStorageTimeline {
  StandStorageTimeline._(
    this._request,
    this._closeClient,
    this._sink,
    this._originalStreams,
    int origin,
    List<String> workers,
    this._eventLimit,
    this._byteLimit,
  ) : _origin = origin,
      _initialOrigin = origin,
      _workers = workers.toSet();

  static Future<StandStorageTimeline> open(File destination) {
    final client = StandCpuProfile();
    return withClient(destination, client.request, client.close).then((
      capture,
    ) {
      capture.startPolling();
      return capture;
    });
  }

  // Test-only VM seam, kept outside the product's dependency graph.
  static Future<StandStorageTimeline> withClient(
    File destination,
    StandVmRequest request,
    void Function() closeClient, {
    int eventLimit = maxEvents,
    int byteLimit = maxBytes,
  }) async {
    if (eventLimit < 1 ||
        eventLimit > maxEvents ||
        byteLimit < 1 ||
        byteLimit > maxBytes) {
      throw ArgumentError('invalid private timeline budget');
    }
    List<String>? original;
    var changed = false;
    try {
      final flags = await request('getVMTimelineFlags', {});
      original = List<String>.from(flags['recordedStreams'] as List);
      final streams = {...original, 'Dart', 'Isolate'}.toList();
      await request('setVMTimelineFlags', {
        'recordedStreams': '[${streams.join(',')}]',
      });
      changed = true;
      final vm = await request('getVM', {});
      final origin =
          (await request('getVMTimelineMicros', {}))['timestamp'] as int;
      final workers = <String>[
        for (final isolate in vm['isolates'] as List)
          if (isolate['name'] == '_workerEntry') isolate['id'] as String,
      ];
      final sink = destination.openWrite();
      sink.writeln(
        jsonEncode({
          'schema': 'xveil-private-storage-timeline/1',
          'kind': 'open',
          'openedAtUs': DateTime.now().microsecondsSinceEpoch,
          'originUs': origin,
          'workers': workers,
        }),
      );
      return StandStorageTimeline._(
        request,
        closeClient,
        sink,
        original,
        origin,
        workers,
        eventLimit,
        byteLimit,
      );
    } catch (_) {
      try {
        if (changed) {
          await request('setVMTimelineFlags', {
            'recordedStreams': '[${original!.join(',')}]',
          });
        }
      } finally {
        closeClient();
      }
      rethrow;
    }
  }

  static const maxEvents = 200000;
  static const maxBytes = 96 * 1024 * 1024;
  final StandVmRequest _request;
  final void Function() _closeClient;
  final IOSink _sink;
  final List<String> _originalStreams;
  int _origin;
  final int _initialOrigin, _eventLimit, _byteLimit;
  final Set<String> _workers;
  final Set<String> _seen = {};
  int _events = 0, _bytes = 0;
  bool _capped = false;
  Future<void>? _closing, _capturing;
  Timer? _timer;
  bool _pollFailed = false, _closed = false;

  // The parent may spend seconds restarting another device. Poll independently
  // so the VM ring cannot silently overwrite this child's active window.
  void startPolling([Duration interval = const Duration(seconds: 1)]) {
    if (interval.inMicroseconds < 1 || _closing != null || _closed) {
      throw StateError('invalid storage timeline polling lifecycle');
    }
    _timer ??= Timer.periodic(interval, (_) {
      if (_closing != null) return;
      unawaited(
        capture().catchError((Object _) {
          _pollFailed = true;
        }),
      );
    });
  }

  Future<void> capture() {
    if (_closed) return Future.error(StateError('storage timeline is closed'));
    final pending = _capturing;
    if (pending != null) return pending;
    late final Future<void> result;
    result = _capture().whenComplete(() {
      if (identical(_capturing, result)) _capturing = null;
    });
    return _capturing = result;
  }

  Future<void> _capture() async {
    if (_capped) return;
    final end = (await _request('getVMTimelineMicros', {}))['timestamp'] as int;
    if (end < _origin) throw StateError('VM timeline clock regressed');
    final timeline = await _request('getVMTimeline', {
      'timeOriginMicros': '$_initialOrigin',
      'timeExtentMicros': '${end - _initialOrigin}',
    });
    // Durations are published only on completion. Re-read from the original
    // origin (the VM ring is bounded), then deduplicate: moving the query
    // origin forward can lose a long handler's earlier begin event.
    final events = <Map<String, Object?>>[];
    for (final raw in timeline['traceEvents'] as List) {
      final event = raw as Map;
      final args = event['args'] as Map? ?? const {};
      final rpc = event['name'] == 'stand.storage.rpc';
      if (!(rpc && const ['b', 'e'].contains(event['ph'])) &&
          !(event['name'] == 'HandleMessage' &&
              _workers.contains(args['isolateId']) &&
              const ['B', 'E'].contains(event['ph']))) {
        continue;
      }
      final retained = <String, Object?>{
        'name': event['name'],
        'ph': event['ph'],
        'ts': event['ts'],
        'tid': event['tid'],
        if (rpc) 'id': event['id'],
        'args': rpc
            ? {
                if (args.containsKey('sequence')) 'sequence': args['sequence'],
                if (args.containsKey('operation'))
                  'operation': args['operation'],
                if (args.containsKey('ok')) 'ok': args['ok'],
              }
            : {'isolateId': args['isolateId']},
      };
      final key = jsonEncode(retained);
      if (_seen.contains(key)) continue;
      if (_seen.length >= _eventLimit) {
        _capped = true;
        return;
      }
      _seen.add(key);
      events.add(retained);
    }
    final line = jsonEncode({
      'kind': 'chunk',
      'fromUs': _origin,
      'toUs': end,
      'timeOriginMicros': timeline['timeOriginMicros'],
      'timeExtentMicros': timeline['timeExtentMicros'],
      'events': events,
    });
    final size = utf8.encode(line).length;
    if (_events + events.length > _eventLimit || _bytes + size > _byteLimit) {
      _capped = true;
      return;
    }
    _sink.writeln(line);
    _events += events.length;
    _bytes += size;
    _origin = end;
    await _sink.flush();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _timer?.cancel();
    try {
      final pending = _capturing;
      if (pending != null) await pending;
      await capture();
    } finally {
      try {
        await _request('setVMTimelineFlags', {
          'recordedStreams': '[${_originalStreams.join(',')}]',
        });
      } finally {
        _sink.writeln(
          jsonEncode({
            'kind': 'close',
            'events': _events,
            'bytes': _bytes,
            'capped': _capped,
            'pollFailed': _pollFailed,
          }),
        );
        try {
          await _sink.close();
        } finally {
          _closed = true;
          _closeClient();
        }
      }
    }
  }
}
