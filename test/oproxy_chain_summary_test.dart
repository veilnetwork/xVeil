import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/proxy_routing.dart';
import 'package:xveil/features/network/oproxy_chain_summary.dart';
import 'package:xveil/l10n/app_localizations_en.dart';
import 'package:xveil/l10n/app_localizations_ru.dart';

/// The row that tells a person WHICH exit their VPN leaves through.
///
/// It rendered "0 + запасных: exit-host" on a live phone: the generated
/// signature sorts placeholders alphabetically — `(fallbacks, primary)` — while
/// the sentence reads `{primary} + запасных: {fallbacks}`, and both call sites
/// passed them the other way round. Two positional `Object`s of the same type
/// swap silently; nothing but reading the screen catches it.
void main() {
  // The two exits the phone actually carries, padded to the 64 hex digits
  // ProxyRouting insists on — a short id is silently dropped from the catalog,
  // which would make every assertion below pass for the wrong reason.
  final zap = 'b95b118d'.padRight(64, 'a');
  final vdsina = '59dc503e'.padRight(64, 'b');

  final routing = ProxyRouting.disabled.copyWith(
    oProxies: [
      OproxyEndpoint(nodeId: zap, label: 'exit-host'),
      OproxyEndpoint(nodeId: vdsina, label: 'vdsina2'),
    ],
  );

  test('premise: both exits are in the catalog', () {
    expect(
      routing.effectiveOproxies.map((e) => e.label),
      containsAll(['exit-host', 'vdsina2']),
    );
  });

  test('names the exit first and counts the fallbacks second', () {
    final text = oproxyChainSummary(AppL10nRu(), routing, [zap, vdsina]);

    // The whole point of the line: the exit is what a person reads FIRST.
    expect(text, 'exit-host + запасных: 1');
    // Premise — without this the assertion above could pass on a string that
    // simply never mentions either value.
    expect(text.indexOf('exit-host'), lessThan(text.indexOf('1')));
  });

  test('a single-exit chain says there are no fallbacks', () {
    expect(
      oproxyChainSummary(AppL10nRu(), routing, [vdsina]),
      'vdsina2 + запасных: 0',
    );
  });

  test('an exit missing from the catalog is named by its id prefix', () {
    final stranger = 'ab' * 32;
    final text = oproxyChainSummary(AppL10nRu(), routing, [stranger]);

    expect(text, startsWith('abababab'));
    expect(text, isNot(contains(stranger)));
  });

  test('with failover off it says so instead of promising a spare', () {
    final text = oproxyChainSummary(
      AppL10nRu(),
      routing,
      [zap, vdsina],
      autoFailover: false,
    );

    // VpnProxyPlan cuts the chain to its first entry when the switch is off,
    // so "+ запасных: 1" would be a promise the plan does not keep.
    expect(text, contains('exit-host'));
    expect(text, contains('запасные отключены'));
    expect(text, isNot(contains('запасных: 1')));
  });

  test('failover off with nothing to fall back to reads as an ordinary line', () {
    // Nothing is being withheld, so the plain sentence is the honest one.
    expect(
      oproxyChainSummary(
        AppL10nRu(),
        routing,
        [zap],
        autoFailover: false,
      ),
      'exit-host + запасных: 0',
    );
  });

  test('the same order holds in English', () {
    expect(
      oproxyChainSummary(AppL10nEn(), routing, [zap, vdsina]),
      'exit-host + 1 fallbacks',
    );
  });
}
