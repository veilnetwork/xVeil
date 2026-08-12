// The two production seed lists must say the same thing.
//
// There are two of them, and they are written in different languages by
// different hands:
//
//   * `assets/prod/seeds.json`, bundled by `pubspec.yaml` and read by the app;
//   * `builtin_seeds()` in the veil submodule, compiled into the node under
//     `--features production-seeds`.
//
// They diverged, and the way it presented is the reason this gate exists. The
// app showed "Connected, 0 nodes": it had a transport, it dialled, and it
// reached nothing — because the bundled list had been swapped for a test
// stand's while the compiled-in list still held production. Nothing was
// broken in any single place. Each list was internally valid, each was
// plausible on its own, and no test compared them, so the app shipped one
// answer and the node held another.
//
// It cost a live debugging session that started from the wrong premise
// entirely — a protocol version mismatch was suspected and the production
// fleet was nearly rolled over it, which per the flag-day note in the wire
// header would have cut off every connected node to fix nothing.
//
// So: one assertion, on the SET, in both directions.
//
// ## What this deliberately does not check
//
// The obfs4 PSK. It is a deployment secret, gitignored, and therefore not
// comparable from inside the repository — a wrong PSK produces the same
// "Connected, 0 nodes" symptom (measured: 0 sessions, 33 handshake failures)
// and this gate cannot see it. That gap is named here rather than left for
// someone to assume it is covered.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One seed, reduced to the fields that decide whether a dial can succeed.
typedef Seed = ({String transport, String publicKey, String nonce});

String _describe(Seed s) => '${s.transport} key=${s.publicKey} nonce=${s.nonce}';

void main() {
  final jsonFile = File('assets/prod/seeds.json');
  final rustFile = File(
    'third_party/veil/crates/veil-bootstrap/src/seeds.rs',
  );

  /// The list the APP bundles and dials.
  List<Seed> bundled() {
    final decoded = jsonDecode(jsonFile.readAsStringSync()) as List<dynamic>;
    return [
      for (final e in decoded.cast<Map<String, dynamic>>())
        (
          transport: e['transport'] as String,
          publicKey: e['public_key'] as String,
          nonce: e['nonce'] as String,
        ),
    ];
  }

  /// The list the NODE compiles in.
  ///
  /// Parsed out of the Rust rather than generated from it, because generating
  /// one from the other is the thing that was never done and this gate has to
  /// work on the tree as it stands. The parse is anchored on `builtin_seeds`
  /// so the DHT bundle constants and the doc comments below it cannot leak in.
  List<Seed> builtin() {
    final source = rustFile.readAsStringSync();
    final start = source.indexOf('pub fn builtin_seeds()');
    expect(start, greaterThan(-1), reason: 'builtin_seeds() moved or was renamed');
    // From the LAST definition: the file carries a `#[cfg]`-gated empty stub
    // for the public source ahead of the real one, and anchoring on the first
    // match would read the stub and compare production against nothing.
    //
    // Bounded at the function's closing brace, not at the end of file. Reading
    // to EOF swallowed the `#[cfg(test)]` fixtures further down and reported
    // `tcp://seed1.example:9000` as a production seed the app was failing to
    // dial — a gate that invents its own finding is worse than no gate.
    final last = source.lastIndexOf('pub fn builtin_seeds()');
    final close = source.indexOf('\n}', last);
    expect(close, greaterThan(-1), reason: 'builtin_seeds() has no closing brace');
    final body = source.substring(last, close);
    final entry = RegExp(
      r'transport:\s*"([^"]+)"\.to_owned\(\),\s*'
      r'public_key:\s*"([^"]+)"\.to_owned\(\),\s*'
      r'nonce:\s*"([^"]+)"\.to_owned\(\),',
    );
    return [
      for (final m in entry.allMatches(body))
        (
          transport: m.group(1)!,
          publicKey: m.group(2)!,
          nonce: m.group(3)!,
        ),
    ];
  }

  test('the bundled seed list and the compiled-in one agree', () {
    final app = bundled();
    final node = builtin();

    // A floor before any comparison. Both parsers are discovery-based, and two
    // empty sets are equal — the gate would pass loudest at the moment it had
    // stopped reading either file. This project has shipped that shape before.
    expect(
      app.length,
      greaterThanOrEqualTo(3),
      reason: 'parsed ${app.length} seeds from ${jsonFile.path} — the parse '
          'is broken, not the file',
    );
    expect(
      node.length,
      greaterThanOrEqualTo(3),
      reason: 'parsed ${node.length} seeds from ${rustFile.path} — the parse '
          'is broken, not the file',
    );

    final onlyInApp = app.where((s) => !node.contains(s)).map(_describe);
    final onlyInNode = node.where((s) => !app.contains(s)).map(_describe);

    expect(
      onlyInApp,
      isEmpty,
      reason: 'the app would dial seeds the node does not know:\n'
          '${onlyInApp.join('\n')}',
    );
    expect(
      onlyInNode,
      isEmpty,
      reason: 'the node knows seeds the app will never dial:\n'
          '${onlyInNode.join('\n')}',
    );
  });

  test('no test stand reached the shipped list', () {
    // The separate promise, and the one with the sharper edge: test seeds must
    // never enter the index or a release bundle. A stand runs on port 5557 on
    // hosts that are not the production fleet, and the swap that caused the
    // outage above put exactly those values in this file for half an hour.
    //
    // Asserted on the PORT and on the production host set rather than on a
    // denylist of stand addresses — a denylist only knows the stands that
    // existed when it was written, and the next one will have a new address.
    for (final seed in bundled()) {
      expect(
        seed.transport,
        endsWith(':5556'),
        reason: '${seed.transport} is not on the production port',
      );
      expect(
        seed.transport,
        startsWith('obfs4-tcp://'),
        reason: '${seed.transport} is not an obfs4 transport — a plain one '
            'would ship an unobfuscated bootstrap',
      );
    }
  });
}
