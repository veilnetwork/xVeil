// What the app promises about the shared seeds, checked against the node it
// actually ships — the one file here that reads the veil submodule's Rust.
//
// Two promises, both cross-language, both of which have been broken by a change
// that was locally correct on one side of the boundary.
//
// ## 1. The two production seed lists must say the same thing.
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
//
// ## 2. The node's DEFERRED BOOT must not dial those seeds behind the setting.
//
// `EmbeddedNode.startDeferred` boots from a config this app never sees:
// `build_stub_config_with_ephemeral_identity` on the native side. The real
// config — the one carrying `builtin_seed_policy` and therefore the whole
// answer to "may this identity use the shared seeds" — arrives afterwards, as
// an apply-config.
//
// So for as long as the stub said `auto` (the `Config::default()` value, whose
// condition "no peers, no bootstrap_peers" the stub satisfies by construction),
// an identity that DECLINED the shared seeds still opened connectors to all
// four production hosts on every single start. Measured on a real node start:
// `bootstrap.builtin dialing 4 entry point(s): 0 configured + 4 builtin
// seed(s) (policy=auto)`, followed by four `bootstrap.connecting` lines.
//
// The whole of `bundled_seeds.dart`, the onboarding choice, and
// `withBuiltinSeedPolicy` were green throughout: every one of them tests the
// config the app COMPOSES, and the composed config is the second one the node
// reads. Nothing on this side of the boundary could see it, which is why the
// guard has to reach across.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One seed, reduced to the fields that decide whether a dial can succeed.
typedef Seed = ({String transport, String publicKey, String nonce});

String _describe(Seed s) => '${s.transport} key=${s.publicKey} nonce=${s.nonce}';

/// One network's two lists, named the way the build names them.
typedef Network = ({String assetPath, String rustAnchor, bool lastMatch});

/// Both of them. Production is the network real installs use; the testnet is
/// what every development build now talks to, which makes ITS pair of lists
/// exactly as load-bearing — a testnet whose two halves disagree wastes the
/// same debugging session, just on cheaper hardware.
const _networks = <String, Network>{
  'production': (
    assetPath: 'assets/prod/seeds.json',
    // The LAST `builtin_seeds()`: the file carries several `#[cfg]`-gated
    // definitions and only the production-seeds one holds the production list.
    rustAnchor: 'pub fn builtin_seeds()',
    lastMatch: true,
  ),
  'testnet': (
    assetPath: 'assets/testnet/seeds.json',
    rustAnchor: 'pub fn testnet_seeds()',
    lastMatch: false,
  ),
};

void main() {
  final rustFile = File(
    'third_party/veil/crates/veil-bootstrap/src/seeds.rs',
  );

  /// The list the APP bundles and dials.
  List<Seed> bundled(File jsonFile) {
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
  List<Seed> builtin(Network network) {
    final source = rustFile.readAsStringSync();
    final anchor = network.rustAnchor;
    final at = network.lastMatch
        ? source.lastIndexOf(anchor)
        : source.indexOf(anchor);
    expect(at, greaterThan(-1), reason: '\$anchor moved or was renamed');
    // Bounded at the function's closing brace, not at the end of file. Reading
    // to EOF swallowed the `#[cfg(test)]` fixtures further down and reported
    // `tcp://seed1.example:9000` as a production seed the app was failing to
    // dial — a gate that invents its own finding is worse than no gate.
    final close = source.indexOf('\n}', at);
    expect(close, greaterThan(-1), reason: '\$anchor has no closing brace');
    final body = source.substring(at, close);
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

  for (final entry in _networks.entries) {
    final label = entry.key;
    final network = entry.value;

    test('the bundled $label seeds and the compiled-in ones agree', () {
      final app = bundled(File(network.assetPath));
      final node = builtin(network);

      // A floor before any comparison. Both parsers are discovery-based, and
      // two empty sets are equal — the gate would pass loudest at the moment it
      // had stopped reading either file. This project has shipped that shape
      // before.
      expect(
        app.length,
        greaterThanOrEqualTo(3),
        reason: 'parsed ${app.length} seeds from ${network.assetPath} — the '
            'parse is broken, not the file',
      );
      expect(
        node.length,
        greaterThanOrEqualTo(3),
        reason: 'parsed ${node.length} seeds from ${network.rustAnchor} — the '
            'parse is broken, not the file',
      );

      final onlyInApp = app.where((s) => !node.contains(s)).map(_describe);
      final onlyInNode = node.where((s) => !app.contains(s)).map(_describe);

      expect(
        onlyInApp,
        isEmpty,
        reason: 'the app would dial $label seeds the node does not know:\n'
            '${onlyInApp.join('\n')}',
      );
      expect(
        onlyInNode,
        isEmpty,
        reason: 'the node knows $label seeds the app will never dial:\n'
            '${onlyInNode.join('\n')}',
      );
    });
  }

  // The separate promise, and the one with the sharper edge: the two networks
  // must not be able to swap files. A stand runs on 5557 on hosts that are not
  // the production fleet, and the swap that caused the outage above put exactly
  // those values in the production file for half an hour.
  //
  // Asserted on the PORT rather than on a denylist of stand addresses — a
  // denylist only knows the stands that existed when it was written, and the
  // next one will have a new address. The two networks share their hosts now,
  // so the port is the whole of the difference visible from here.
  test('each network\'s file is on that network\'s port', () {
    const ports = {'production': ':5556', 'testnet': ':5557'};
    for (final entry in _networks.entries) {
      for (final seed in bundled(File(entry.value.assetPath))) {
        expect(
          seed.transport,
          endsWith(ports[entry.key]!),
          reason: '${seed.transport} is in ${entry.value.assetPath} but not on '
              'the ${entry.key} port — the two files have been swapped',
        );
        expect(
          seed.transport,
          startsWith('obfs4-tcp://'),
          reason: '${seed.transport} is not an obfs4 transport — a plain one '
              'would ship an unobfuscated bootstrap',
        );
      }
    }
  });

  test('the deferred-boot stub refuses the compiled-in seeds', () {
    // The body of `build_stub_config_with_ephemeral_identity` — the config
    // `EmbeddedNode.startDeferred` boots from, which this app cannot inspect at
    // runtime because `veil_node_start_deferred(sock, len, anonymous, err)`
    // takes no config and returns none.
    //
    // Bounded at the function's own closing brace for the same reason the
    // `builtin_seeds()` parse above is: reading to EOF would swallow the crate's
    // other writers of this field and pass on somebody else's line.
    final storeFile = File('third_party/veil/crates/veil-cfg/src/store.rs');
    final source = storeFile.readAsStringSync();
    final start = source.indexOf(
      'pub fn build_stub_config_with_ephemeral_identity(',
    );
    expect(
      start,
      greaterThan(-1),
      reason: 'build_stub_config_with_ephemeral_identity moved or was renamed '
          'in ${storeFile.path} — this gate is reading nothing',
    );
    final close = source.indexOf('\n}', start);
    expect(close, greaterThan(-1), reason: 'the stub builder has no closing brace');
    final body = source.substring(start, close);

    // On the ASSIGNMENT, not on the word "never" appearing somewhere in the
    // function. The prose around this code says "never" a dozen times, and a
    // gate that a comment can satisfy is a gate that fails open.
    final assigned = RegExp(
      r'builtin_seed_policy\s*=\s*(?:crate::model::|veil_cfg::|)BuiltinSeedPolicy::(\w+)\s*;',
    ).allMatches(body).map((m) => m.group(1)!).toList();

    expect(
      assigned,
      isNotEmpty,
      reason: 'the deferred stub sets no builtin_seed_policy, so it boots on '
          "veil's default `auto` — whose condition (no peers, no "
          'bootstrap_peers) the stub meets by construction. Every start, '
          'including one by an identity that DECLINED the shared seeds, opens '
          'connectors to the production seed hosts before the app config that '
          'says otherwise has been applied.',
    );
    expect(
      assigned,
      everyElement('Never'),
      reason: 'the deferred stub boots with builtin_seed_policy = $assigned. '
          'Only `Never` keeps the boot off the shared seed hosts; the app has '
          'no other way to reach that decision, because startDeferred takes no '
          'config.',
    );
  });
}
