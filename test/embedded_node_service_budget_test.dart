import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';

/// A phone's share of other people's DHT work.
///
/// Measured 18.08.2026 on an idle client with three bytes per second of actual
/// application traffic: 5 GB a day on the phone, of which 85% was work done for
/// strangers. veil's own leaf default is 8 MB/h; a phone gets an eighth.
void main() {
  const base =
      '[identity]\n'
      'public_key = "pk"\n'
      '\n'
      '[global]\n'
      'runtime_flavor = "multi_thread"\n';

  test('a phone is given a smaller share of other peoples work', () {
    final out = EmbeddedNode.withMobileServiceBudget(base, isMobile: true);
    expect(out, contains('[dht]'));
    expect(out, contains('service_budget_bytes_per_hour = ${1024 * 1024}'));
  });

  test('a desktop keeps the veil default', () {
    final out = EmbeddedNode.withMobileServiceBudget(base, isMobile: false);
    expect(out, isNot(contains('service_budget_bytes_per_hour')));
    expect(out, base, reason: 'nothing else may change either');
  });

  /// The composed config is built by nesting helpers, so a `[dht]` table may
  /// already exist by the time this one runs. Appending a second `[dht]` makes
  /// a TOML the native parser rejects — the node then fails to start, which is
  /// a worse outcome than any amount of traffic.
  test('an existing dht table is extended, not duplicated', () {
    const withDht =
        '[identity]\n'
        'public_key = "pk"\n'
        '\n'
        '[dht]\n'
        'k = 20\n';

    final out = EmbeddedNode.withMobileServiceBudget(withDht, isMobile: true);

    expect('[dht]'.allMatches(out).length, 1);
    expect(out, contains('k = 20'), reason: 'the existing keys must survive');
    expect(out, contains('service_budget_bytes_per_hour'));
  });

  /// Composing twice must not stack two settings: whichever the parser took
  /// last would silently decide the bill.
  test('applying it twice leaves exactly one setting', () {
    final once = EmbeddedNode.withMobileServiceBudget(base, isMobile: true);
    final twice = EmbeddedNode.withMobileServiceBudget(once, isMobile: true);

    expect('service_budget_bytes_per_hour'.allMatches(twice).length, 1);
    expect(twice, once);
  });
}

extension on String {
  Iterable<Match> allMatches(String input) => RegExp(
    RegExp.escape(this),
  ).allMatches(input);
}
