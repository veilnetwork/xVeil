import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/screen_lock.dart';
import 'package:xveil/features/chat/notification_binder.dart';
import 'package:xveil/features/lock/screen_lock_overlay.dart';
import 'package:xveil/features/settings/privacy_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/screen_lock_controller.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// Every label the platform would hand to VoiceOver / TalkBack, read out of the
/// SEMANTICS tree rather than the widget tree.
///
/// The distinction is the entire bug: the widget tree and the pixels agreed
/// that the chat was covered while the accessibility tree — a separate tree,
/// which is what a screen reader actually walks — still carried every message
/// and every button under it. A `tester.tap` test cannot see that, because the
/// opaque cover really does eat the pointer.
List<String> _accessibleLabels(WidgetTester tester) {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    final label = node.getSemanticsData().label;
    if (label.isNotEmpty) labels.add(label);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.getSemantics(find.byType(MaterialApp)));
  return labels;
}

final _self = _id(1);
final _peer = _id(2);

class _InjectableTransport implements VeilTransport {
  final _inbound = StreamController<InboundMessage>.broadcast();

  void inject(InboundMessage message) => _inbound.add(message);

  @override
  Future<NodeId> nodeId() async => _self;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async {}
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

/// Records what reached the OS instead of posting it.
class _CapturingNotifications extends NotificationService {
  final shown = <({String title, String body})>[];

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? replyLabel,
    String? replyHint,
  }) async {
    shown.add((title: title, body: body));
  }
}

class _ReadyAppController extends AppController {
  @override
  AppState build() =>
      AppState(AppPhase.ready, identity: Identity(nodeId: _self));
}

SpaceOpener _memory() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the rule about how long away is too long', () {
    test('off never locks, however long it has been', () {
      expect(
        screenLockDue(
          timeout: ScreenLockTimeout.off,
          awayFor: const Duration(days: 7),
        ),
        isFalse,
      );
    });

    test('immediately locks even at zero', () {
      expect(
        screenLockDue(
          timeout: ScreenLockTimeout.immediately,
          awayFor: Duration.zero,
        ),
        isTrue,
      );
    });

    test('the boundary counts as due, not as one second short', () {
      // `>` instead of `>=` here is the classic way to ship "never locks at
      // exactly the timeout".
      expect(
        screenLockDue(
          timeout: ScreenLockTimeout.fiveMinutes,
          awayFor: const Duration(minutes: 5),
        ),
        isTrue,
      );
      expect(
        screenLockDue(
          timeout: ScreenLockTimeout.fiveMinutes,
          awayFor: const Duration(minutes: 4, seconds: 59),
        ),
        isFalse,
      );
    });

    test('every choice has a distinct meaning', () {
      expect(ScreenLockTimeout.off.after, isNull);
      expect(ScreenLockTimeout.immediately.after, Duration.zero);
      expect(ScreenLockTimeout.oneMinute.after, const Duration(minutes: 1));
      expect(
        ScreenLockTimeout.fifteenMinutes.after,
        const Duration(minutes: 15),
      );
    });

    test('an unknown persisted name falls back to off, not to locking', () {
      expect(screenLockTimeoutFromName('someday'), ScreenLockTimeout.off);
      expect(screenLockTimeoutFromName(null), ScreenLockTimeout.off);
      expect(
        screenLockTimeoutFromName('fiveMinutes'),
        ScreenLockTimeout.fiveMinutes,
      );
    });
  });

  group('the password that lifts it', () {
    test('recognises the one that opened the container, and nothing else', () {
      final verifier = ScreenLockVerifier.forPassword('correct horse');
      expect(verifier.matches('correct horse'), isTrue);
      expect(verifier.matches('correct hors'), isFalse);
      expect(verifier.matches('Correct horse'), isFalse);
      expect(verifier.matches(''), isFalse);
    });

    test('two sessions with the same password do not agree on a value', () {
      // The per-session random key is the whole point: nothing about this
      // survives the process, and it is not a stable function of the password.
      final a = ScreenLockVerifier.forPassword('same');
      final b = ScreenLockVerifier.forPassword('same');
      expect(a.matches('same') && b.matches('same'), isTrue);
      expect(a == b, isFalse);
    });
  });

  group('the controller', () {
    late ProviderContainer container;
    late ScreenLockController controller;
    late DateTime clock;

    setUp(() async {
      final storage = HiddenVolumeStorage(_memory());
      await storage.open(password: 'pw', createIfMissing: true);
      container = ProviderContainer(
        overrides: [storageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      controller = container.read(screenLockProvider.notifier);
      clock = DateTime(2026, 8, 4, 12);
      controller.now = () => clock;
      controller.rememberPassword('pw');
    });

    test('off stays unlocked no matter how long the app is away', () async {
      await controller.setTimeout(ScreenLockTimeout.off);
      controller.onLeftForeground();
      clock = clock.add(const Duration(hours: 9));
      controller.onReturnedToForeground();
      expect(container.read(screenLockProvider).locked, isFalse);
    });

    test('immediately locks as the app leaves', () async {
      await controller.setTimeout(ScreenLockTimeout.immediately);
      controller.onLeftForeground();
      expect(container.read(screenLockProvider).locked, isTrue);
    });

    test('a timeout waits for the time to actually pass', () async {
      await controller.setTimeout(ScreenLockTimeout.fiveMinutes);
      controller.onLeftForeground();
      clock = clock.add(const Duration(minutes: 2));
      controller.onReturnedToForeground();
      expect(
        container.read(screenLockProvider).locked,
        isFalse,
        reason: 'two minutes away under a five-minute setting must not lock',
      );

      controller.onLeftForeground();
      clock = clock.add(const Duration(minutes: 6));
      controller.onReturnedToForeground();
      expect(container.read(screenLockProvider).locked, isTrue);
    });

    test('a bounce out and back does not restart the clock', () async {
      // `inactive` arrives for a notification shade pull as well as a real
      // switch away. Resetting the stamp on every one of them would mean a
      // phone that is poked once a minute never locks.
      await controller.setTimeout(ScreenLockTimeout.fiveMinutes);
      controller.onLeftForeground();
      clock = clock.add(const Duration(minutes: 3));
      controller.onLeftForeground();
      clock = clock.add(const Duration(minutes: 3));
      controller.onReturnedToForeground();
      expect(container.read(screenLockProvider).locked, isTrue);
    });

    test('the wrong password does not lift it; the right one does', () async {
      await controller.setTimeout(ScreenLockTimeout.immediately);
      controller.onLeftForeground();
      expect(controller.tryUnlock('not it'), isFalse);
      expect(container.read(screenLockProvider).locked, isTrue);
      expect(container.read(screenLockProvider).wrongPassword, isTrue);

      expect(controller.tryUnlock('pw'), isTrue);
      expect(container.read(screenLockProvider).locked, isFalse);
      expect(container.read(screenLockProvider).wrongPassword, isFalse);
    });

    test('a session that never saw a password cannot be locked out', () async {
      // A headless boot or a test harness opens the container by other means.
      // Locking it behind a prompt nobody can answer would be a way to brick
      // the app, not to protect it.
      final storage = HiddenVolumeStorage(_memory());
      await storage.open(password: 'pw', createIfMissing: true);
      final bare = ProviderContainer(
        overrides: [storageProvider.overrideWithValue(storage)],
      );
      addTearDown(bare.dispose);
      final fresh = bare.read(screenLockProvider.notifier);
      await fresh.setTimeout(ScreenLockTimeout.immediately);
      fresh.onLeftForeground();
      expect(bare.read(screenLockProvider).locked, isFalse);
    });

    test('locking the volume forgets the screen lock with it', () async {
      await controller.setTimeout(ScreenLockTimeout.immediately);
      controller.onLeftForeground();
      expect(container.read(screenLockProvider).locked, isTrue);

      controller.forgetSession();
      expect(container.read(screenLockProvider).locked, isFalse);
      // And the old password no longer opens anything — the next session may
      // be a different identity entirely.
      controller.onLeftForeground();
      expect(container.read(screenLockProvider).locked, isFalse);
    });

    test('the choice survives a reload of the controller', () async {
      await controller.setTimeout(ScreenLockTimeout.fifteenMinutes);
      container.invalidate(screenLockProvider);
      // Reading rebuilds it; the persisted load lands a microtask later.
      container.read(screenLockProvider);
      await pumpEventQueue();
      expect(
        container.read(screenLockProvider).timeout,
        ScreenLockTimeout.fifteenMinutes,
      );
    });
  });

  group('the wiring nobody was exercising', () {
    // Every test above hands the controller an ALREADY-OPEN container and calls
    // `rememberPassword` by hand. Production does neither: the host is built
    // from the first frame against a container that is still shut, and the only
    // code that ever says the password is `AppController`. Both halves of
    // IF-01 lived in exactly that gap, with the suite green over them.

    Future<void> settle(ProviderContainer c) async {
      for (
        var i = 0;
        i < 40 && c.read(appControllerProvider).phase == AppPhase.bootstrapping;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test(
      'a timeout saved last run is honoured after the container opens',
      () async {
        // ONE store behind both sessions, so the second one is a restart rather
        // than a fresh install.
        final store = FakeKvLogStore();
        KvLogStore? opener({
          required Uint8List password,
          required bool create,
        }) => store;

        final first = ProviderContainer(
          overrides: [
            storageProvider.overrideWithValue(HiddenVolumeStorage(opener)),
          ],
        );
        final firstController = first.read(appControllerProvider.notifier);
        await settle(first);
        await firstController.completeOnboarding(
          password: 'pw',
          mode: StorageMode.hiddenSpace,
        );
        await first
            .read(screenLockProvider.notifier)
            .setTimeout(ScreenLockTimeout.fiveMinutes);
        await firstController.lock();
        first.dispose();

        // Restart. The host in `MaterialApp.builder` is mounted on the first
        // frame, so the controller is BUILT HERE — against a shut container.
        final second = ProviderContainer(
          overrides: [
            storageProvider.overrideWithValue(HiddenVolumeStorage(opener)),
          ],
        );
        addTearDown(second.dispose);
        final controller = second.read(appControllerProvider.notifier);
        await settle(second);
        expect(
          second.read(screenLockProvider).timeout,
          ScreenLockTimeout.off,
          reason: 'a shut container cannot answer, and must not be asked to',
        );

        // The real path, not an invalidation: the container opens.
        await controller.unlock('pw');
        expect(second.read(appControllerProvider).phase, AppPhase.ready);
        expect(
          second.read(screenLockProvider).timeout,
          ScreenLockTimeout.fiveMinutes,
          reason:
              'the saved choice read as "off" for the whole run — the load '
              'ran once against a locked container and was never retried',
        );
      },
    );

    test('a second space reads its own choice, not the previous one', () async {
      // The notifier survives a lock on the single-identity path (the provider
      // hands back one object), so the "the user has already chosen, do not
      // overwrite" guard would otherwise carry the REAL space's setting into a
      // decoy opened with a different password.
      final spaces = {'a': FakeKvLogStore(), 'b': FakeKvLogStore()};
      KvLogStore? opener({required Uint8List password, required bool create}) =>
          spaces[utf8.decode(password)];
      final c = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(HiddenVolumeStorage(opener)),
        ],
      );
      addTearDown(c.dispose);
      final controller = c.read(appControllerProvider.notifier);
      await settle(c);

      await controller.completeOnboarding(
        password: 'a',
        mode: StorageMode.hiddenSpace,
      );
      await c
          .read(screenLockProvider.notifier)
          .setTimeout(ScreenLockTimeout.fifteenMinutes);
      await controller.lock();

      await controller.completeOnboarding(
        password: 'b',
        mode: StorageMode.hiddenSpace,
      );
      expect(
        c.read(screenLockProvider).timeout,
        ScreenLockTimeout.off,
        reason: 'the second space inherited the first one\'s setting',
      );
    });

    test('the lock can engage in the very first session', () async {
      // Onboarding is the other path that opens a container with a password in
      // hand, and it was the one that never said so. A first session therefore
      // had nothing to check a typed password against, and `_lock` refuses to
      // raise a prompt that cannot be answered — so the setting the user had
      // just chosen did nothing until they restarted the app.
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final controller = c.read(appControllerProvider.notifier);
      await settle(c);
      await controller.completeOnboarding(
        password: 'pw',
        mode: StorageMode.hiddenSpace,
      );

      final lock = c.read(screenLockProvider.notifier);
      await lock.setTimeout(ScreenLockTimeout.immediately);
      lock.onLeftForeground();
      expect(
        c.read(screenLockProvider).locked,
        isTrue,
        reason: 'the first session could not be locked at all',
      );
      expect(
        lock.tryUnlock('pw'),
        isTrue,
        reason: 'and the password that created the container did not lift it',
      );
    });
  });

  group('the cover over the app', () {
    /// Shaped like `lib/app.dart`: the lock host wraps the whole tree and the
    /// notification binder lives INSIDE it, exactly as it lives inside the
    /// router's home shell in production.
    Future<
      ({
        ProviderContainer container,
        _InjectableTransport transport,
        _CapturingNotifications notifications,
        HiddenVolumeStorage storage,
        MessagingService messaging,
      })
    >
    mount(WidgetTester tester, {Widget? body}) async {
      final storage = HiddenVolumeStorage(_memory());
      final transport = _InjectableTransport();
      addTearDown(transport.dispose);
      await storage.open(password: 'pw', createIfMissing: true);
      // STARTED, because an unstarted service never listens to the transport
      // and the delivery this whole group is about would be a fiction.
      final messaging = MessagingService(transport, storage)..start();
      await messaging.acceptContact(_peer);
      final notifications = _CapturingNotifications();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageProvider.overrideWithValue(storage),
            messagingServiceProvider.overrideWithValue(messaging),
            notificationServiceProvider.overrideWithValue(notifications),
            groupServiceProvider.overrideWithValue(null),
            appControllerProvider.overrideWith(_ReadyAppController.new),
          ],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: ScreenLockHost(
              child: NotificationBinder(
                child: Scaffold(body: body ?? const Text('a message')),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      // Disposed by the caller INSIDE the test body: the started service holds
      // periodic timers, and the framework's "a Timer is still pending" check
      // runs before tearDowns do.
      return (
        container: container,
        transport: transport,
        notifications: notifications,
        storage: storage,
        messaging: messaging,
      );
    }

    /// `pumpAndSettle` is unusable here: the messaging service is STARTED (it
    /// has to be, or nothing would arrive), and its periodic timers mean the
    /// scheduler is never idle. Pump a bounded number of frames instead, which
    /// also drains the microtasks the storage futures complete on.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// Deliberately NOT awaited. `dispose` cancels both of the service's
    /// timers synchronously, before its first await — which is all the
    /// framework's "a Timer is still pending" check needs — while the rest of
    /// its teardown awaits work a fake-async test zone will never advance, so
    /// awaiting it hangs the test forever.
    Future<void> shutdown(
      WidgetTester tester,
      MessagingService messaging,
    ) async {
      unawaited(messaging.dispose());
      await tester.pump();
    }

    /// The platform walks the states; it never jumps. Driving `paused` straight
    /// back to `resumed` trips a framework assertion, and — worse for this
    /// feature — while the app is `paused` the binding does not rebuild dirty
    /// widgets at all, so a test that answered the prompt without coming back
    /// first would be testing a state the user is never in.
    Future<void> background(WidgetTester tester) async {
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
    }

    Future<void> foreground(WidgetTester tester) async {
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
    }

    testWidgets('THE point of it: messages keep arriving while locked', (
      tester,
    ) async {
      final app = await mount(tester);
      final lock = app.container.read(screenLockProvider.notifier);
      lock.rememberPassword('pw');
      await lock.setTimeout(ScreenLockTimeout.immediately);

      await background(tester);
      expect(
        find.byType(ScreenLockCover),
        findsOneWidget,
        reason: 'the screen did not lock, so the rest proves nothing',
      );

      // Someone writes to us while the phone is face-down on the table.
      app.transport.inject(
        InboundMessage(
          src: _peer,
          payload: WireEnvelope.message(
            'are you there',
            id: 'while-locked-1',
            sentAtMs: DateTime.now().millisecondsSinceEpoch,
          ).encode(),
          // An honest contact on an authenticated session (audit X/V-01).
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      await settle(tester);

      // Delivery: the message is in the container, not merely announced.
      final stored = await app.storage.loadMessages(_peer.hex);
      expect(
        stored.map((m) => m.body),
        contains('are you there'),
        reason: 'a locked SCREEN must not stop the volume receiving',
      );
      // And the notification actually went out.
      expect(
        app.notifications.shown,
        isNotEmpty,
        reason: 'the shade stayed empty — the lock cost the user delivery',
      );
      // Still locked afterwards: receiving a message is not a way in.
      expect(find.byType(ScreenLockCover), findsOneWidget);
      await shutdown(tester, app.messaging);
    });

    testWidgets('the cover hides what was on screen', (tester) async {
      final app = await mount(tester);
      final lock = app.container.read(screenLockProvider.notifier);
      lock.rememberPassword('pw');
      await lock.setTimeout(ScreenLockTimeout.immediately);

      expect(find.text('a message'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await settle(tester);
      // The tree below is deliberately still mounted — that is what keeps
      // delivery alive — so the cover is the ONLY thing between the chat and
      // whoever is holding the phone. Two things have to be true of it.
      final cover = tester.getRect(find.byType(ScreenLockCover));
      final host = tester.getRect(find.byType(ScreenLockHost));
      expect(cover.size, host.size, reason: 'the cover left an edge showing');

      // And it has to be OPAQUE. A transparent surface is the same size and
      // still swallows taps (the scroll view underneath it does that much on
      // its own), so a size check alone would happily pass a lock screen you
      // can read the last message through.
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(ScreenLockCover),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(
        material.type,
        isNot(MaterialType.transparency),
        reason: 'the chat is visible through the lock screen',
      );
      expect(material.color?.a, 1.0, reason: 'the cover is see-through');
      await shutdown(tester, app.messaging);
    });

    testWidgets('what is underneath cannot be tapped through', (tester) async {
      var tapped = 0;
      final app = await mount(
        tester,
        body: Center(
          child: FilledButton(
            onPressed: () => tapped++,
            child: const Text('delete everything'),
          ),
        ),
      );
      final lock = app.container.read(screenLockProvider.notifier);
      lock.rememberPassword('pw');
      await lock.setTimeout(ScreenLockTimeout.immediately);

      await tester.tap(find.text('delete everything'));
      await tester.pump();
      expect(tapped, 1, reason: 'the fixture itself is broken');

      await background(tester);
      await settle(tester);
      await tester.tap(find.text('delete everything'), warnIfMissed: false);
      await tester.pump();
      expect(
        tapped,
        1,
        reason: 'the lock is a picture of a lock if taps go through it',
      );
      await shutdown(tester, app.messaging);
    });

    testWidgets('a screen reader cannot read the chat through the cover', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final app = await mount(
        tester,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('are you free tonight'),
              FilledButton(
                onPressed: () {},
                child: const Text('delete everything'),
              ),
            ],
          ),
        ),
      );
      final lock = app.container.read(screenLockProvider.notifier);
      lock.rememberPassword('pw');
      await lock.setTimeout(ScreenLockTimeout.immediately);

      // Control first. Without it the assertion below would pass just as
      // happily over a fixture that never had anything to leak.
      expect(
        _accessibleLabels(tester),
        containsAll(<String>['are you free tonight', 'delete everything']),
        reason: 'the fixture itself is broken',
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await settle(tester);
      expect(
        find.byType(ScreenLockCover),
        findsOneWidget,
        reason: 'the screen did not lock, so the rest proves nothing',
      );

      final behind = _accessibleLabels(tester);
      expect(
        behind,
        isNot(contains('are you free tonight')),
        reason: 'VoiceOver/TalkBack reads the conversation through the cover',
      );
      expect(
        behind,
        isNot(contains('delete everything')),
        reason: 'a screen reader can still ACTIVATE what is under the cover',
      );
      // And the prompt itself has to stay reachable, or the lock would be
      // unanswerable by exactly the person who needs a reader to answer it.
      expect(
        behind,
        contains('Unlock'),
        reason: 'the fix silenced the lock screen along with everything else',
      );
      await shutdown(tester, app.messaging);
      semantics.dispose();
    });

    testWidgets('a keyboard cannot tab to what is under the cover', (
      tester,
    ) async {
      // The other half of "still mounted, still interactive": an external
      // keyboard walks the FOCUS tree, which an opaque surface does not touch.
      final node = FocusNode(debugLabel: 'under the cover');
      addTearDown(node.dispose);
      final app = await mount(
        tester,
        body: Center(
          child: FilledButton(
            focusNode: node,
            onPressed: () {},
            child: const Text('delete everything'),
          ),
        ),
      );
      final lock = app.container.read(screenLockProvider.notifier);
      lock.rememberPassword('pw');
      await lock.setTimeout(ScreenLockTimeout.immediately);

      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue, reason: 'the fixture itself is broken');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await settle(tester);
      expect(find.byType(ScreenLockCover), findsOneWidget);
      expect(
        node.hasFocus,
        isFalse,
        reason: 'focus stayed on a button under the lock',
      );
      node.requestFocus();
      await tester.pump();
      expect(
        node.hasFocus,
        isFalse,
        reason: 'Tab from an external keyboard still reaches under the cover',
      );
      await shutdown(tester, app.messaging);
    });

    testWidgets('typing the password gives the screen back', (tester) async {
      final app = await mount(tester);
      final lock = app.container.read(screenLockProvider.notifier);
      lock.rememberPassword('pw');
      await lock.setTimeout(ScreenLockTimeout.immediately);
      await background(tester);
      // And back: the password is typed by someone who has picked the phone up
      // again, so this is the state the prompt is actually answered in.
      await foreground(tester);
      await settle(tester);

      await tester.enterText(
        find.byKey(const ValueKey('screen-lock-password')),
        'wrong',
      );
      await tester.tap(find.byKey(const ValueKey('screen-lock-submit')));
      await settle(tester);
      expect(find.byType(ScreenLockCover), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('screen-lock-password')),
        'pw',
      );
      await tester.tap(find.byKey(const ValueKey('screen-lock-submit')));
      await settle(tester);
      expect(find.byType(ScreenLockCover), findsNothing);
      expect(find.text('a message'), findsOneWidget);
      await shutdown(tester, app.messaging);
    });

    testWidgets('off means the app is never covered', (tester) async {
      final app = await mount(tester);
      final lock = app.container.read(screenLockProvider.notifier);
      lock.rememberPassword('pw');
      await lock.setTimeout(ScreenLockTimeout.off);

      await background(tester);
      await foreground(tester);
      await settle(tester);
      expect(find.byType(ScreenLockCover), findsNothing);
      expect(find.text('a message'), findsOneWidget);
      await shutdown(tester, app.messaging);
    });
  });

  group('the setting in Settings -> Privacy', () {
    testWidgets('picking a timeout is what the lock then obeys', (
      tester,
    ) async {
      final storage = HiddenVolumeStorage(_memory());
      await storage.open(password: 'pw', createIfMissing: true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [storageProvider.overrideWithValue(storage)],
          child: const MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: PrivacySettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('screen-lock-timeout'));
      expect(row, findsOneWidget);
      // Off out of the box: an install that silently started demanding a
      // password after every glance at another app would read as a bug.
      expect(find.text('Off'), findsOneWidget);

      await tester.tap(row);
      await tester.pumpAndSettle();
      // Every choice the user was promised is actually offered.
      for (final label in [
        'Off',
        'Immediately',
        'After 1 minute',
        'After 5 minutes',
        'After 15 minutes',
      ]) {
        expect(find.text(label), findsWidgets, reason: '$label is missing');
      }

      await tester.tap(find.text('After 5 minutes').last);
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PrivacySettingsScreen)),
      );
      expect(
        container.read(screenLockProvider).timeout,
        ScreenLockTimeout.fiveMinutes,
        reason: 'the pick never reached the controller',
      );
      expect(
        await storage.getSetting(kScreenLockTimeoutSettingKey),
        'fiveMinutes',
        reason: 'the choice would not survive a restart',
      );
    });
  });
}
