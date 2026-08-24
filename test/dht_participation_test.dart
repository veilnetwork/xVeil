import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/network/network_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/data/node/dht_participation.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

/// Whether this device does DHT work for OTHER people.
///
/// Measured 18.08.2026: an idle client received 13.6 KB/s, 85% of it work for
/// strangers, against three bytes per second of its own traffic — 5 GB a day
/// on a phone. The service budget shipped before this refuses half that work
/// and changed the traffic by nothing, because the bytes arrive before any
/// local decision. Only the advertised refusal can help.
SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

void main() {
  // Without the binding + a prefs mock the widget half hangs rather than
  // failing: something in the tree reaches a platform channel nobody answers,
  // and `pumpAndSettle` waits for a frame that never comes.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  switchTests();
  const base =
      '[identity]\n'
      'public_key = "pk"\n'
      '\n'
      '[global]\n'
      'runtime_flavor = "multi_thread"\n';

  group('config composition', () {
    test('the choice reaches the config either way', () {
      expect(
        EmbeddedNode.withDhtParticipation(base, participate: false),
        contains('participate = false'),
      );
      expect(
        EmbeddedNode.withDhtParticipation(base, participate: true),
        contains('participate = true'),
        reason:
            'written even though true is veil\'s own default, so the '
            'composed config says what it means and a flip shows in a diff',
      );
    });

    /// The composed config is built by nesting helpers, so `[dht]` may already
    /// exist by the time this one runs. A second `[dht]` table is a TOML the
    /// native parser rejects — the node then fails to start, which is a worse
    /// outcome than any amount of traffic.
    test('an existing dht table is extended, not duplicated', () {
      const withDht = '[identity]\npublic_key = "pk"\n\n[dht]\nk = 20\n';
      final out = EmbeddedNode.withDhtParticipation(
        withDht,
        participate: false,
      );
      expect('[dht]'.allMatches(out).length, 1);
      expect(out, contains('k = 20'));
      expect(out, contains('participate = false'));
    });

    test('applying it twice leaves exactly one setting', () {
      final once = EmbeddedNode.withDhtParticipation(base, participate: false);
      final twice = EmbeddedNode.withDhtParticipation(once, participate: true);
      expect('participate'.allMatches(twice).length, 1);
      expect(twice, once, reason: 'the first answer stands');
    });

    /// The two knobs are different questions and must not collide in the
    /// composed TOML: one refuses work locally, the other asks peers not to
    /// send it.
    test('it coexists with the service budget', () {
      final out = EmbeddedNode.withMobileServiceBudget(
        EmbeddedNode.withDhtParticipation(base, participate: false),
        isMobile: true,
      );
      expect('[dht]'.allMatches(out).length, 1);
      expect(out, contains('participate = false'));
      expect(out, contains('service_budget_bytes_per_hour'));
    });
  });

  group('the stored answer', () {
    late HiddenVolumeStorage storage;

    setUp(() async {
      storage = HiddenVolumeStorage(_memOpener());
      await storage.open(password: 'p', createIfMissing: true);
    });

    tearDown(() async => storage.close());

    /// Tri-state on purpose. A device that never chose has to keep following
    /// the platform default even if that default changes later; a device that
    /// explicitly chose has to keep its choice even if the default flips under
    /// it. Collapsing the two at read time overwrites a real choice with a
    /// policy decision made afterwards.
    test('never asked is distinguishable from answered', () async {
      expect(await dhtParticipationAnswer(storage), isNull);
      expect(
        await dhtParticipationEffective(storage),
        kDhtParticipationDefault,
      );

      expect(await setDhtParticipation(storage, true), isTrue);
      expect(await dhtParticipationAnswer(storage), isTrue);
      expect(await dhtParticipationEffective(storage), isTrue);

      expect(await setDhtParticipation(storage, false), isTrue);
      expect(await dhtParticipationAnswer(storage), isFalse);
      expect(await dhtParticipationEffective(storage), isFalse);
    });

    /// Reading must never write: a resolved default is not an answer, and
    /// freezing it would make tomorrow's default unable to reach a device that
    /// simply never chose.
    test('reading the default does not answer the question', () async {
      await dhtParticipationEffective(storage);
      await dhtParticipationEffective(storage);
      expect(await dhtParticipationAnswer(storage), isNull);
    });

    /// The failure this setting cannot afford: an explicit OFF that quietly
    /// becomes ON.
    ///
    /// A throw from an OPEN store was swallowed into the same `null` as "never
    /// asked", and on desktop `null` resolves to the platform default, `true`.
    /// So a transient storage fault booted a node that had opted OUT as one
    /// serving the DHT for strangers — the unpaid work this whole setting
    /// exists to stop — while the UI still showed the choice that was made.
    test('a read fault does not turn serving back on', () async {
      final faulty = _FakeStorage()
        ..settings[kDhtParticipationSettingKey] = 'false'
        ..readThrows = true;

      expect(
        faulty.isOpen,
        isTrue,
        reason: 'a fault on an OPEN store, not the closed-store lifecycle case',
      );
      expect(
        await dhtParticipationEffective(faulty),
        isFalse,
        reason: 'an answer that could not be read must not resolve to serving',
      );
      expect(
        await dhtParticipationUnreadable(faulty),
        isTrue,
        reason: 'and the fault is nameable, not folded into "never asked"',
      );
    });

    /// The same store, healthy, still follows the platform default when the
    /// question was genuinely never asked — the fix must not turn every
    /// unanswered device off.
    test('a healthy store with no answer still takes the default', () async {
      final healthy = _FakeStorage();
      expect(await dhtParticipationUnreadable(healthy), isFalse);
      expect(
        await dhtParticipationEffective(healthy),
        kDhtParticipationDefault,
      );
    });

    /// A switch that silently did not stick is worse than one that reports it.
    test('a closed store refuses the write and reads as unanswered', () async {
      await storage.close();
      expect(await setDhtParticipation(storage, false), isFalse);
      expect(await dhtParticipationAnswer(storage), isNull);
      expect(
        await dhtParticipationEffective(storage),
        kDhtParticipationDefault,
      );
    });
  });
}

/// The switch, end to end: what it shows, what it writes, and what a refused
/// write does. Thin wiring is exactly what looks identical whether it works or
/// not — a switch that moves and stores nothing renders the same as one that
/// works.
///
/// A settings-only fake, not the real container: `HiddenVolumeStorage.open`
/// does real file work, and real I/O inside `testWidgets` does not fail — it
/// HANGS, for ten minutes, on a frame that never comes. The pure group above
/// exercises the real store, where a plain `test` can await it honestly.
class _FakeStorage implements Storage {
  final settings = <String, String>{};
  bool unlocked = true;

  /// A store that answers instantly cannot show the gap this widget exists to
  /// cover, so the one test about that gap widens it deliberately.
  Duration readDelay = Duration.zero;

  /// An OPEN store whose read fails. Distinct from `unlocked = false`, which
  /// is a lifecycle state the switch is allowed to meet before unlock.
  bool readThrows = false;

  @override
  bool get isOpen => unlocked;

  @override
  Future<void> putSetting(String key, String value) async {
    if (!unlocked) throw StateError('storage is locked');
    settings[key] = value;
  }

  @override
  Future<String?> getSetting(String key) async {
    if (!unlocked) throw StateError('storage is locked');
    if (readThrows) throw StateError('read fault');
    if (readDelay > Duration.zero) await Future<void>.delayed(readDelay);
    return settings[key];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void switchTests() {
  Widget host(_FakeStorage storage) => ProviderScope(
    overrides: [storageProvider.overrideWithValue(storage)],
    child: MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: const Scaffold(body: ServeDhtSwitch()),
    ),
  );

  final tile = find.byKey(const ValueKey('serve-dht-switch'));

  testWidgets('the switch shows the store and writes it back', (tester) async {
    final storage = _FakeStorage();
    // Explicitly the OPPOSITE of the platform default, so a switch that
    // ignored the store and rendered the default would fail here.
    storage.settings[kDhtParticipationSettingKey] = kDhtParticipationDefault
        ? 'false'
        : 'true';

    await tester.pumpWidget(host(storage));
    await tester.pumpAndSettle();

    expect(tile, findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(tile).value,
      !kDhtParticipationDefault,
      reason: 'it must render the STORED answer, not the platform default',
    );

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(
      storage.settings[kDhtParticipationSettingKey],
      kDhtParticipationDefault ? 'true' : 'false',
      reason: 'the flip has to reach the store the node boots from',
    );
    expect(tester.widget<SwitchListTile>(tile).value, kDhtParticipationDefault);
  });

  /// A switch that moved but stored nothing would promise a posture no node
  /// will ever boot with — the exact shape of lie the control exists to avoid.
  testWidgets('a refused write leaves the switch where it was', (tester) async {
    final storage = _FakeStorage();
    storage.settings[kDhtParticipationSettingKey] = 'true';

    await tester.pumpWidget(host(storage));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);

    storage.unlocked = false;
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(
      tester.widget<SwitchListTile>(tile).value,
      isTrue,
      reason: 'nothing was saved, so nothing may appear to have changed',
    );
    expect(find.byType(SnackBar), findsOneWidget);
  });

  /// Nothing is shown until the store answers: rendering the platform default
  /// first and correcting it a frame later shows people their switch moving on
  /// its own.
  testWidgets('it renders nothing before the store answers', (tester) async {
    final storage = _FakeStorage()..readDelay = const Duration(seconds: 1);
    await tester.pumpWidget(host(storage));
    await tester.pump();
    expect(
      tile,
      findsNothing,
      reason:
          'a switch rendered at the platform default and corrected a '
          'frame later is a switch people watch move on its own',
    );
    // `pumpAndSettle` returns at once here: a pending timer with no animation
    // schedules no frames, so nothing settles and the clock never moves. The
    // duration is what advances it.
    await tester.pump(const Duration(seconds: 2));
    expect(tile, findsOneWidget);
  });
}
