import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/bundled_seeds.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/features/onboarding/bundled_seeds_choice.dart';
import 'package:xveil/l10n/app_localizations.dart';
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
  transport: 'obfs4-tcp://198.51.100.11:5556',
  publicKey: 'SEED1=',
  nonce: 'N1=',
);
const _seed2 = BootstrapPeerCfg(
  transport: 'obfs4-tcp://198.51.100.11:5556',
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
}
