import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:xveil/core/ids.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/bundled_seeds.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/features/network/network_screen.dart';
import 'package:xveil/features/onboarding/bundled_seeds_choice.dart';
import 'package:xveil/features/onboarding/onboarding_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/routing/router.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/managed_nodes_controller.dart';
import 'package:xveil/state/providers.dart';

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

  group('the answer is persisted for the identity that gave it', () {
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

    testWidgets('accepting after all puts the identity back on the seeds', (
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

      // Survives a restart, per identity, under the key a wipe clears.
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
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l().actionContinue));
      await tester.pumpAndSettle();
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
}
