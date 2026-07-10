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

  group('trayTooltip', () {
    test('locked → app name', () {
      expect(trayTooltip(const AppState(AppPhase.locked)), 'xVeil');
    });
    test('ready with an active identity → its name', () {
      expect(
        trayTooltip(const AppState(AppPhase.ready, activeIdentity: 'work')),
        'work',
      );
    });
    test('ready without an identity → app name', () {
      expect(trayTooltip(const AppState(AppPhase.ready)), 'xVeil');
    });
  });

  group('tray unread line', () {
    test('no unread → no count item', () {
      final menu = buildTrayMenu(l, const AppState(AppPhase.ready));
      expect(keys(menu), isNot(contains(kTrayUnreadKey)));
    });
    test('unread → a disabled count item on top', () {
      final menu = buildTrayMenu(l, const AppState(AppPhase.ready), unread: 5);
      expect(menu.items!.first.key, kTrayUnreadKey);
      expect(menu.items!.first.disabled, isTrue);
      expect(menu.items!.first.label, contains('5'));
    });
    test('count caps at 999+', () {
      final menu =
          buildTrayMenu(l, const AppState(AppPhase.ready), unread: 1500);
      final item = menu.items!.firstWhere((i) => i.key == kTrayUnreadKey);
      expect(item.label, contains('999+'));
    });
  });
}
