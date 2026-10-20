// Private physical-call overlay. Copied into an isolated QA export by
// prepare_physical_pcm_probe.py; never imported by the production app.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _Row extends Struct {
  @Double()
  external double t;
  @Double()
  external double sourceAt;
  @Double()
  external double rms;
  @Double()
  external double freq;
  @Double()
  external double intervalMs;
  @Uint64()
  external int sourceTick;
  @Uint32()
  external int side;
  @Uint32()
  external int sourceFreq;
}

final class _Stats extends Struct {
  @Double()
  external double maxIntervalMs;
  @Uint64()
  external int lateIntervals;
  @Uint64()
  external int droppedRows;
  @Array(2)
  external Array<Uint64> failures;
  @Uint64()
  external int ticks;
  @Double()
  external double maxWakeLatenessMs;
  @Double()
  external double maxCallbackMs;
  @Double()
  external double maxPublicationMs;
  @Int32()
  external int qosSupported;
  @Int32()
  external int qosResult;
  @Int32()
  external int qosRequested;
  @Int32()
  external int qosActual;
  @Int32()
  external int timerError;
  @Int32()
  external int deadlineRequested;
  @Int32()
  external int deadlineResult;
  @Int32()
  external int deadlineActive;
  @Uint32()
  external int deadlinePeriodTicks;
  @Uint32()
  external int deadlineComputationTicks;
  @Uint32()
  external int deadlineConstraintTicks;
  @Uint32()
  external int deadlineActualPeriodTicks;
  @Uint32()
  external int deadlineActualComputationTicks;
  @Uint32()
  external int deadlineActualConstraintTicks;
  @Uint64()
  external int deadlineChecks;
  @Uint64()
  external int deadlineMisses;
}

const _enabled = bool.fromEnvironment('XVEIL_PCM_PROBE');
const _source = int.fromEnvironment('XVEIL_PCM_SOURCE', defaultValue: -1);
final _probes = <QaPcmProbe>[];

Map<String, Object?> qaPcmSnapshot({double? startAt}) {
  if (!_enabled) throw StateError('Physical PCM overlay is not enabled');
  if (startAt != null) {
    if (_probes.where((p) => !p.stopped && p.handle == nullptr).length != 1) {
      throw StateError('Expected exactly one prepared engine');
    }
    _probes.last.start(startAt);
  }
  return {
    'ok': true,
    'clock': _probes.isEmpty ? null : _probes.last.now(),
    'source': _source,
    'probes': [for (final p in _probes) p.snapshot()],
  };
}

class QaPcmProbe {
  QaPcmProbe._(DynamicLibrary media, this.engine) {
    if (_source < 0 || _source > 1 || _probes.length >= 16) {
      throw StateError('Invalid physical PCM fixture source or engine count');
    }
    final driver = DynamicLibrary.open(
      Platform.isAndroid
          ? 'libxveil_pcm_driver.so'
          : '${File(Platform.resolvedExecutable).parent.parent.path}'
                '/Frameworks/libxveil_pcm_driver.dylib',
    );
    for (final entry in {
      'stand_pcm_row_size': sizeOf<_Row>(),
      'stand_pcm_stats_size': sizeOf<_Stats>(),
    }.entries) {
      if (driver.lookupFunction<Size Function(), int Function()>(entry.key)() !=
          entry.value) {
        throw StateError('PCM driver ABI layout mismatch: ${entry.key}');
      }
    }
    now = driver.lookupFunction<Double Function(), double Function()>(
      'stand_pcm_now',
    );
    _start = driver
        .lookupFunction<
          Pointer<Void> Function(
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
            Int32,
            Double,
            Int32,
            Int32,
          ),
          Pointer<Void> Function(
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
            int,
            double,
            int,
            int,
          )
        >('stand_group_local_pcm_start');
    _poll = driver
        .lookupFunction<
          Size Function(Pointer<Void>, Pointer<_Row>, Size, Pointer<_Stats>),
          int Function(Pointer<Void>, Pointer<_Row>, int, Pointer<_Stats>)
        >('stand_pcm_poll');
    _stop = driver
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('stand_pcm_request_stop');
    _finished = driver
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('stand_pcm_finished');
    _destroy = driver
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('stand_pcm_destroy');
    capture = media
        .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
          'veil_media_test_audio_capture_tone',
        )
        .cast<Void>();
    playout = media
        .lookup<
          NativeFunction<Int32 Function(Pointer<Void>, Pointer<Int16>, Size)>
        >('veil_media_test_audio_playout_pcm')
        .cast<Void>();
    // Flutter's Android systemTemp is code_cache, which an APK update clears.
    // Keep measurements in the app's cache until the collector has copied them.
    final temporary = Directory.systemTemp;
    final parent = Platform.isAndroid && temporary.path.endsWith('/code_cache')
        ? Directory('${temporary.parent.path}/cache')
        : temporary;
    final directory = parent.createTempSync('xveil-pcm-$pid-');
    file = File('${directory.path}/observations.jsonl');
    file.writeAsStringSync('');
    _rows = calloc<_Row>(512);
    _stats = calloc<_Stats>();
  }

  static QaPcmProbe? prepare(DynamicLibrary media, Pointer<Void> engine) {
    if (!_enabled) return null;
    final probe = QaPcmProbe._(media, engine);
    _probes.add(probe);
    return probe;
  }

  final Pointer<Void> engine;
  Pointer<Void> handle = nullptr;
  late final Pointer<Void> capture, playout;
  late final Pointer<_Row> _rows;
  late final Pointer<_Stats> _stats;
  late final File file;
  late final double Function() now;
  late final Pointer<Void> Function(
    Pointer<Void>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    double,
    int,
    int,
  )
  _start;
  late final int Function(Pointer<Void>, Pointer<_Row>, int, Pointer<_Stats>)
  _poll;
  late final void Function(Pointer<Void>) _stop, _destroy;
  late final int Function(Pointer<Void>) _finished;
  Timer? timer;
  double? origin;
  bool stopped = false;
  int written = 0;
  Map<String, Object?> lastStats = {};

  void start(double at) {
    if (stopped || handle != nullptr) throw StateError('PCM already started');
    handle = _start(capture, playout, engine, _source, at, 1000, 1);
    if (handle == nullptr) throw StateError('Native PCM driver rejected start');
    origin = at;
    timer = Timer.periodic(const Duration(milliseconds: 250), (_) => drain());
  }

  void drain() {
    if (handle == nullptr) return;
    final encoded = StringBuffer();
    for (;;) {
      final count = _poll(handle, _rows, 512, _stats);
      for (var i = 0; i < count; i++) {
        final r = _rows[i];
        encoded.writeln(
          jsonEncode({
            't': r.t,
            'source_at': r.sourceAt,
            'rms': r.rms,
            'freq': r.freq,
            'interval_ms': r.intervalMs,
            'source_tick': r.sourceTick,
            'side': r.side,
            'source_freq': r.sourceFreq,
          }),
        );
      }
      written += count;
      if (count < 512) break;
    }
    if (encoded.isNotEmpty) {
      file.writeAsStringSync(encoded.toString(), mode: FileMode.append);
    }
    final s = _stats.ref;
    lastStats = {
      'ticks': s.ticks,
      'dropped_rows': s.droppedRows,
      'failures': [s.failures[0], s.failures[1]],
      'max_interval_ms': s.maxIntervalMs,
      'max_wake_lateness_ms': s.maxWakeLatenessMs,
      'max_callback_ms': s.maxCallbackMs,
      'max_publication_ms': s.maxPublicationMs,
      'qos_supported': s.qosSupported,
      'qos_requested': s.qosRequested,
      'qos_result': s.qosResult,
      'qos_actual': s.qosActual,
      'timer_error': s.timerError,
    };
  }

  Map<String, Object?> snapshot() => {
    'source': _source,
    'path': file.path,
    'origin': origin,
    'started': origin != null,
    'stopped': stopped,
    'rows': written,
    'stats': lastStats,
  };

  void stop() {
    if (stopped) return;
    timer?.cancel();
    if (handle != nullptr) {
      _stop(handle);
      final deadline = now() + 5;
      while (_finished(handle) == 0) {
        if (now() >= deadline) {
          // The caller must retain the engine while a callback can own it.
          throw StateError('PCM driver did not stop; engine is retained');
        }
        sleep(const Duration(milliseconds: 1));
      }
      drain();
      _destroy(handle);
      handle = nullptr;
    }
    calloc.free(_rows);
    calloc.free(_stats);
    stopped = true;
  }
}
