import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_video_delivery_model.dart';

final _epoch = DateTime.utc(2026, 10, 25);
const _floor = (maxBitrateKbps: 15, maxFps: 1.0);
const _ceiling = (maxBitrateKbps: 900, maxFps: 60.0);
const _first = (maxBitrateKbps: 19, maxFps: 1.25);

Map<String, dynamic> _ack(int n) => {
  'origin': 1,
  'sample_us': n * 1000000,
  'arrival_us': n * 1000000 + 120000,
  'bytes': n * 1200,
  'frames': n,
  'timestamp': n * 90000,
  'sent_timestamp': n * 90000,
  'sent_bytes': n * 1200,
  'sent_timestamp_valid': true,
  'delay_ms': 60,
};

void _observe(CallVideoDeliveryModel m, int n, {Map<String, dynamic>? peers}) {
  m.observe(
    {
      'video_delivery_peers': peers ?? {'p': _ack(n)},
    },
    _epoch.add(Duration(seconds: n)),
    peers?.length ?? 1,
  );
}

CallVideoDeliveryModel _probed() {
  final m = CallVideoDeliveryModel();
  _observe(m, 1);
  _observe(m, 2);
  expect(
    m.propose(
      _floor,
      _ceiling,
      _epoch.add(const Duration(seconds: 2)),
      healthy: true,
      probeOnly: true,
    ),
    _first,
  );
  m.applied(_epoch.add(const Duration(seconds: 2)), reduced: false);
  return m;
}

void main() {
  test('a new causal startup ACK funds the next bounded RTT probe', () {
    final m = _probed();
    _observe(m, 3);
    expect(
      m.propose(
        _first,
        _ceiling,
        _epoch.add(const Duration(seconds: 3)),
        healthy: true,
        probeOnly: true,
      ),
      (maxBitrateKbps: 24, maxFps: 1.5625),
      reason: 'fresh delivery must not miss a short healthy growth window',
    );
  });

  test('even an early decoded ACK cannot exceed the native pacing floor', () {
    final m = _probed();
    final before = _epoch.add(const Duration(milliseconds: 2949));
    m.observe(
      {
        'video_delivery_peers': {'p': _ack(3)},
      },
      before,
      1,
    );
    expect(
      m.propose(_first, _ceiling, before, healthy: true, probeOnly: true),
      isNull,
    );
    expect(
      m.propose(
        _first,
        _ceiling,
        _epoch.add(const Duration(milliseconds: 2950)),
        healthy: true,
        probeOnly: true,
      ),
      (maxBitrateKbps: 24, maxFps: 1.5625),
    );
  });

  test('a timer cannot replace a new post-probe decoded frame', () {
    final m = _probed();
    _observe(m, 3, peers: {'p': _ack(2)});
    expect(
      m.propose(
        _first,
        _ceiling,
        _epoch.add(const Duration(seconds: 3)),
        healthy: true,
        probeOnly: true,
      ),
      isNull,
    );
    _observe(
      m,
      4,
      peers: {
        'p': {..._ack(4), 'timestamp': 2 * 90000},
      },
    );
    expect(
      m.propose(
        _first,
        _ceiling,
        _epoch.add(const Duration(seconds: 4)),
        healthy: true,
        probeOnly: true,
      ),
      isNull,
    );
  });

  test('every group receiver must acknowledge the new budget', () {
    final m = CallVideoDeliveryModel();
    _observe(m, 1, peers: {'a': _ack(1), 'b': _ack(1)});
    _observe(m, 2, peers: {'a': _ack(2), 'b': _ack(2)});
    m.applied(_epoch.add(const Duration(seconds: 2)), reduced: false);
    _observe(m, 3, peers: {'a': _ack(3), 'b': _ack(2)});
    expect(
      m.propose(
        _first,
        _ceiling,
        _epoch.add(const Duration(seconds: 3)),
        healthy: true,
        probeOnly: true,
      ),
      isNull,
    );
    _observe(m, 4, peers: {'a': _ack(3), 'b': _ack(4)});
    expect(
      m.propose(
        _first,
        _ceiling,
        _epoch.add(const Duration(seconds: 4)),
        healthy: true,
        probeOnly: true,
      ),
      isNotNull,
    );
  });

  test('loss drain and cruise retain their longer probe intervals', () {
    final m = _probed();
    m.applied(_epoch.add(const Duration(seconds: 2)), reduced: true);
    for (var n = 3; n < 8; n++) {
      _observe(m, n);
      expect(
        m.propose(
          _floor,
          _ceiling,
          _epoch.add(Duration(seconds: n)),
          healthy: true,
          probeOnly: true,
        ),
        isNull,
      );
    }
    _observe(m, 8);
    expect(
      m.propose(
        _floor,
        _ceiling,
        _epoch.add(const Duration(seconds: 8)),
        healthy: true,
        probeOnly: true,
      ),
      _first,
    );
    m.applied(_epoch.add(const Duration(seconds: 8)), reduced: false);
    _observe(m, 9);
    expect(
      m.propose(
        _first,
        _ceiling,
        _epoch.add(const Duration(seconds: 9)),
        healthy: true,
        probeOnly: true,
      ),
      isNull,
    );
    _observe(m, 11);
    expect(
      m.propose(
        _first,
        _ceiling,
        _epoch.add(const Duration(seconds: 11)),
        healthy: true,
        probeOnly: true,
      ),
      isNotNull,
    );
  });
}
