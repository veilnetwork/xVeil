import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/features/network/security_center_sheet.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

/// The security centre is a STATUS surface: everything on it describes how the
/// app is set up right now, and it is the first thing a person opens to check
/// exactly that. Two of its lines were saying something else.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Mounts the sheet over a host, the way a home section opens it.
  Future<AppL10n> openSheet(WidgetTester tester, _FakeApp app) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(() => app),
          nodeStatusProvider.overrideWith(
            (ref) => Stream.value(
              const NodeStatus(phase: NodePhase.connected, peerCount: 2),
            ),
          ),
          sessionCountProvider.overrideWith((ref) => Stream.value(2)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) {
              hostContext = context;
              return Scaffold(
                body: TextButton(
                  onPressed: () => showSecurityCenterSheet(context, ref),
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return AppL10n.of(hostContext);
  }

  testWidgets('a toggle nobody touched does not claim a pending restart', (
    tester,
  ) async {
    // The subtitle was chosen from the current bool alone, so the OFF state and
    // "you switched it off, and it applies when the node next starts" were the
    // same sentence. On a fresh install — where the toggle has never been
    // touched and there is nothing outstanding — the line read "no longer
    // routes over onion — applies on its next start", which describes an act
    // nobody performed and a restart nobody is waiting for. On the one surface
    // people open to find out what is actually switched on.
    final l = await openSheet(tester, _FakeApp(anonymous: false));

    expect(
      find.text(l.securityCenterAnonymousOff),
      findsOneWidget,
      reason: 'an untouched setting must be stated, not narrated as a change',
    );
    expect(
      find.text(l.settingsAnonymousDisabledHint),
      findsNothing,
      reason: 'nothing is pending on a fresh install',
    );
  });

  testWidgets('a toggle the person just flipped DOES say it is pending', (
    tester,
  ) async {
    // The other half, and the reason the fix is a distinction rather than a
    // replacement: the moment the setting changes there really is something
    // outstanding, and saying so is the whole value of the string.
    final app = _FakeApp(anonymous: false);
    final l = await openSheet(tester, app);

    await tester.tap(find.widgetWithText(SwitchListTile, l.settingsAnonymousRouting));
    await tester.pumpAndSettle();

    expect(
      find.text(l.settingsAnonymousEnabledHint),
      findsOneWidget,
      reason: 'the one moment a pending restart is true is right after this',
    );
    expect(find.text(l.securityCenterAnonymousOn), findsNothing);
    // GUARD — stays green with the fix removed: the switch still did its job.
    expect(app.anonymous, isTrue);
  });

  testWidgets('the identity row does not print its own title twice', (
    tester,
  ) async {
    // Title and subtitle were the same string whenever the identity had no
    // display name, which is every identity that has not been renamed. The row
    // read "Identities & account" over "Identities & account" and told a
    // person nothing about where it goes — while the string written for that
    // second line sat unused two files away.
    final l = await openSheet(tester, _FakeApp(anonymous: false));

    expect(find.text(l.settingsCatAccountHint), findsOneWidget);
    expect(
      find.text(l.settingsCatAccount),
      findsOneWidget,
      reason: 'the fallback title stays — what must not repeat is the subtitle',
    );
  });
}

/// A controller with no boot, no storage and no node: what the sheet reads is
/// the anonymity flag and the phase, and both are answered here directly so the
/// assertions are about the sheet rather than about a session coming up.
class _FakeApp extends AppController {
  _FakeApp({required this.anonymous});

  /// Public and mutable: the toggle test reads it back as its guard, and the
  /// sheet reads it through [singleIdentityAnonymous] exactly as it reads the
  /// real one.
  bool anonymous;

  @override
  AppState build() => const AppState(AppPhase.ready);

  @override
  bool get singleIdentityAnonymous => anonymous;

  @override
  Future<bool> setSingleIdentityAnonymous(bool value) async {
    anonymous = value;
    // The real one bumps this too: the flag lives on the notifier, so nothing
    // the sheet watches would otherwise change.
    ref.read(anonymityRevisionProvider.notifier).state++;
    return true;
  }
}
