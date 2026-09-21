import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/settings/devices_screen.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/sovereign_secret.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/group_service.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';

void main() {
  _devicesRowActions();
  testWidgets(
    'shows both guided roles and disables them before node readiness',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: DevicesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(DevicesScreen)));
      expect(find.text(l.settingsDevices), findsOneWidget);
      expect(find.text(l.devicesNoGroup), findsOneWidget);
      expect(find.text(l.devicesLinkNew), findsOneWidget);
      expect(find.text(l.devicesJoinExisting), findsOneWidget);
      expect(find.text(l.devicesRecoverySection), findsOneWidget);
      expect(find.text(l.devicesCreateRecovery), findsOneWidget);
      expect(find.text(l.devicesRecover), findsOneWidget);
      final source = tester.widget<ListTile>(
        find.widgetWithText(ListTile, l.devicesLinkNew),
      );
      final target = tester.widget<ListTile>(
        find.widgetWithText(ListTile, l.devicesJoinExisting),
      );
      expect(source.enabled, isFalse);
      expect(target.enabled, isFalse);
      expect(
        tester
            .widget<ListTile>(
              find.widgetWithText(ListTile, l.devicesCreateRecovery),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, l.devicesRecover))
            .enabled,
        isFalse,
      );
    },
  );

  group('the onboarding hand-off opens the join sheet', () {
    // The gate itself, not the sheet: opening the real sheet needs a live
    // RealVeilStack (private constructor, real node) so the positive case is
    // out of reach here. Asserting "no sheet appears" through the widget is
    // NOT a substitute — it passes just as happily with the readiness check
    // deleted, because the resulting premature call dies silently at
    // _showTarget's own null guard. Only the gate can tell the two apart.

    test('waits for the node rather than burning its one shot', () {
      expect(
        shouldOpenJoinSheet(autoJoin: true, ready: false, alreadyOpened: false),
        isFalse,
        reason: 'firing before the node is up opens nothing and never retries',
      );
      expect(
        shouldOpenJoinSheet(autoJoin: true, ready: true, alreadyOpened: false),
        isTrue,
        reason: 'once the node is up the hand-off must actually fire, or the '
            'link path dead-ends on a list the user did not ask for',
      );
    });

    test('fires once, and only for the hand-off', () {
      expect(
        shouldOpenJoinSheet(autoJoin: true, ready: true, alreadyOpened: true),
        isFalse,
        reason: 'a sheet the user closed must stay closed',
      );
      expect(
        shouldOpenJoinSheet(autoJoin: false, ready: true, alreadyOpened: false),
        isFalse,
        reason: 'reaching Devices from Settings must not pop a join sheet',
      );
    });
  });

  testWidgets('a not-ready hand-off leaves a usable screen', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: DevicesScreen(autoJoin: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppL10n.of(tester.element(find.byType(DevicesScreen)));
    expect(
      find.byType(BottomSheet),
      findsNothing,
      reason: 'no node yet — there is nothing to show a join QR from',
    );
    // Still the plain list, not a wedged or blank screen.
    expect(find.text(l.devicesJoinExisting), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, l.devicesJoinExisting))
          .enabled,
      isFalse,
    );
  });
}

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// Only what the device group needs to sign and verify. `noSuchMethod` covers
/// the rest of the interface rather than three hundred lines of stubs; a path
/// that reaches one of them fails loudly instead of quietly returning null.
class _Signer implements GroupSigner {
  _Signer(this._self);
  final NodeId _self;

  @override
  NodeId get selfId => _self;
  @override
  Uint8List get selfPubKey => _self.bytes;
  @override
  ControlEntry signControl(ControlEntry u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  GroupMessage signMessage(GroupMessage u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  bool verifyControl(ControlEntry e) =>
      e.signature.length == 64 && e.authorPubKey.length == 32;
  @override
  bool verifyControlAt(ControlEntry e, int atUnixSecs) => verifyControl(e);
  @override
  bool verifyMessage(GroupMessage m) =>
      m.signature.length == 64 && m.authorPubKey.length == 32;

  @override
  SpaceManifest signSpaceManifest(SpaceManifest value) =>
      value.withSignature(_sig(selfPubKey, value.canonicalBytes()));
  @override
  bool verifySpaceManifest(SpaceManifest value) =>
      value.owner == NodeId(Uint8List.fromList(value.genesisPubKey)) &&
      _same(_sig(value.genesisPubKey, value.canonicalBytes()), value.signature);

  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) =>
      algorithm == 'ed25519' &&
      nodeId == NodeId(Uint8List.fromList(publicKey)) &&
      _same(_sig(publicKey, message), signature);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of this '
          'screen\'s path — add it deliberately if that changes');
}

Uint8List _sig(Uint8List publicKey, Uint8List message) {
  final digest = sha256.convert([...publicKey, ...message]).bytes;
  return Uint8List.fromList([...digest, ...digest]);
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The owner's sovereign key, as far as linking a device needs one.
class _Sovereign implements SovereignGroupSigner {
  _Sovereign(this.nodeId);
  @override
  final NodeId nodeId;
  @override
  String get algorithm => 'ed25519';
  @override
  Uint8List get publicKey => Uint8List.fromList(nodeId.bytes);
  @override
  Uint8List sign(Uint8List message) => _sig(publicKey, message);
  @override
  void close() {}
}

void _devicesRowActions() {
  group('a linked device is something you can ask for data', () {
    testWidgets('its row offers to fetch its data', (tester) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(1);
      final svc = GroupService(storage, _Signer(owner));
      addTearDown(svc.dispose);
      final bob = _id(3);
      expect(
        await svc.linkDevice(bob, sovereign: _Sovereign(_id(9))),
        isTrue,
        reason: 'the premise: a device was linked',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            groupServiceProvider.overrideWithValue(svc),
            storageProvider.overrideWithValue(storage as Storage),
          ],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: const DevicesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(DevicesScreen)));
      expect(
        find.text(l.settingsDevices),
        findsOneWidget,
        reason: 'the premise: the screen renders with a group service',
      );
      expect(
        find.text(l.devicesNoGroup),
        findsNothing,
        reason: 'the premise: this identity HAS a device group',
      );

      // The linked device has a row, and its row has a menu.
      expect(
        find.widgetWithText(ListTile, bob.short),
        findsWidgets,
        reason: 'a linked device with no row is a device nobody can act on',
      );
      expect(
        find.byType(PopupMenuButton<String>),
        findsWidgets,
        reason: 'the row offers nothing at all',
      );

      // And the menu offers to fetch that device's data. THIS is the half a
      // wire test cannot reach: the request machinery was verified end to end
      // on the stand while the screen could still have offered no way in.
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      expect(
        find.text(l.devicesPullHistory),
        findsOneWidget,
        reason:
            'the feature exists on the wire and nowhere a person can press',
      );
    });
  });
}
