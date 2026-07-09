import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/desktop/desktop_tray.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';

void main() {
  final l = lookupAppL10n(const Locale('en'));

  List<String?> keys(menu) => [for (final i in menu.items!) i.key];

  test('locked: window controls + quit only', () {
    final menu = buildTrayMenu(l, const AppState(AppPhase.locked));
    final k = keys(menu);
    expect(k, contains(kTrayShowKey));
    expect(k, contains(kTrayHideKey));
    expect(k, contains(kTrayQuitKey));
    expect(k, isNot(contains(kTrayLockKey)));
    expect(menu.items!.any((i) => i.submenu != null), isFalse);
    expect(menu.items!.last.key, kTrayQuitKey);
  });

  test('ready single identity: lock, no identity submenu', () {
    final menu = buildTrayMenu(l, const AppState(AppPhase.ready));
    expect(keys(menu), contains(kTrayLockKey));
    expect(menu.items!.any((i) => i.submenu != null), isFalse);
    expect(menu.items!.last.key, kTrayQuitKey);
  });

  test('ready master: identity submenu with the active one checked', () {
    final menu = buildTrayMenu(
      l,
      const AppState(
        AppPhase.ready,
        identities: ['personal', 'work'],
        activeIdentity: 'work',
      ),
    );
    final sub = menu.items!.firstWhere((i) => i.submenu != null);
    expect(sub.label, l.trayIdentities);
    final entries = sub.submenu!.items!;
    expect(
      [for (final e in entries) e.key],
      ['${kTrayIdentityKeyPrefix}personal', '${kTrayIdentityKeyPrefix}work'],
    );
    expect(
      [for (final e in entries) e.checked],
      [false, true],
    );
    expect(keys(menu), contains(kTrayLockKey));
    expect(menu.items!.last.key, kTrayQuitKey);
  });

  test('picking identity: lock offered, no switch submenu', () {
    final menu = buildTrayMenu(
      l,
      const AppState(AppPhase.pickingIdentity, identities: ['a', 'b']),
    );
    expect(keys(menu), contains(kTrayLockKey));
    expect(menu.items!.any((i) => i.submenu != null), isFalse);
  });
}
