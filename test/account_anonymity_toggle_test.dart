import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/features/settings/account_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

/// The anonymity switch in Settings → Account must show the value it actually
/// has after a toggle.
///
/// The flag lives on the notifier — the master roster's `anonymous` entry, or
/// the single space's `anonymous` setting — NOT in [AppState]. The toggle
/// reboots the node but leaves every watched field where it was (same phase in
/// the end, same active label), so a screen that only watches [AppState] kept
/// drawing the pre-toggle position and the control looked dead. That is not
/// cosmetic: it cost a whole stand session chasing a "broken" toggle that had
/// been flipping correctly the entire time.
///
/// Two halves, because the defect can come back on either side: the screen must
/// redraw when the revision moves, and the controller must move it.
void main() {
  testWidgets('the screen redraws off the changed flag, not off AppState', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final ctrl = _StubController();
    final c = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(() => ctrl),
        identityOriginProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(c.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: const AccountSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppL10n.of(tester.element(find.byType(AccountSettingsScreen)));
    final tile = find.widgetWithText(
      SwitchListTile,
      l.settingsAnonymousRouting,
    );
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);

    await tester.tap(find.descendant(of: tile, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    expect(ctrl.anonymous, isTrue, reason: 'the tap reached the setter');
    expect(
      tester.widget<SwitchListTile>(tile).value,
      isTrue,
      reason: 'the switch must follow the flag it just set — watching AppState '
          'alone never sees this, since the toggle leaves phase and the active '
          'label exactly where they were',
    );
  });

  test('setIdentityAnonymous moves the revision the UI watches', () async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final container = FakeHvContainer();
    final alice = container.storage();
    await alice.open(password: 'pw-alice', createIfMissing: true);
    await alice.saveProfile(UserProfile(displayName: 'Alice'));
    final aliceKeys = await alice.exportSpaceKeys();
    await alice.close();
    final master = container.storage();
    await master.open(password: 'masterpw', createIfMissing: true);
    await master.saveRoster([
      RosterEntry(label: 'alice', spaceKeys: aliceKeys),
    ]);
    await master.close();

    final app = container.storage();
    final c = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => app)],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(appControllerProvider.notifier);
    for (
      var i = 0;
      i < 20 && c.read(appControllerProvider).phase == AppPhase.bootstrapping;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await ctrl.unlock('masterpw');
    await ctrl.pickIdentity('alice');
    expect(ctrl.isIdentityAnonymous('alice'), isFalse);

    final before = c.read(anonymityRevisionProvider);
    expect(await ctrl.setIdentityAnonymous('alice', true), isTrue);
    expect(ctrl.isIdentityAnonymous('alice'), isTrue);
    expect(
      c.read(anonymityRevisionProvider),
      greaterThan(before),
      reason: 'a flag change no widget can observe is a flag change no widget '
          'will draw',
    );
  });
}

/// A controller with the real screen's contract and none of its machinery: no
/// bootstrap, no space, no node reboot. Single-identity mode (empty
/// `identities` ⇒ not master), so the switch takes the single-identity branch.
class _StubController extends AppController {
  bool anonymous = false;

  @override
  AppState build() => const AppState(AppPhase.ready);

  @override
  bool get singleIdentityAnonymous => anonymous;

  @override
  bool isIdentityAnonymous(String label) => anonymous;

  @override
  Future<bool> setSingleIdentityAnonymous(bool value) async {
    anonymous = value;
    // What the real setter does at the end of its reboot; the point of the
    // test is that the screen reacts to THIS and not to a state change.
    ref.read(anonymityRevisionProvider.notifier).state++;
    return true;
  }
}
