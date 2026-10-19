import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_framing.dart';

Map<String, Object?> model(
  int overhead, {
  int copies = 1,
  int? total,
  int packet = 200,
}) => {
  'packet_bytes': packet,
  'per_path_overhead_bytes': overhead,
  'per_path_wire_bytes_x2': 2 * (packet + overhead),
  'source_copies_limit': copies,
  'source_wire_bytes_x2': total ?? copies * 2 * (packet + overhead),
};

void main() {
  test('direct, relay, ordered framing and replication stay distinct', () {
    expect(callMediaFramingOverhead(model(209)), 209);
    expect(callMediaFramingOverhead(model(360, copies: 2)), 360);
    // Obfs4 mean508.5 is rounded once for the integral native hint.
    final ordered = model(509)..['per_path_wire_bytes_x2'] = 1417;
    ordered['source_wire_bytes_x2'] = 1417;
    expect(callMediaFramingOverhead(ordered), 509);
    expect(callMediaFramingOverhead(model(717)), 717);
    // A full-size RTP packet may occupy two session datagrams. The schema
    // accepts its real model without pretending it was a 1000-byte packet.
    expect(callMediaFramingOverhead(model(420, packet: 1460)), 420);
    expect(callMediaFramingOverhead(model(420, packet: 1461)), isNull);
  });
  test('unknown or inconsistent wire models never overwrite a live hint', () {
    expect(callMediaFramingOverhead(null), isNull);
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
      expect(callMediaFramingOverhead(cost), isNull);
    }
  });
  test(
    'video retains acknowledged framing through a busy or unknown new path',
    () {
      final framing = CallVideoFraming();
      Map<String, Object?>? cost = model(209);
      var workerReady = true;
      final attempts = <int>[];
      void poll() => framing.refresh(
        query: (_) => cost,
        apply: (bytes) {
          attempts.add(bytes);
          return workerReady;
        },
      );
      poll();
      expect(framing.appliedOverheadBytes, 209);
      workerReady = false;
      cost = model(360);
      poll();
      expect(framing.appliedOverheadBytes, 209);
      cost = null;
      poll();
      expect(framing.sourceCost, isNull);
      expect(framing.appliedOverheadBytes, 209);
      workerReady = true;
      cost = model(360);
      poll();
      poll(); // No redundant native mutation for the same per-path hint.
      expect(framing.appliedOverheadBytes, 360);
      for (final invalid in [
        model(1025),
        model(360, packet: 1000),
        model(360)..['per_path_overhead_bytes'] = 1,
      ]) {
        cost = invalid;
        poll();
      }
      expect(attempts, [209, 360, 360]);
      expect(framing.appliedOverheadBytes, 360);
    },
  );
  test(
    'video models payload packet deltas, including counter reset and ceiling',
    () {
      final framing = CallVideoFraming();
      final sizes = <int>[];
      void poll([int? packets, int? bytes]) => framing.refresh(
        stats: packets == null
            ? null
            : {
                'video_tx_payload_pkts': packets,
                'video_tx_payload_bytes': bytes,
              },
        query: (packet) {
          sizes.add(packet);
          return model(360, packet: packet);
        },
        apply: (_) => true,
      );
      poll();
      poll(10, 1800); // 180 payload + 20 RTP, not the lifetime average.
      poll(20, 9800);
      poll(21, 11800); // Bound a model packet to the configured RTP ceiling.
      poll(0, 0); // Reset does not invent a negative/zero-sized packet.
      poll(5, 500);
      expect(sizes, [200, 200, 820, 1000, 1000, 120]);
      expect(framing.appliedOverheadBytes, 360);
    },
  );
}
