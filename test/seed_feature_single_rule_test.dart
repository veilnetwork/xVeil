// One rule for which veil network a build belongs to — checked by reading the
// build scripts, because that is where the copies were.
//
// There were four: `scripts/build-native.sh`, `scripts/build-mobile.sh`,
// `scripts/build-packet-tunnel-macos.sh` and `builder.py`, each naming
// `production-seeds` for itself. A mirrored constant in this repository has
// already cost a live debugging session — the app bundled one seed list while
// the node held another, the symptom was "Connected, 0 nodes", and nothing was
// wrong in any single place.
//
// The rule matters more than the tidiness. The node splices its compiled-in
// seed list in by itself whenever the config names no peers, so the cargo
// feature — not the bundled asset — decides what a stock install actually
// dials. A path that keeps its own copy is a path that can dial production
// from a development build, invisibly from inside the app.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Everything that builds the native library, and must therefore say which
/// network it is building for.
const _buildPaths = [
  'scripts/build-native.sh',
  'scripts/build-mobile.sh',
  'scripts/build-packet-tunnel-macos.sh',
  'builder.py',
];

void main() {
  test('no cargo invocation names a seed feature of its own', () {
    // The property is about CALL SITES, not about the word appearing at all:
    // `builder.py` holds the Python half of the rule and necessarily names both
    // features inside it. What must never happen is a build command choosing
    // one for itself.
    final offenders = <String>[];
    for (final path in _buildPaths) {
      final src = File(path).readAsStringSync();
      for (final line in src.split('\n')) {
        final code = line.trim();
        // Comments explain the rule; they are not the rule.
        if (code.startsWith('#') || code.startsWith('//')) continue;
        if (!code.contains('--features')) continue;
        if (code.contains('production-seeds') || code.contains('testnet-seeds')) {
          offenders.add('$path: $code');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'these decide the network for themselves instead of reading the '
          'shared rule (scripts/veil-network.sh / seed_feature in builder.py):'
          '\n${offenders.join('\n')}',
    );
  });

  test('every build path reads the shared rule', () {
    for (final path in _buildPaths.where((p) => p.endsWith('.sh'))) {
      expect(
        File(path).readAsStringSync(),
        contains('veil-network.sh'),
        reason: '$path builds the node without stating its network',
      );
    }
    expect(
      File('builder.py').readAsStringSync(),
      contains('seed_feature('),
      reason: 'the Windows path builds the node without stating its network',
    );
  });

  // The shell half and the Dart half must agree on the two words, or the app
  // reads one network's assets while linking the other's node.
  test('the shell rule names the same networks as the Dart one', () {
    final rule = File('scripts/veil-network.sh').readAsStringSync();
    expect(rule, contains('prod)    SEED_FEATURE="production-seeds"'));
    expect(rule, contains('testnet) SEED_FEATURE="testnet-seeds"'));
    // And the default: release is production, everything else is the testnet.
    expect(rule, contains('XVEIL_NETWORK=prod'));
    expect(rule, contains('XVEIL_NETWORK=testnet'));
  });
}
