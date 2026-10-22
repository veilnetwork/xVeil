import 'dart:math' as math;

typedef CallVideoBudget = ({int maxBitrateKbps, double maxFps});

enum CallVideoDeliveryPhase { startup, drain, cruise, probe }

/// BBR-inspired source search, not a replacement for transport congestion
/// control. Only authenticated remote decoder progress funds a new probe.
/// Rate samples are bounded by production, so ACK compression cannot invent
/// capacity. Low application-limited samples never erase the recent maximum.
class CallVideoDeliveryModel {
  final _peers = <String, _DeliverySample>{};
  final _barriers = <String, (int, int, int)>{};
  final _rates = <(DateTime, double)>[];
  final _qualified = <String>{};
  final _streamEpochs = <String, String>{};
  CallVideoDeliveryPhase phase = CallVideoDeliveryPhase.startup;
  DateTime? _lastApply, _drainUntil, _nextProbe;
  int? _route;
  String? _membership;
  bool supported = false, queuePressure = false, _credit = false;
  int generation = 0;
  double deliveryKbps = 0;

  /// Let the acknowledged reduction drain before reacting to another video
  /// loss observation. Audio protection remains independent of this interval.
  bool draining(DateTime now) =>
      _drainUntil != null &&
      _lastApply != null &&
      !now.isBefore(_lastApply!) &&
      now.isBefore(_drainUntil!);

  void reset() {
    generation++;
    _peers.clear();
    _barriers.clear();
    _qualified.clear();
    _streamEpochs.clear();
    _rates.clear();
    supported = queuePressure = _credit = false;
    deliveryKbps = 0;
    phase = CallVideoDeliveryPhase.startup;
    _lastApply = _drainUntil = _nextProbe = null;
    _route = null;
    _membership = null;
  }

  void observe(
    Map<String, dynamic> stats,
    DateTime now,
    int expectedPeers, {
    bool sourcePaused = false,
  }) {
    queuePressure = _credit = false;
    if (sourcePaused) _qualified.clear();
    final raw = stats['video_delivery_peers'];
    if (raw is! Map) return;
    final names = raw.keys.whereType<String>().toList()..sort();
    final epochs = <String, String>{};
    for (final name in names) {
      final peer = raw[name];
      epochs[name] = peer is Map && peer.isNotEmpty
          ? '${peer['route_epoch']}:${peer['source_epoch']}'
          : _streamEpochs[name] ?? 'null:null';
    }
    final membership = names.map((n) => '$n:${epochs[n]}').join(',');
    final route = stats['video_rtt_route_epoch'];
    if ((_route != null && route != _route) ||
        (_membership != null && membership != _membership) ||
        (_lastApply != null && now.isBefore(_lastApply!))) {
      reset();
    }
    _membership = membership;
    _streamEpochs
      ..clear()
      ..addAll(epochs);
    _route = route is int ? route : null;
    var all = names.length == expectedPeers && expectedPeers > 0;
    var complete = all;
    var slowest = double.infinity;
    for (final name in names) {
      final next = _DeliverySample.parse(raw[name], now);
      final old = _peers[name];
      if (next == null) {
        complete = false;
        all = false;
        continue;
      }
      if (old != null &&
          next.origin == old.origin &&
          (next.sample <= old.sample || next.arrival <= old.arrival)) {
        all &=
            _qualified.contains(name) &&
            now.difference(old.at) <= const Duration(seconds: 3);
        continue;
      }
      if (old != null && next.origin < old.origin) {
        all = false;
        continue;
      }
      if (old != null && next.origin > old.origin) {
        _barriers.remove(name);
        _qualified.remove(name);
        _rates.clear();
      }
      final same = old != null && next.origin == old.origin;
      final progress =
          same && next.frames > old.frames && next.bytes > old.bytes;
      if (next.sentTimestampValid) {
        _barriers.putIfAbsent(
          name,
          () => (next.origin, next.sample, next.sentTimestamp),
        );
      }
      final barrier = _barriers[name];
      // RTP timestamps use serial arithmetic, including the 32-bit wrap. A
      // fresh report of frames predating the last probe earns nothing.
      final causal =
          barrier != null &&
          (next.origin == barrier.$1 &&
              next.sample > barrier.$2 &&
              _newerTimestamp(next.timestamp, barrier.$3));
      if (progress && causal) _qualified.add(name);
      if (!_qualified.contains(name)) all = false;
      if (same && (next.frames < old.frames || next.bytes < old.bytes)) {
        all = false;
        continue;
      }
      if (sourcePaused) {
        // No new source media time is expected during an acknowledged pause.
        // Fresh report clocks around the same old decoded frame (including its
        // retained playout delay) cannot prove a growing network queue. That
        // false witness otherwise prevents the audio controller from ever
        // releasing its pause. Resume only the sparse floor; growth still
        // requires a causal decoder ACK of media sent after this barrier.
        if (next.sentTimestampValid) {
          _barriers[name] = (next.origin, next.sample, next.sentTimestamp);
        }
        _qualified.remove(name);
        _peers[name] = next;
        all = false;
        continue;
      }
      if (progress) {
        final remoteUs = next.sample - old.sample;
        final localUs = now.difference(old.at).inMicroseconds;
        if (remoteUs >= 100000 &&
            localUs >= 100000 &&
            next.sentBytes >= old.sentBytes) {
          final receiveRate = (next.bytes - old.bytes) * 8000 / remoteUs;
          final sendRate = (next.sentBytes - old.sentBytes) * 8000 / localUs;
          slowest = math.min(slowest, math.min(receiveRate, sendRate));
        }
      }
      // WebRTC's current_delay_ms includes its adaptive playout target. A
      // target rising while decoded RTP keeps pace is not a growing backlog.
      // Compare elapsed receiver time with decoded RTP media time. Clock
      // offsets cancel; a bounded ten-second window limits clock-rate drift.
      // Allow one frame of quantization (important at the one-fps floor).
      if (same && old.frames > 0 && next.frames >= old.frames) {
        final ticks = (next.timestamp - old.timestamp) & 0xffffffff;
        if (ticks < 0x80000000) {
          final mediaUs = ticks * 1000 ~/ 90;
          final frames = next.frames - old.frames;
          next.mediaLagUs = old.mediaLagUs + next.sample - old.sample - mediaUs;
          next.lagWindow = [
            for (final point
                in old.lagWindow.isEmpty
                    ? [(old.sample, old.mediaLagUs)]
                    : old.lagWindow)
              if (next.sample - point.$1 <= 10000000) point,
            (next.sample, next.mediaLagUs),
          ];
          next.framePeriodUs = frames > 0 && ticks > 0
              ? mediaUs ~/ frames
              : old.framePeriodUs;
        }
        final minimumLagUs = next.lagWindow.fold(
          next.mediaLagUs,
          (minimum, point) => math.min(minimum, point.$2),
        );
        final growing =
            next.mediaLagUs - minimumLagUs >= 80000 + next.framePeriodUs;
        next.growingSince = growing ? old.growingSince ?? now : null;
        queuePressure |=
            next.delay >= 500 ||
            (next.growingSince != null &&
                now.difference(next.growingSince!) >=
                    const Duration(seconds: 3));
      }
      _peers[name] = next;
    }
    supported |= complete;
    _rates.removeWhere(
      (r) => now.difference(r.$1) > const Duration(seconds: 10),
    );
    if (all && slowest.isFinite && slowest > 0) _rates.add((now, slowest));
    deliveryKbps = _rates.fold(0, (value, r) => math.max(value, r.$2));
    final queueGrowing = _peers.values.any((p) => p.growingSince != null);
    _credit = !sourcePaused && all && !queuePressure && !queueGrowing;
  }

  CallVideoBudget? propose(
    CallVideoBudget applied,
    CallVideoBudget ceiling,
    DateTime now, {
    required bool healthy,
  }) {
    if (!healthy ||
        !_credit ||
        (_lastApply != null &&
            now.difference(_lastApply!) < const Duration(milliseconds: 950))) {
      return null;
    }
    if (_drainUntil != null) {
      if (now.isBefore(_drainUntil!)) return null;
      _drainUntil = null;
      phase = CallVideoDeliveryPhase.cruise;
    }
    if (applied == ceiling) {
      phase = CallVideoDeliveryPhase.cruise;
      return null;
    }
    final startup = phase == CallVideoDeliveryPhase.startup;
    if (!startup && _nextProbe != null && now.isBefore(_nextProbe!)) {
      return null;
    }
    final gain = startup ? 2.0 : 1.25;
    return (
      maxBitrateKbps: math.min(
        ceiling.maxBitrateKbps,
        math.max(
          applied.maxBitrateKbps + 1,
          (applied.maxBitrateKbps * gain).ceil(),
        ),
      ),
      maxFps: math.min(
        ceiling.maxFps,
        math.max(applied.maxFps + 1, applied.maxFps * gain),
      ),
    );
  }

  void applied(DateTime now, {required bool reduced}) {
    _credit = false;
    _lastApply = now;
    _barriers.clear();
    _qualified.clear();
    for (final entry in _peers.entries) {
      final r = entry.value;
      if (r.sentTimestampValid) {
        _barriers[entry.key] = (r.origin, r.sample, r.sentTimestamp);
      }
    }
    if (reduced) {
      phase = CallVideoDeliveryPhase.drain;
      _drainUntil = now.add(const Duration(seconds: 3));
      _nextProbe = now.add(const Duration(seconds: 6));
      // Rebase the decoder queue only after draining, not on every report.
      for (final r in _peers.values) {
        r.lagWindow = [(r.sample, r.mediaLagUs)];
        r.growingSince = null;
      }
    } else if (phase != CallVideoDeliveryPhase.startup) {
      phase = CallVideoDeliveryPhase.probe;
      _nextProbe = now.add(const Duration(seconds: 3));
    }
  }

  static bool _newerTimestamp(int next, int before) {
    final delta = (next - before) & 0xffffffff;
    return delta > 0 && delta < 0x80000000;
  }

  Map<String, Object?> get diagnostics => {
    'phase': phase.name,
    'supported': supported,
    'delivery_kbps': deliveryKbps,
    'probe_confirmed': _credit,
    'queue_pressure': queuePressure,
  };
}

class _DeliverySample {
  _DeliverySample(
    this.origin,
    this.sample,
    this.arrival,
    this.bytes,
    this.frames,
    this.timestamp,
    this.delay,
    this.sentTimestamp,
    this.sentBytes,
    this.sentTimestampValid,
    this.at,
  );
  final int origin,
      sample,
      arrival,
      bytes,
      frames,
      timestamp,
      delay,
      sentTimestamp,
      sentBytes;
  final bool sentTimestampValid;
  final DateTime at;
  int mediaLagUs = 0, framePeriodUs = 0;
  List<(int, int)> lagWindow = [];
  DateTime? growingSince;
  static _DeliverySample? parse(Object? raw, DateTime now) {
    if (raw is! Map) return null;
    final values = [
      for (final k in [
        'origin',
        'sample_us',
        'arrival_us',
        'bytes',
        'frames',
        'timestamp',
        'delay_ms',
        'sent_timestamp',
        'sent_bytes',
      ])
        raw[k],
    ];
    if (values.any((v) => v is! int || v < 0)) return null;
    final validClock = raw['sent_timestamp_valid'];
    if (validClock != null && validClock is! bool) return null;
    final v = values.cast<int>();
    if (v[0] == 0 ||
        v[1] < v[0] ||
        v[2] == 0 ||
        v[6] > 60000 ||
        v[5] > 0xffffffff ||
        v[7] > 0xffffffff) {
      return null;
    }
    return _DeliverySample(
      v[0],
      v[1],
      v[2],
      v[3],
      v[4],
      v[5],
      v[6],
      v[7],
      v[8],
      validClock is bool ? validClock : v[8] > 0,
      now,
    );
  }
}
