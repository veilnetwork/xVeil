// Reproduce the parser-only AOT A/B/A measurement with synthetic IDs:
// TMPDIR=/private/tmp/ dart compile exe scripts/bench_node_id_hex.dart \
//   -o /private/tmp/bench-node-id-hex
// /private/tmp/bench-node-id-hex
//
// This measures decoding, not delivery or full history synchronization. The
// old implementation remains an independent compatibility/workload control.
// Timings are observations, never timing thresholds in a correctness test.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:xveil/core/ids.dart';

NodeId baseline(String hex) {
  final clean = hex.replaceAll(' ', '');
  if (clean.length != 64) {
    throw ArgumentError('node id hex must be 64 chars, got ${clean.length}');
  }
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return NodeId(out);
}

({int us, int checksum}) run(
  NodeId Function(String) parse,
  List<String> input,
  int count,
) {
  var checksum = 0;
  final clock = Stopwatch()..start();
  for (var n = 0; n < count; n++) {
    final id = parse(input[n % input.length]);
    checksum =
        (checksum + id.bytes[n & 31] + id.bytes[(n + 7) & 31]) & 0x3fffffff;
  }
  clock.stop();
  return (us: clock.elapsedMicroseconds, checksum: checksum);
}

void main() {
  final random = Random(20261107);
  final lower = List.generate(
    512,
    (_) => List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join(),
  );
  final inputs = {
    'lower': lower,
    'mixed': [
      for (final value in lower)
        value.substring(0, 32).toUpperCase() + value.substring(32),
    ],
    'spaces': [for (final value in lower) ' ${value.split('').join(' ')} '],
    'legacy': [for (final value in lower) '+f${value.substring(2, 60)}-a\tf'],
  };
  final rows = <Map<String, Object>>[];
  const count = 100000;
  for (final entry in inputs.entries) {
    for (var i = 0; i < entry.value.length; i++) {
      final a = baseline(entry.value[i]);
      final b = NodeId.fromHex(entry.value[i]);
      if (a != b) throw StateError('decoder mismatch');
    }
    run(baseline, entry.value, 10000);
    run(NodeId.fromHex, entry.value, 10000);
    for (var repetition = 0; repetition < 5; repetition++) {
      final a1 = run(baseline, entry.value, count);
      final b = run(NodeId.fromHex, entry.value, count);
      final a2 = run(baseline, entry.value, count);
      if (a1.checksum != b.checksum || a1.checksum != a2.checksum) {
        throw StateError('work mismatch');
      }
      rows.add({
        'profile': entry.key,
        'repetition': repetition,
        'count': count,
        'baseline1Us': a1.us,
        'candidateUs': b.us,
        'baseline2Us': a2.us,
        'checksumMatched': true,
      });
    }
  }
  stdout.writeln(
    jsonEncode({
      'schema': 'xveil-benchmark/node-id-hex/1',
      'rows': rows,
      'totalMeasuredParses': count * 3 * rows.length,
      'timeThresholdAsserted': false,
    }),
  );
}
