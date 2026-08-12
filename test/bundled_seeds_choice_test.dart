import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:xveil/core/ids.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/bundled_seeds.dart';
import 'package:xveil/data/node/bundled_seeds_prefs.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/features/network/network_screen.dart';
import 'package:xveil/features/onboarding/bundled_seeds_choice.dart';
import 'package:xveil/features/onboarding/onboarding_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/routing/router.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/managed_nodes_controller.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_hv_container.dart';
import 'support/fake_multi_space.dart';
import 'support/fake_setting_storage.dart';
import 'support/onboarding_walk.dart';

/// The choice between reaching the network through the project's shared seed
/// nodes and reaching it only through nodes the person added themselves.
///
/// The assertions worth having are about the two places the answer has to
/// arrive: the node CONFIG (which is the only thing the node acts on) and the
/// prompt that offers the choice again (which must speak exactly once, in
/// exactly one of three states).

const _seed1 = BootstrapPeerCfg(
  transport: 'obfs4-tcp://203.12.31.146:5556',
  publicKey: 'SEED1=',
  nonce: 'N1=',
);
const _seed2 = BootstrapPeerCfg(
  transport: 'obfs4-tcp://203.12.31.145:5556',
  publicKey: 'SEED2=',
  nonce: 'N2=',
);
const _mine = BootstrapPeerCfg(
  transport: 'obfs4-tcp://10.0.0.9:5556',
  publicKey: 'MINE=',
  nonce: 'N9=',
);

/// A managed-nodes registry that answers a fixed list without a container.
class _FakeManagedNodes extends ManagedNodesController {
  _FakeManagedNodes(this._nodes);
  final List<ManagedNode> _nodes;
  @override
  Future<List<ManagedNode>> build() async => _nodes;
}

Widget _host({
  required bool useBundledSeeds,
  List<ManagedNode> ownNodes = const [],
  List<BootstrapPeerCfg> configuredPeers = const [],
  required void Function(BuildContext, WidgetRef) onReady,
}) => ProviderScope(
  overrides: [
    bundledSeedsChoiceProvider.overrideWith((ref) => useBundledSeeds),
    managedNodesProvider.overrideWith(() => _FakeManagedNodes(ownNodes)),
    deniableBootProvider.overrideWithValue(
      DeniableBootConfig(runtimeDir: '/tmp/x', bootstrapPeers: configuredPeers),
    ),
  ],
  child: MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: Consumer(
      builder: (context, ref, _) => _Ready(onReady: onReady, ref: ref),
    ),
  ),
);

class _Ready extends StatelessWidget {
  const _Ready({required this.onReady, required this.ref});
  final void Function(BuildContext, WidgetRef) onReady;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Builder(
      builder: (inner) => TextButton(
        onPressed: () => onReady(inner, ref),
        child: const Text('go'),
      ),
    ),
  );
}

/// A node controller with no timers (the fake one uses delayed/periodic timers
/// that leak past a widget test).
class _NoopNode implements NodeController {
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

/// A ready session, so the router can be built and asked what it routes where.
class _ReadyAppController extends AppController {
  @override
  AppState build() =>
      AppState(AppPhase.ready, identity: Identity(nodeId: NodeId(Uint8List(32))));
}

/// The boot config as `main()` composes it: BUILT from the live answer, so the
/// bundled descriptors are absent whenever the answer is no. Overriding it with
/// a fixed value instead would make a switch that never reaches the config look
/// exactly like one that does.
final _bootOverrides = [
  deniableBootProvider.overrideWith(
    (ref) => DeniableBootConfig(
      runtimeDir: '/tmp/x',
      bootstrapPeers: resolveBootstrapPeers(
        operatorPeers: const [_mine],
        bundledSeeds: const [_seed1, _seed2],
        useBundledSeeds: ref.watch(bundledSeedsChoiceProvider),
      ),
    ),
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the answer reaches the node configuration', () {
    // The half that actually decides anything. An empty Dart-side peer list is
    // NOT an opt-out: the deniable boot passes no `[[bootstrap_peers]]` on
    // purpose, which is exactly the condition under which veil's
    // `builtin_seed_policy = "auto"` splices its COMPILED-IN seeds into the
    // node's own dial list. Only `never` stops that.
    test('declining forbids the node its compiled-in seeds', () {
      const rendered = '[global]\nbuiltin_seed_policy = "auto"\n';
      final out = EmbeddedNode.withBuiltinSeedPolicy(rendered, false);
      expect(out, contains('builtin_seed_policy = "never"'));
      expect(out, isNot(contains('"auto"')));
      // One key, not two: a duplicate is a TOML parse error, and this config is
      // handed straight to the native parser.
      expect('builtin_seed_policy'.allMatches(out), hasLength(1));
    });

    test('keeping the seeds leaves veil own default alone', () {
      const rendered = '[global]\nbuiltin_seed_policy = "auto"\n';
      expect(EmbeddedNode.withBuiltinSeedPolicy(rendered, true), rendered);
    });

    test('the policy is written even when [global] rendered nothing', () {
      final out = EmbeddedNode.withBuiltinSeedPolicy('listen = "x"\n', false);
      expect(out, contains('[global]'));
      expect(out, contains('builtin_seed_policy = "never"'));
    });

    test('an existing [global] gains the key without a second header', () {
      const rendered = '[global]\nmlkem_rotation_secs = 3600\n';
      final out = EmbeddedNode.withBuiltinSeedPolicy(rendered, false);
      expect('[global]'.allMatches(out), hasLength(1));
      expect(out, contains('mlkem_rotation_secs = 3600'));
      expect(out, contains('builtin_seed_policy = "never"'));
    });
  });

  group('the peer list is built from the answer', () {
    test('declining never merges the bundled seeds in', () {
      final peers = resolveBootstrapPeers(
        operatorPeers: const [_mine],
        bundledSeeds: const [_seed1, _seed2],
        useBundledSeeds: false,
      );
      // Not "filtered afterwards" — the seeds are not in the list at all, so
      // nothing downstream is holding an address it could fall back to.
      expect(peers.map((p) => p.publicKey), ['MINE=']);
    });

    test('declining the SHARED seeds does not decline your own node', () {
      final peers = resolveBootstrapPeers(
        operatorPeers: const [_mine],
        bundledSeeds: const [_seed1],
        useBundledSeeds: false,
      );
      expect(peers.single.transport, 'obfs4-tcp://10.0.0.9:5556');
    });

    test('keeping the seeds merges both sets, own entries first', () {
      final peers = resolveBootstrapPeers(
        operatorPeers: const [_mine],
        bundledSeeds: const [_seed1, _seed2],
        useBundledSeeds: true,
      );
      expect(peers.map((p) => p.publicKey), ['MINE=', 'SEED1=', 'SEED2=']);
    });

    test('declining with nothing of your own leaves the node no peers', () {
      expect(
        resolveBootstrapPeers(
          operatorPeers: const [],
          bundledSeeds: const [_seed1, _seed2],
          useBundledSeeds: false,
        ),
        isEmpty,
      );
    });
  });

  // Renamed: this group asserted a round-trip through the PROFILE preference
  // and nothing whatever about scope, under a title that claimed the answer
  // belonged to the identity that gave it. It did not — one file per app
  // profile was handed to every identity in the process — and a title that
  // states the property nobody checked is how the scope defect survived a full
  // test suite. What the preference is now is the pre-unlock fallback; the
  // identity's own answer is asserted further down, against its space.
  group('the pre-unlock answer is persisted for the profile', () {
    test('absent means yes, so an existing install is untouched', () async {
      expect(await bundledSeedsAllowed(), isTrue);
      expect(await bundledSeedsReofferSuppressed(), isFalse);
    });

    test('a refusal survives being written and read back', () async {
      expect(await setBundledSeedsAllowed(false), isTrue);
      expect(await bundledSeedsAllowed(), isFalse);
    });

    test('the answer is stored under a profile-scoped posture key', () async {
      await setBundledSeedsAllowed(false);
      final prefs = await SharedPreferences.getInstance();
      // The store is one file per profile, so the key needs no profile suffix —
      // but it must be THIS key, because that is the one a wipe clears.
      expect(prefs.getBool(kBundledSeedsPrefKey), isFalse);
      expect(kBundledSeedsPrefKey, 'network.bundled_seeds.v1');
    });

    test('what the node config resolves is what was stored', () async {
      await setBundledSeedsAllowed(false);
      // The value `RealVeilStack.startDeniable` resolves when no caller passes
      // one — the single point every node boot goes through.
      final resolved = await bundledSeedsAllowed();
      expect(
        EmbeddedNode.withBuiltinSeedPolicy(
          '[global]\nbuiltin_seed_policy = "auto"\n',
          resolved,
        ),
        contains('builtin_seed_policy = "never"'),
      );
    });

    test('the control and the config read the same answered store', () async {
      // Two readers, one store, and they differ only on FAILURE:
      // `bundledSeedsAllowed` hands a node config the historical behaviour
      // because something has to be composed, while the network switch stays
      // put — "yes" there would put an identity that refused the shared seeds
      // back on them in the live boot config with nobody having asked. That
      // divergence is only defensible while an ANSWERED store says the same
      // thing to both.
      expect(await storedBundledSeedsAnswer(), isTrue);
      await setBundledSeedsAllowed(false);
      expect(await storedBundledSeedsAnswer(), isFalse);
      expect(await bundledSeedsAllowed(), isFalse);
    });

    test('suppression is a separate key from the answer', () async {
      await setBundledSeedsReofferSuppressed(true);
      // Silencing the prompt is not agreeing to the seeds.
      expect(await bundledSeedsReofferSuppressed(), isTrue);
      expect(await bundledSeedsAllowed(), isTrue);
      await setBundledSeedsAllowed(false);
      expect(await bundledSeedsReofferSuppressed(), isTrue);
    });
  });

  group('the startup prompt has three states', () {
    test('declined and nothing to connect through: offer', () {
      expect(
        shouldOfferBundledSeeds(
          useBundledSeeds: false,
          reofferSuppressed: false,
          ownNodeCount: 0,
          configuredPeerCount: 0,
        ),
        isTrue,
      );
    });

    test('declined with a node of their own: say nothing', () {
      expect(
        shouldOfferBundledSeeds(
          useBundledSeeds: false,
          reofferSuppressed: false,
          ownNodeCount: 1,
          configuredPeerCount: 0,
        ),
        isFalse,
      );
    });

    test('declined but the boot config named an entry point: say nothing', () {
      // An operator who set XVEIL_BOOTSTRAP_PEERS named a way in themselves,
      // and it survives a restart — which is the property that separates it
      // from a peer redeemed from an invite into the ephemeral runtime.
      expect(
        shouldOfferBundledSeeds(
          useBundledSeeds: false,
          reofferSuppressed: false,
          ownNodeCount: 0,
          configuredPeerCount: 1,
        ),
        isFalse,
      );
    });

    test('suppressed: say nothing, even with nothing to connect through', () {
      expect(
        shouldOfferBundledSeeds(
          useBundledSeeds: false,
          reofferSuppressed: true,
          ownNodeCount: 0,
          configuredPeerCount: 0,
        ),
        isFalse,
      );
    });

    test('using the seeds: there is nothing to offer', () {
      expect(
        shouldOfferBundledSeeds(
          useBundledSeeds: true,
          reofferSuppressed: false,
          ownNodeCount: 0,
          configuredPeerCount: 0,
        ),
        isFalse,
      );
    });
  });

  group('the prompt, driven through the real dialog', () {
    testWidgets('declining without peers does prompt', (tester) async {
      await setBundledSeedsAllowed(false);
      await tester.pumpWidget(
        _host(
          useBundledSeeds: false,
          onReady: (context, ref) => maybeOfferBundledSeeds(context, ref),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('go'));
      // Two bare pumps first: the offer awaits both count providers, and those
      // futures complete in microtasks that pumpAndSettle alone does not drain
      // when nothing has scheduled a frame yet.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      expect(find.byType(BundledSeedsReofferDialog), findsOneWidget);
    });

    testWidgets('declining WITH a node of their own does not prompt', (
      tester,
    ) async {
      await setBundledSeedsAllowed(false);
      await tester.pumpWidget(
        _host(
          useBundledSeeds: false,
          ownNodes: const [ManagedNode(id: 'n1', label: 'my vps')],
          onReady: (context, ref) => maybeOfferBundledSeeds(context, ref),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('go'));
      // Two bare pumps first: the offer awaits both count providers, and those
      // futures complete in microtasks that pumpAndSettle alone does not drain
      // when nothing has scheduled a frame yet.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      expect(find.byType(BundledSeedsReofferDialog), findsNothing);
    });

    testWidgets('declining WITH an entry point in the config does not prompt', (
      tester,
    ) async {
      await setBundledSeedsAllowed(false);
      await tester.pumpWidget(
        _host(
          useBundledSeeds: false,
          configuredPeers: const [_mine],
          onReady: (context, ref) => maybeOfferBundledSeeds(context, ref),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('go'));
      // Two bare pumps first: the offer awaits both count providers, and those
      // futures complete in microtasks that pumpAndSettle alone does not drain
      // when nothing has scheduled a frame yet.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      expect(find.byType(BundledSeedsReofferDialog), findsNothing);
    });

    testWidgets('an identity on the shared seeds is never prompted', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          useBundledSeeds: true,
          onReady: (context, ref) => maybeOfferBundledSeeds(context, ref),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('go'));
      // Two bare pumps first: the offer awaits both count providers, and those
      // futures complete in microtasks that pumpAndSettle alone does not drain
      // when nothing has scheduled a frame yet.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      expect(find.byType(BundledSeedsReofferDialog), findsNothing);
    });

    testWidgets('declining twice does not re-prompt after the checkbox', (
      tester,
    ) async {
      await setBundledSeedsAllowed(false);
      await tester.pumpWidget(
        _host(
          useBundledSeeds: false,
          onReady: (context, ref) => maybeOfferBundledSeeds(context, ref),
        ),
      );
      await tester.pump();

      // First launch: prompted, ticks "don't show this again", declines again.
      await tester.tap(find.text('go'));
      // Two bare pumps first: the offer awaits both count providers, and those
      // futures complete in microtasks that pumpAndSettle alone does not drain
      // when nothing has scheduled a frame yet.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      expect(find.byType(BundledSeedsReofferDialog), findsOneWidget);
      final l = AppL10n.of(
        tester.element(find.byType(BundledSeedsReofferDialog)),
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.seedsReofferKeep));
      await tester.pumpAndSettle();
      expect(find.byType(BundledSeedsReofferDialog), findsNothing);

      // The refusal stands, and the box was honoured on the branch that does
      // NOT change the answer — the branch a "don't show this again" is
      // normally lost on.
      expect(await bundledSeedsAllowed(), isFalse);
      expect(await bundledSeedsReofferSuppressed(), isTrue);

      // Next launch, same state: silent.
      await tester.tap(find.text('go'));
      // Two bare pumps first: the offer awaits both count providers, and those
      // futures complete in microtasks that pumpAndSettle alone does not drain
      // when nothing has scheduled a frame yet.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      expect(find.byType(BundledSeedsReofferDialog), findsNothing);
    });

    // Renamed for the same reason as the group above: it says "the identity"
    // and asserts a profile-wide preference plus a live provider. Which
    // identity the dialog answered for is asserted where it can be — against
    // the space, in "the answer belongs to the identity".
    testWidgets('accepting after all records the answer and the live config', (
      tester,
    ) async {
      await setBundledSeedsAllowed(false);
      late WidgetRef captured;
      await tester.pumpWidget(
        _host(
          useBundledSeeds: false,
          onReady: (context, ref) {
            captured = ref;
            maybeOfferBundledSeeds(context, ref);
          },
        ),
      );
      await tester.pump();
      await tester.tap(find.text('go'));
      // Two bare pumps first: the offer awaits both count providers, and those
      // futures complete in microtasks that pumpAndSettle alone does not drain
      // when nothing has scheduled a frame yet.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      final l = AppL10n.of(
        tester.element(find.byType(BundledSeedsReofferDialog)),
      );
      await tester.tap(find.text(l.seedsReofferUse));
      await tester.pumpAndSettle();

      // Both halves: what survives a restart, and what the boot config is
      // rebuilt from without waiting for one.
      expect(await bundledSeedsAllowed(), isTrue);
      expect(captured.read(bundledSeedsChoiceProvider), isTrue);
    });

    // The defect the assertions above could not see, found on Android and iOS
    // on the same day: accepting wrote the setting and the provider and left
    // the RUNNING node exactly as it was — `relays=0`, no mailbox, every send
    // logging `stash SKIP … NO mailbox` — while the dialog closed as if
    // something had happened. A force-stop and relaunch registered the seeds in
    // seconds, so the answer was right and only the moment it was read was
    // wrong. And the write was what made it terminal: an identity on the seeds
    // is never prompted again, so the one thing that could still have explained
    // anything had spent itself.
    //
    // Nothing above catches it. "The preference says true" and "the provider
    // says true" are both satisfied by an app that never boots a node again —
    // they are the two writes the defect consisted of. What has to be asserted
    // is the thing the person came for: a node running on the shared seeds,
    // without a restart.
    testWidgets('accepting REBOOTS the node onto the seeds, without a restart',
        (tester) async {
      SharedPreferences.setMockInitialValues({'onboarded': true});
      final container = FakeHvContainer();
      // An identity in exactly the state the prompt exists for: it declined,
      // and it has nothing of its own to reach the network through.
      final seeding = container.storage();
      expect(
        await seeding.open(password: 'pw', createIfMissing: true),
        isTrue,
      );
      await seeding.saveProfile(UserProfile(displayName: 'refuser'));
      await seeding.putSetting(kBundledSeedsSettingKey, 'false');
      await seeding.close();

      final c = ProviderContainer(
        overrides: [
          singleSpaceStorageProvider.overrideWith((ref) => container.storage()),
          managedNodesProvider.overrideWith(() => _FakeManagedNodes(const [])),
          deniableBootProvider.overrideWithValue(
            const DeniableBootConfig(
              runtimeDir: '/run',
              listenPort: 9000,
              storePath: '/x',
              bundledSeeds: [_seed1, _seed2],
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      // Every node boot this app performs, in order. The seam the real boot
      // path goes through, so what is recorded is what a node would have been
      // composed from — not what any screen believes.
      final plans = <IdentitySeedPlan>[];
      ctrl.debugDeniableStackStarter = (plan) async {
        plans.add(plan);
        return RealVeilStack.overParts(
          controller: _NoopNode(),
          transport: _NoopTransport(),
          myInvite: BootstrapInvite(
            publicKey: Uint8List(32),
            nonce: Uint8List(8),
          ),
        );
      };

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Builder(
                  builder: (inner) => TextButton(
                    onPressed: () => maybeOfferBundledSeeds(inner, ref),
                    child: const Text('go'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      /// Pump until [done] or the budget runs out. Never fails on its own — the
      /// assertions do that, so a timeout reads as the state it actually
      /// reached rather than as a stack trace from a helper.
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 200 && !done(); i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      // Never `await` a controller future in a widget test: the body suspends,
      // nothing pumps, and the microtasks it is waiting on are never flushed.
      unawaited(ctrl.unlock('pw'));
      await until(() => c.read(appControllerProvider).phase == AppPhase.ready);

      // The CONTROL, and it comes first: the identity really is running a node
      // composed from its refusal. Without it, "the second boot has the seeds"
      // would pass just as well against an app that always boots with them.
      expect(plans, hasLength(1), reason: 'the first node boot never ran');
      expect(plans.single.useBundledSeeds, isFalse);
      expect(plans.single.bootstrapPeers, isEmpty);

      await tester.tap(find.text('go'));
      // Two bare pumps first: the offer awaits both count providers, and those
      // futures complete in microtasks that pumpAndSettle alone does not drain
      // when nothing has scheduled a frame yet.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      expect(find.byType(BundledSeedsReofferDialog), findsOneWidget);
      final l = AppL10n.of(
        tester.element(find.byType(BundledSeedsReofferDialog)),
      );
      await tester.tap(find.text(l.seedsReofferUse));
      await until(() => plans.length > 1);

      // THE ASSERTION. A second node boot happened because the button was
      // pressed, and it was composed with the shared seeds. The shipped code
      // reaches neither: it writes two values and stops, and this identity goes
      // on running the node it booted from its refusal until the app is killed.
      expect(
        plans,
        hasLength(2),
        reason: 'the choice never reached a node: the app kept running the '
            'node composed from the refusal, with no relay and no mailbox, '
            'and the prompt that could have said so can never appear again',
      );
      expect(plans.last.useBundledSeeds, isTrue);
      expect(plans.last.bootstrapPeers.map((p) => p.publicKey), [
        'SEED1=',
        'SEED2=',
      ]);
      // The boot read the SPACE, not the provider — `planIdentitySeeds`
      // resolves the identity's own answer — so the reboot also proves the
      // answer was persisted before the node was rebuilt from it.
      expect(c.read(appControllerProvider).phase, AppPhase.ready);
    });

    testWidgets('a reboot that does not come back is SAID, not swallowed', (
      tester,
    ) async {
      // The dead end, one layer down. Accepting spends the prompt for good —
      // an identity on the seeds is never asked again — so if the node does
      // not come back and nothing says so, the person is left exactly where
      // the original defect left them: an app that cannot reach anything, and
      // nothing on screen to act on. The restart has to be named.
      await setBundledSeedsAllowed(false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bundledSeedsChoiceProvider.overrideWith((ref) => false),
            managedNodesProvider.overrideWith(() => _FakeManagedNodes(const [])),
            storageProvider.overrideWith((ref) => _OpenSettingStorage()),
            appControllerProvider.overrideWith(_RebootRefusingAppController.new),
            deniableBootProvider.overrideWithValue(
              const DeniableBootConfig(runtimeDir: '/tmp/x'),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Builder(
                  builder: (inner) => TextButton(
                    onPressed: () => maybeOfferBundledSeeds(inner, ref),
                    child: const Text('go'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      final l = AppL10n.of(
        tester.element(find.byType(BundledSeedsReofferDialog)),
      );
      await tester.tap(find.text(l.seedsReofferUse));
      await tester.pumpAndSettle();

      expect(find.byType(BundledSeedsReofferDialog), findsNothing);
      expect(
        find.text(l.seedsRestartToApply),
        findsOneWidget,
        reason: 'the answer was recorded and no node took it, and the person '
            'was told nothing — the prompt cannot fire again, so this notice '
            'is the only thing left that mentions the restart',
      );
    });
  });

  group('the answer can be changed after onboarding', () {
    // The onboarding step says "You can change this later in Network settings"
    // and shipped with nothing behind it: `setBundledSeedsAllowed` had two call
    // sites, the step itself and the re-offer dialog — which can only ever
    // write `true`. Someone who ACCEPTED could never decline, and someone who
    // declined and ticked "don't show this again" had no route back.

    Widget host({required void Function(ProviderContainer) capture}) =>
        ProviderScope(
          overrides: _bootOverrides,
          child: Consumer(
            builder: (ctx, ref, _) {
              capture(ProviderScope.containerOf(ctx));
              return MaterialApp(
                localizationsDelegates: AppL10n.localizationsDelegates,
                supportedLocales: AppL10n.supportedLocales,
                home: const Scaffold(
                  body: SingleChildScrollView(child: SharedSeedsSwitch()),
                ),
              );
            },
          ),
        );

    /// What `EmbeddedNode.composeConfig` would render for the answer currently
    /// in the store — the half of the opt-out the node actually acts on.
    Future<String> composedPolicy() async => EmbeddedNode.withBuiltinSeedPolicy(
      '[global]\nbuiltin_seed_policy = "auto"\n',
      await bundledSeedsAllowed(),
    );

    testWidgets('accepted -> declined reaches BOTH halves of the config', (
      tester,
    ) async {
      await setBundledSeedsAllowed(true);
      late ProviderContainer container;
      await tester.pumpWidget(host(capture: (c) => container = c));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      // Survives a restart, under the key a wipe clears. No container is open
      // in this widget test, so the write lands in the pre-unlock fallback —
      // which is exactly the path the switch takes when nothing is unlocked.
      expect(await bundledSeedsAllowed(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kBundledSeedsPrefKey), isFalse);

      // Half one: the boot config no longer HOLDS the bundled descriptors, so
      // nothing downstream has an address it could fall back to. This is the
      // assertion a switch that wrote only the preference fails.
      expect(
        container.read(deniableBootProvider)!.bootstrapPeers.map(
          (p) => p.publicKey,
        ),
        ['MINE='],
      );
      // Half two: the node is forbidden its COMPILE-TIME seeds. Without this,
      // an empty peer list is the very condition under which veil splices them
      // in by itself, and the refusal would be theatre.
      expect(await composedPolicy(), contains('builtin_seed_policy = "never"'));
    });

    testWidgets('declined -> accepted puts the identity back on the seeds', (
      tester,
    ) async {
      await setBundledSeedsAllowed(false);
      late ProviderContainer container;
      await tester.pumpWidget(host(capture: (c) => container = c));
      // The control reads the identity's own answer out of the store, so it
      // opens showing "off" even though the provider was seeded with the
      // default — that is what makes it right after an identity switch.
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(await bundledSeedsAllowed(), isTrue);
      expect(
        container.read(deniableBootProvider)!.bootstrapPeers.map(
          (p) => p.publicKey,
        ),
        ['MINE=', 'SEED1=', 'SEED2='],
      );
      // Nothing is written when the seeds are kept: veil's own default is
      // `auto`, and spelling it out would freeze a runtime decision.
      expect(
        await composedPolicy(),
        '[global]\nbuiltin_seed_policy = "auto"\n',
      );
    });

    testWidgets('the switch says when the change reaches a running node', (
      tester,
    ) async {
      // A control that silently does nothing until the next node start, on a
      // screen whose status card says "Connected", is a promise of its own.
      await setBundledSeedsAllowed(true);
      await tester.pumpWidget(host(capture: (_) {}));
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(SharedSeedsSwitch)));
      expect(find.text(l.routeAppliesNextStart), findsOneWidget);
    });
  });

  group('the promise the onboarding step makes resolves to a control', () {
    // The class of defect this catches: a sentence that names a destination,
    // and a destination that does not carry what the sentence promised. The
    // route object below is the APP'S OWN — read out of the router the app
    // builds — so the assertion is about where a person actually lands.

    testWidgets('the step promises it, and /network carries it', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [appControllerProvider.overrideWith(_ReadyAppController.new)],
      );
      addTearDown(container.dispose);
      final networkRoute = container
          .read(routerProvider)
          .configuration
          .routes
          .whereType<GoRoute>()
          .firstWhere(
            (r) => r.path == '/network',
            orElse: () => throw StateError(
              'the app registers no /network route, so the onboarding step '
              'names a destination that does not exist',
            ),
          );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._bootOverrides,
            nodeStatusProvider.overrideWith(
              (ref) => Stream.value(const NodeStatus(phase: NodePhase.offline)),
            ),
          ],
          child: MaterialApp.router(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            routerConfig: GoRouter(
              initialLocation: '/network',
              routes: [networkRoute],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byType(SharedSeedsSwitch),
        findsOneWidget,
        reason: 'the onboarding step tells people the answer can be changed '
            'in Network settings; this is that control',
      );
      final l = AppL10n.of(tester.element(find.byType(SharedSeedsSwitch)));
      expect(find.text(l.seedsSwitchTitle), findsOneWidget);
    });
  });

  group('the decline warning is not below the fold', () {
    // Found on a real 407x904 phone: picking the private answer pushed the red
    // consequence under the Continue button, its last line cut mid-glyph, with
    // nothing saying the region scrolled. It was reachable — which is the
    // problem, because it is precisely the sentence someone can act without
    // ever having seen.

    Future<AppL10n> toSeedsStep(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: const OnboardingScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      AppL10n l() => AppL10n.of(tester.element(find.byType(OnboardingScreen)));
      await tester.tap(find.text(l().actionContinue));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l().onboardCreateIdentity));
      await tester.pumpAndSettle();
      await confirmRecoveryPhrase(tester, continueLabel: l().actionContinue);
      await tester.tap(find.text(l().actionContinue));
      await tester.pumpAndSettle();
      expect(find.text(l().seedsChoiceTitle), findsOneWidget);
      return l();
    }

    testWidgets('choosing it puts the consequence on screen at 407x904', (
      tester,
    ) async {
      // The reported device, with the system bars it really has — a viewport
      // measured without them is a screen nobody owns.
      tester.view.physicalSize = const Size(407, 904);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
      addTearDown(tester.view.reset);

      final l = await toSeedsStep(tester);
      await tester.tap(find.text(l.seedsDeclineTitle));
      await tester.pumpAndSettle();

      final warning = tester.getRect(find.text(l.seedsNoNodeBody));
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final button = tester.getRect(
        find.widgetWithText(FilledButton, l.actionContinue),
      );

      // Nobody scrolled: the step brought it into view by itself. Asserted as
      // a RANGE rather than a coordinate, so it survives a font, a screen and
      // a translation the layout was never tuned for.
      expect(
        warning.bottom,
        lessThanOrEqualTo(viewport.bottom),
        reason: 'the last line of the consequence is cut off the bottom of the '
            'scroll area — exactly the defect, which reads as a finished '
            'sentence with a shaved final line',
      );
      expect(
        warning.top,
        greaterThanOrEqualTo(viewport.top),
        reason: 'revealing the end of the warning must not push its beginning '
            'off the top',
      );
      expect(
        warning.bottom,
        lessThanOrEqualTo(button.top),
        reason: 'the consequence must be readable above the button that acts '
            'on it, not behind or below it',
      );
    });

    testWidgets('the region says it scrolls, before anything is chosen', (
      tester,
    ) async {
      // The other half of the report: no scroll cue. A thumb that is only
      // painted while a finger is down tells nobody anything.
      tester.view.physicalSize = const Size(407, 904);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
      addTearDown(tester.view.reset);

      await toSeedsStep(tester);
      final bar = tester.widget<Scrollbar>(find.byType(Scrollbar));
      expect(bar.thumbVisibility, isTrue);
    });
  });

  group('the answer belongs to the identity, not the profile', () {
    // The defect these are for: the answer was a PREFERENCE, and preferences
    // are separated by which file is installed — once per process, per app
    // profile, which the codebase itself documents as a directory choice and
    // not an identity. So one answer was handed to every identity at once: two
    // could not disagree, the last write won for all of them, and a duress
    // master — another space in the SAME container — inherited the real
    // identity's network posture, which is the one thing a decoy must not do.
    //
    // Every assertion below therefore names WHICH identity, and the profile
    // preference is deliberately left saying the opposite of the space, so a
    // path that still reads the old key cannot pass.

    /// One identity's storage view over a hosted space.
    Storage viewOf(FakeMultiSpaceBacking backing, Uint8List keys) =>
        HiddenVolumeStorage.fromStore(
          MultiSpaceKvLogStore(backing, backing.openSpace(keys)),
        );

    test(
      'ALL-ONLINE: a refuser and an allower boot from one container, and each '
      'node is composed with its OWN answer',
      () async {
        // The profile says YES, loudly, so nothing here can pass by reading it.
        SharedPreferences.setMockInitialValues({
          'network.bundled_seeds.v1': true,
        });
        final backing = FakeMultiSpaceBacking();
        await viewOf(
          backing,
          _spaceKeys(1),
        ).putSetting(kBundledSeedsSettingKey, 'false');
        await viewOf(
          backing,
          _spaceKeys(2),
        ).putSetting(kBundledSeedsSettingKey, 'true');

        final booted = <String, IdentityBootSpec>{};
        final session = MultiIdentitySession(
          SyncWrappedAsyncMultiSpaceBacking(backing),
          runtimeDirBase: '/run',
          listenPortBase: 9000,
          // What main() hands down: the two halves, kept apart, so each
          // identity's list is BUILT from its own answer.
          peersFor: (allowed) => resolveBootstrapPeers(
            operatorPeers: const [_mine],
            bundledSeeds: const [_seed1, _seed2],
            useBundledSeeds: allowed,
          ),
          boot: (spec, storage) async {
            booted[spec.label] = spec;
            return IdentityNode(
              transport: _NoopTransport(),
              dispose: () async {},
            );
          },
        );
        addTearDown(session.disposeAll);

        await session.bootAll([
          RosterEntry(label: 'refuser', spaceKeys: _spaceKeys(1)),
          RosterEntry(label: 'allower', spaceKeys: _spaceKeys(2)),
        ]);

        // The refuser's node is handed NO shared descriptor — not a filtered
        // list, no list containing them at all — and is forbidden the
        // compiled-in ones, which is the half an empty list cannot express.
        expect(
          booted['refuser']!.bootstrapPeers.map((p) => p.publicKey),
          ['MINE='],
          reason: 'an identity that refused the shared seeds was handed them '
              'because another identity in the same container had not',
        );
        expect(booted['refuser']!.useBundledSeeds, isFalse);
        expect(
          EmbeddedNode.withBuiltinSeedPolicy(
            '[global]\nbuiltin_seed_policy = "auto"\n',
            booted['refuser']!.useBundledSeeds,
          ),
          contains('builtin_seed_policy = "never"'),
        );

        // ...and the allower, in the same container and the same session, gets
        // them. Both halves, or "nobody gets seeds" would pass this too.
        expect(booted['allower']!.bootstrapPeers.map((p) => p.publicKey), [
          'MINE=',
          'SEED1=',
          'SEED2=',
        ]);
        expect(booted['allower']!.useBundledSeeds, isTrue);
      },
    );

    test('ONE-ACTIVE: the boot composes the ACTIVE identity of the container, '
        'and a second identity in the same container disagrees', () async {
      // Two passwords over one FakeHvContainer is the real/decoy master shape:
      // two spaces, one file, one process, one preference file.
      SharedPreferences.setMockInitialValues({
        'onboarded': true,
        // Again the opposite of what the refusing space says.
        'network.bundled_seeds.v1': true,
      });
      final container = FakeHvContainer();
      Future<void> seedSpace(String password, bool allowed) async {
        final s = container.storage();
        await s.open(password: password, createIfMissing: true);
        await s.saveProfile(UserProfile(displayName: password));
        await s.putSetting(
          kBundledSeedsSettingKey,
          allowed ? 'true' : 'false',
        );
        await s.close();
      }

      await seedSpace('refuserpw', false);
      await seedSpace('allowerpw', true);

      final c = ProviderContainer(
        overrides: [
          singleSpaceStorageProvider.overrideWith((ref) => container.storage()),
          deniableBootProvider.overrideWithValue(
            const DeniableBootConfig(
              runtimeDir: '/run',
              listenPort: 9000,
              storePath: '/x',
              operatorPeers: [_mine],
              bundledSeeds: [_seed1, _seed2],
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final ctrl = c.read(appControllerProvider.notifier);
      IdentitySeedPlan? planned;
      ctrl.debugDeniableStackStarter = (plan) async {
        planned = plan;
        return RealVeilStack.overParts(
          controller: _NoopNode(),
          transport: _NoopTransport(),
          myInvite: BootstrapInvite(
            publicKey: Uint8List(32),
            nonce: Uint8List(8),
          ),
        );
      };
      for (var i = 0;
          i < 40 &&
              c.read(appControllerProvider).phase == AppPhase.bootstrapping;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      await ctrl.unlock('refuserpw');
      expect(planned, isNotNull, reason: 'the one-active boot never ran');
      expect(planned!.useBundledSeeds, isFalse);
      expect(planned!.bootstrapPeers.map((p) => p.publicKey), ['MINE=']);
      // The live value the screens render follows the identity that booted.
      expect(c.read(bundledSeedsChoiceProvider), isFalse);

      // The other identity in the SAME container, in the same process, on the
      // same preference file: it kept the seeds and it still has them.
      planned = null;
      await ctrl.lock();
      await ctrl.unlock('allowerpw');
      expect(planned, isNotNull, reason: 'the second boot never ran');
      expect(planned!.useBundledSeeds, isTrue);
      expect(planned!.bootstrapPeers.map((p) => p.publicKey), [
        'MINE=',
        'SEED1=',
        'SEED2=',
      ]);
      expect(c.read(bundledSeedsChoiceProvider), isTrue);
    });

    test('a decoy master and the real master in one container do not share the '
        'answer', () async {
      // The rationale the shipped code carried — "one file per profile is what
      // keeps a decoy from inheriting the real identity's network posture" —
      // was untrue of the decoy this app actually creates: `createDecoyMaster`
      // opens a space in the SAME container, out of the same profile directory.
      SharedPreferences.setMockInitialValues({});
      final container = FakeHvContainer();
      // Only one space may be open at a time — the container's exclusive lock,
      // which is exactly why this is not two containers.
      Future<T> inSpace<T>(
        String password,
        Future<T> Function(Storage s) body,
      ) async {
        final s = container.storage();
        await s.open(password: password, createIfMissing: true);
        try {
          return await body(s);
        } finally {
          await s.close();
        }
      }

      // The real identity refuses. The decoy has never been asked.
      await inSpace('realpw', (s) => setBundledSeedsAllowedFor(s, false));
      expect(await inSpace('realpw', bundledSeedsAllowedFor), isFalse);
      expect(
        await inSpace('duresspw', bundledSeedsAllowedFor),
        isTrue,
        reason: 'the decoy inherited the real identity\'s network posture — '
            'the deniability failure the per-profile file was claimed to '
            'prevent and in fact caused',
      );

      // And it holds in both directions, once each has answered.
      await inSpace('duresspw', (s) => setBundledSeedsAllowedFor(s, false));
      expect(await inSpace('realpw', bundledSeedsAllowedFor), isFalse);
      await inSpace('realpw', (s) => setBundledSeedsAllowedFor(s, true));
      expect(
        await inSpace('duresspw', bundledSeedsAllowedFor),
        isFalse,
        reason: 'the last write won for every identity at once',
      );
      // Nothing of either answer is left in the preference file, where a
      // forensic tool reads it without opening any container.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kBundledSeedsPrefKey), isNull);
    });

    test('a space that never answered adopts the pre-unlock answer ONCE, then '
        'owns it', () async {
      // The migration. An upgrade must not put an identity that declined back
      // on the shared seeds — only the preference remembers that it declined —
      // and it must not keep tracking the preference afterwards.
      SharedPreferences.setMockInitialValues({
        'network.bundled_seeds.v1': false,
      });
      final backing = FakeMultiSpaceBacking();
      final space = viewOf(backing, _spaceKeys(7));
      expect(await bundledSeedsAllowedFor(space), isFalse);
      expect(await space.getSetting(kBundledSeedsSettingKey), 'false');

      // The preference moves (another identity answers pre-unlock). This space
      // has its own answer now and does not follow.
      await setBundledSeedsAllowed(true);
      expect(await bundledSeedsAllowedFor(space), isFalse);
    });

    testWidgets('the SWITCH writes the active identity, and nothing else', (
      tester,
    ) async {
      // Two spaces in one container, one of them active. The control must
      // answer for that one alone — it used to write a preference every
      // identity in the process then read.
      SharedPreferences.setMockInitialValues({});
      final backing = FakeMultiSpaceBacking();
      final active = viewOf(backing, _spaceKeys(1));
      final other = viewOf(backing, _spaceKeys(2));
      await active.putSetting(kBundledSeedsSettingKey, 'true');
      await other.putSetting(kBundledSeedsSettingKey, 'true');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._bootOverrides,
            singleSpaceStorageProvider.overrideWith((ref) => active),
          ],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: const Scaffold(
              body: SingleChildScrollView(child: SharedSeedsSwitch()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(
        await active.getSetting(kBundledSeedsSettingKey),
        'false',
        reason: 'the refusal never reached the identity whose node is composed '
            'from it',
      );
      expect(
        await other.getSetting(kBundledSeedsSettingKey),
        'true',
        reason: 'one identity answered for another — the defect exactly: the '
            'last write won for every identity at once',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(kBundledSeedsPrefKey),
        isNull,
        reason: 'the answer was left in the profile preference file, where the '
            'next identity with none of its own inherits it and a forensic '
            'tool reads it without opening any container',
      );
    });

    testWidgets('the RE-OFFER writes the active identity too', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final backing = FakeMultiSpaceBacking();
      final active = viewOf(backing, _spaceKeys(1));
      final other = viewOf(backing, _spaceKeys(2));
      await active.putSetting(kBundledSeedsSettingKey, 'false');
      await other.putSetting(kBundledSeedsSettingKey, 'false');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._bootOverrides,
            singleSpaceStorageProvider.overrideWith((ref) => active),
          ],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: const Scaffold(body: BundledSeedsReofferDialog()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppL10n.of(tester.element(find.byType(BundledSeedsReofferDialog)));
      await tester.tap(find.text(l.seedsReofferUse));
      await tester.pumpAndSettle();

      expect(await active.getSetting(kBundledSeedsSettingKey), 'true');
      expect(await other.getSetting(kBundledSeedsSettingKey), 'false');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kBundledSeedsPrefKey), isNull);
    });

    test('a store that will not answer moves no switch', () async {
      // The control's read, which must differ from the boot's on failure only.
      SharedPreferences.setMockInitialValues({
        'network.bundled_seeds.v1': false,
      });
      final refusing = _RefusingStorage();
      expect(await storedBundledSeedsAnswerFor(refusing), isNull);
      // ...while a node config, which has to be composed either way, falls back
      // to the historical behaviour rather than to the opt-out.
      expect(await bundledSeedsAllowedFor(refusing), isFalse);
      expect(await setBundledSeedsAllowedFor(refusing, true), isFalse);
    });
  });

  group('a process with no preference store at all', () {
    // The headless daemon. `bundled_seeds.dart` used to reach for
    // SharedPreferences, and because `lib/data/veil_stack.dart` imports it, the
    // daemon's AOT build died on `dart:ui` while every app build stayed green
    // (709f3b9). The preference half now lives in `bundled_seeds_prefs.dart`
    // and the daemon resolves its answer from the only two things it really
    // has: what its config file said, and what the identity's own space says.
    //
    // These are about the second one. The preference is deliberately left
    // saying the opposite, so a path that still reads it cannot pass.

    Storage viewOf(FakeMultiSpaceBacking backing, Uint8List keys) =>
        HiddenVolumeStorage.fromStore(
          MultiSpaceKvLogStore(backing, backing.openSpace(keys)),
        );

    test('the identity\'s own answer wins over the fallback, both ways', () async {
      SharedPreferences.setMockInitialValues({
        'network.bundled_seeds.v1': true,
      });
      final backing = FakeMultiSpaceBacking();
      final refuser = viewOf(backing, _spaceKeys(11));
      await refuser.putSetting(kBundledSeedsSettingKey, 'false');
      expect(
        await bundledSeedsAllowedFromSpace(refuser, ifUnanswered: true),
        isFalse,
        reason: 'a daemon starting up must not undo a refusal recorded in the '
            'container just because its own config said nothing',
      );

      final allower = viewOf(backing, _spaceKeys(12));
      await allower.putSetting(kBundledSeedsSettingKey, 'true');
      expect(
        await bundledSeedsAllowedFromSpace(allower, ifUnanswered: false),
        isTrue,
      );
    });

    test('a space that never answered takes the fallback and WRITES NOTHING', () async {
      // Unlike the app's read, which migrates the preference into the space on
      // first sight. A daemon has nothing to migrate FROM, and freezing a
      // fallback into the container would answer a question nobody asked — the
      // config file it came from can say something different tomorrow.
      SharedPreferences.setMockInitialValues({
        'network.bundled_seeds.v1': false,
      });
      final backing = FakeMultiSpaceBacking();
      final space = viewOf(backing, _spaceKeys(13));
      expect(
        await bundledSeedsAllowedFromSpace(space, ifUnanswered: true),
        isTrue,
        reason: 'the preference belongs to an app profile the daemon is not',
      );
      expect(
        await space.getSetting(kBundledSeedsSettingKey),
        isNull,
        reason: 'reading a config is not answering the question',
      );
      expect(
        await bundledSeedsAllowedFromSpace(space, ifUnanswered: false),
        isFalse,
        reason: 'and the next boot is still free to be told otherwise',
      );
    });

    test('a store that will not answer takes the fallback too', () async {
      // Same reasoning as `bundledSeedsAllowedFor`: a node config has to be
      // composed one way or the other, so an unreadable space resolves to what
      // the caller said rather than to the opt-out.
      expect(
        await bundledSeedsAllowedFromSpace(
          _RefusingStorage(),
          ifUnanswered: true,
        ),
        isTrue,
      );
    });

    test('the daemon boot HANDS its config answer to the stack', () {
      // Read off the source because there is no seam to inject: `start` opens a
      // real container and dials FFI before it composes anything. What can go
      // wrong is small and specific — the argument is dropped, and then
      // `use_bundled_seeds` in an operator's config file is parsed, carried,
      // and silently ignored, which is worse than not having the key.
      final source = File(
        'lib/headless/headless_runtime.dart',
      ).readAsStringSync();
      final call = RegExp(
        r'RealVeilStack\.startDeniable\((?<args>[\s\S]*?)\n      \);',
      ).firstMatch(source);
      expect(call, isNotNull, reason: 'the daemon no longer starts a stack?');
      expect(
        call!.namedGroup('args'),
        contains('useBundledSeeds: config.useBundledSeeds'),
        reason: 'the daemon must pass what its config file said (and the null '
            'that means it said nothing) — dropping it leaves the key parsed, '
            'documented and inert',
      );
    });
  });

  group('the wording states whose answer it is', () {
    // The strings said the opposite of what the code did: "nobody else's server
    // learns that THIS IDENTITY exists" over a device-wide preference, and two
    // switch subtitles that named no scope at all. The scope is now real, and
    // these assert that it is also SAID — in every locale, because a translated
    // string that drops the clause is the same defect in another language.
    const scope = {'en': 'this identity', 'ru': 'этой личности', 'es': 'esta identidad'};
    const others = {
      'en': 'other identities are unaffected',
      'ru': 'другие ваши личности это не затрагивает',
      'es': 'otras identidades no se ven afectadas',
    };

    for (final entry in scope.entries) {
      testWidgets('${entry.key}: the switch subtitles name the identity', (
        tester,
      ) async {
        final l = await AppL10n.delegate.load(Locale(entry.key));
        expect(
          l.seedsSwitchOnSub.toLowerCase(),
          contains(entry.value),
          reason: 'the ON subtitle states no scope, so a device-wide reading '
              'is the natural one',
        );
        expect(l.seedsSwitchOffSub.toLowerCase(), contains(entry.value));
      });

      testWidgets('${entry.key}: declining says how far the refusal reaches', (
        tester,
      ) async {
        final l = await AppL10n.delegate.load(Locale(entry.key));
        expect(l.seedsDeclineBody.toLowerCase(), contains(entry.value));
        expect(
          l.seedsDeclineBody.toLowerCase(),
          contains(others[entry.key]!),
          reason: 'the promise was "nobody else\'s server learns that this '
              'identity exists" while the answer was shared with every other '
              'identity on the device; saying whose answer it is IS the fix',
        );
      });

      testWidgets('${entry.key}: the re-offer says whom it answers for', (
        tester,
      ) async {
        final l = await AppL10n.delegate.load(Locale(entry.key));
        expect(l.seedsReofferBody.toLowerCase(), contains(entry.value));
      });
    }
  });
}

/// Deterministic space keys, distinct per seed — one hosted space each.
Uint8List _spaceKeys(int seed) => Uint8List.fromList(List.filled(64, seed));

/// A transport that does nothing: the boots under test are faked, and a real
/// one would leave timers running past the test.
class _NoopTransport implements VeilTransport {
  final _c = StreamController<InboundMessage>.broadcast();

  @override
  Future<NodeId> nodeId() async => NodeId(Uint8List(32));
  @override
  Stream<InboundMessage> messages() => _c.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
  @override
  Stream<int> sessionCount() => const Stream.empty();
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _c.close();
}

/// An open space that takes settings — enough for the re-offer's write to
/// succeed, so what happens NEXT is what is under test.
class _OpenSettingStorage extends FakeSettingStorage {
  @override
  bool get isOpen => true;
}

/// A ready session whose node will not come back. Not a stub for the reboot —
/// the reboot's real behaviour is asserted above, against real boots; this is
/// the branch where it fails, which no fake node can produce on demand.
class _RebootRefusingAppController extends AppController {
  @override
  AppState build() => AppState(
    AppPhase.ready,
    identity: Identity(nodeId: NodeId(Uint8List(32))),
  );

  @override
  Future<bool> rebootHostedNodes() async => false;
}

/// A space that is open and will not answer — a damaged container, not an
/// unanswered one. The two must not be handled alike: the second inherits the
/// pre-unlock answer, and doing that on the first would write another
/// identity's posture into this space for good.
class _RefusingStorage extends FakeSettingStorage {
  @override
  bool get isOpen => true;
  @override
  Future<String?> getSetting(String key) async => throw StateError('unreadable');
  @override
  Future<void> putSetting(String key, String value) async =>
      throw StateError('unwritable');
}
