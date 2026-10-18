import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_framing.dart';

Map<String, Object?> model(int overhead, {int copies = 1, int? total}) => {
  'packet_bytes': 200,
  'per_path_overhead_bytes': overhead,
  'per_path_wire_bytes_x2': 2 * (200 + overhead),
  'source_copies_limit': copies,
  'source_wire_bytes_x2': total ?? copies * 2 * (200 + overhead),
};

void main() {
  test('direct, relay, ordered framing and replication stay distinct', () {
    expect(callAudioFramingOverhead(model(209)), 209);
    expect(callAudioFramingOverhead(model(360, copies: 2)), 360);
    // Obfs4 mean508.5 is rounded once for the integral native hint.
    final ordered = model(509)..['per_path_wire_bytes_x2'] = 1417;
    ordered['source_wire_bytes_x2'] = 1417;
    expect(callAudioFramingOverhead(ordered), 509);
    expect(callAudioFramingOverhead(model(717)), 717);
  });
  test('unknown or inconsistent wire models never overwrite a live hint', () {
    expect(callAudioFramingOverhead(null), isNull);
    for (final cost in [
      <String, Object?>{},
      model(360)..['per_path_overhead_bytes'] = 209,
      model(360, copies: 0),
      model(360, copies: 9),
      model(360, total: 100),
      model(360, total: 999999),
      model(360)..['packet_bytes'] = 0,
      model(360)..['per_path_wire_bytes_x2'] = -1,
    ]) {
      expect(callAudioFramingOverhead(cost), isNull);
    }
  });
}
