// The mailbox must be built for a real transport whether or not anything was
// CONFIGURED. Production ships no seed list on either side of the FFI, so a
// gate on the configured list is a gate that is always shut: no mailbox, every
// deposit false, and a contact request — the one send with no retry — lost
// while the app reports itself connected.
//
// Asserted over the source because both call sites need a live node and a real
// transport to exercise, which no unit test has. It reads the CONDITION that
// governs the build rather than searching the file for a spelling: the first
// version of this guard looked for the literal `relays.isNotEmpty` and stayed
// green when the gate came back as `configuredRelays.isNotEmpty`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The `if` that governs the [buildMailboxService] call in [source]: the last
/// line opening a condition before it.
String conditionGoverningTheMailbox(String source) {
  // The CALL, not a comment that names it: the first mention in the app's
  // provider is a paragraph explaining the rebuild race.
  final at = source.indexOf('.buildMailboxService(');
  expect(at, isNot(-1), reason: 'buildMailboxService was renamed');
  final before = source.substring(0, at).split('\n');
  for (final line in before.reversed) {
    final text = line.trim();
    if (text.startsWith('//')) continue;
    if (text.startsWith('if (')) return text;
  }
  fail('no condition governs the mailbox build — has the shape changed?');
}

void main() {
  final sites = {
    'the app': 'lib/state/messaging_providers.dart',
    'the headless daemon': 'lib/headless/headless_runtime.dart',
  };

  for (final entry in sites.entries) {
    group(entry.key, () {
      final source = File(entry.value).readAsStringSync();

      test('decides on the transport alone, never on how many were configured',
          () {
        final condition = conditionGoverningTheMailbox(source);
        expect(
          condition,
          isNot(anyOf(contains('Empty'), contains('length'), contains('>'))),
          reason:
              'the mailbox in ${entry.value} is gated on a COUNT: '
              '`$condition`. On the production network the configured list is '
              'empty by design, so that gate never opens, no mailbox is built, '
              'and nothing can be delivered to this device',
        );
        expect(
          condition,
          contains('VeilFlutterTransport'),
          reason: 'the condition no longer names the transport it is about',
        );
      });

      test('asks the node for carriers rather than the config alone', () {
        expect(
          source,
          contains('liveMailboxRelayCandidates'),
          reason:
              '${entry.value} is back to the configured list alone, which is '
              'empty on every stock install',
        );
      });
    });
  }
}
