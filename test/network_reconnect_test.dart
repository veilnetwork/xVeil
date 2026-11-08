import 'dart:async';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:xveil/core/diagnostic_background.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/state/network_reconnect.dart';
import 'package:xveil/state/providers.dart';

class _Connectivity implements Connectivity {
  final changes = StreamController<List<ConnectivityResult>>(sync: true);
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    ConnectivityResult.wifi,
  ];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => changes.stream;
}

class _Transport extends LoopbackTransport implements NetworkChangeTransport {
  final observed = <NetworkAttachment>[];
  int failures = 0;
  @override
  Future<void> networkChanged(NetworkAttachment attachment) async {
    observed.add(attachment);
    if (failures > 0) {
      failures--;
      throw StateError('transient IPC outage');
    }
  }
}

class _Session implements MultiIdentitySession {
  _Session(this.stacks);
  final Map<String, RealVeilStack> stacks;
  @override
  List<String> get labels => stacks.keys.toList();
  @override
  RealVeilStack? stackFor(String label) => stacks[label];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RealVeilStack _stack(_Transport transport) => RealVeilStack.overParts(
  controller: StaticNodeController(NodeStatus.stopped),
  transport: transport,
  myInvite: BootstrapInvite(publicKey: Uint8List(32), nonce: Uint8List(8)),
);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pending diagnostic read never holds handover or its next generation',
    () async {
      final changes = StreamController<List<ConnectivityResult>>(sync: true);
      final gate = Completer<Map<Object?, Object?>?>();
      var reads = 0;
      final sampler = DiagnosticBackgroundSampler(
        journal: DiagnosticJournal(enabled: true),
        readState: () {
          reads++;
          return gate.future;
        },
      );
      final observed = <NetworkAttachment>[];
      final observer = NetworkReconnect(
        current: () async => [ConnectivityResult.wifi],
        changes: changes.stream,
        onAttachmentChanged: sampler.request,
        notify: (kind, _) async => observed.add(kind),
      );
      await observer.start();
      changes.add([ConnectivityResult.mobile]);
      await _flush();
      changes.add([ConnectivityResult.mobile]);
      await _flush();
      expect(observed, [NetworkAttachment.wifi, NetworkAttachment.cellular]);
      expect(reads, 1, reason: 'OS query still pending, repair has completed');
      sampler.dispose();
      await observer.dispose();
      gate.complete(null);
      await _flush();
      expect(reads, 1, reason: 'dispose discards queued diagnostic sample');
      await changes.close();
    },
  );

  test('a refused diagnostic observer cannot break repair', () async {
    final changes = StreamController<List<ConnectivityResult>>(sync: true);
    final observed = <NetworkAttachment>[];
    final observer = NetworkReconnect(
      current: () async => [ConnectivityResult.wifi],
      changes: changes.stream,
      onAttachmentChanged: () => throw StateError('private-canary'),
      notify: (kind, _) async => observed.add(kind),
    );
    await observer.start();
    changes.add([ConnectivityResult.mobile]);
    await _flush();
    expect(observed, [NetworkAttachment.wifi, NetworkAttachment.cellular]);
    await observer.dispose();
    await changes.close();
  });

  test('handover retries a transient failure without another OS event', () {
    fakeAsync((clock) {
      final changes = StreamController<List<ConnectivityResult>>(sync: true);
      var attempts = 0;
      final observer = NetworkReconnect(
        current: () async => [ConnectivityResult.wifi],
        changes: changes.stream,
        notify: (_, _) async {
          if (++attempts == 1) throw StateError('transient IPC outage');
        },
      );
      unawaited(observer.start());
      clock.flushMicrotasks();
      expect(attempts, 1);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(attempts, 2);
      clock.elapse(const Duration(minutes: 1));
      expect(attempts, 2, reason: 'successful notification must stop retries');
      unawaited(observer.dispose());
      unawaited(changes.close());
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('failed handover backs off, and disposal cancels its retry', () {
    fakeAsync((clock) {
      final changes = StreamController<List<ConnectivityResult>>(sync: true);
      final attempts = <int>[];
      final observer = NetworkReconnect(
        current: () async => [ConnectivityResult.wifi],
        changes: changes.stream,
        notify: (_, _) async {
          attempts.add(clock.elapsed.inSeconds);
          throw StateError('node unavailable');
        },
      );
      unawaited(observer.start());
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 91));
      expect(attempts, [0, 1, 3, 7, 15, 31, 61, 91]);
      expect(clock.pendingTimers, hasLength(1));
      unawaited(observer.dispose());
      unawaited(changes.close());
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 2));
      expect(attempts, hasLength(8));
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('a newer attachment supersedes a pending retry generation', () {
    fakeAsync((clock) {
      final changes = StreamController<List<ConnectivityResult>>(sync: true);
      final kinds = <NetworkAttachment>[];
      final generations = <int>[];
      final gate = Completer<void>();
      final observer = NetworkReconnect(
        current: () async => [ConnectivityResult.wifi],
        changes: changes.stream,
        notify: (kind, generation) async {
          kinds.add(kind);
          generations.add(generation);
          if (kinds.length == 1) throw StateError('node unavailable');
          await gate.future;
        },
      );
      unawaited(observer.start());
      clock.flushMicrotasks();
      changes.add([ConnectivityResult.mobile]);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 2));
      expect(kinds, [NetworkAttachment.wifi, NetworkAttachment.cellular]);
      expect(generations, [1, 2]);
      expect(clock.pendingTimers, isEmpty);
      gate.complete();
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 1));
      expect(kinds, hasLength(2));
      unawaited(observer.dispose());
      unawaited(changes.close());
      clock.flushMicrotasks();
    });
  });

  test('fanout retries only failed identities in the same generation', () {
    fakeAsync((clock) {
      final connectivity = _Connectivity();
      final a = _Transport();
      final b = _Transport()..failures = 1;
      final stackA = _stack(a), stackB = _stack(b);
      final container = ProviderContainer(
        overrides: [
          networkConnectivityProvider.overrideWithValue(connectivity),
          realStackProvider.overrideWith((_) => stackA),
          sessionProvider.overrideWith(
            (_) => _Session({'a': stackA, 'b': stackB}),
          ),
        ],
      );
      container.read(networkReconnectProvider);
      clock.flushMicrotasks();
      expect(a.observed, [NetworkAttachment.wifi]);
      expect(b.observed, [NetworkAttachment.wifi]);
      clock.elapse(const Duration(seconds: 1));
      expect(a.observed, [NetworkAttachment.wifi]);
      expect(b.observed, [NetworkAttachment.wifi, NetworkAttachment.wifi]);
      connectivity.changes.add([ConnectivityResult.mobile]);
      clock.flushMicrotasks();
      connectivity.changes.add([ConnectivityResult.wifi]);
      clock.flushMicrotasks();
      expect(a.observed, [
        NetworkAttachment.wifi,
        NetworkAttachment.cellular,
        NetworkAttachment.wifi,
      ]);
      expect(b.observed, [
        NetworkAttachment.wifi,
        NetworkAttachment.wifi,
        NetworkAttachment.cellular,
        NetworkAttachment.wifi,
      ]);
      container.dispose();
      unawaited(connectivity.changes.close());
      unawaited(a.dispose());
      unawaited(b.dispose());
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test(
    'attachment categories match the SDK priority without network details',
    () {
      expect(networkAttachmentOf([]), NetworkAttachment.offline);
      expect(
        networkAttachmentOf([ConnectivityResult.none]),
        NetworkAttachment.offline,
      );
      expect(
        networkAttachmentOf([ConnectivityResult.mobile]),
        NetworkAttachment.cellular,
      );
      expect(
        networkAttachmentOf([ConnectivityResult.ethernet]),
        NetworkAttachment.ethernet,
      );
      expect(
        networkAttachmentOf([ConnectivityResult.vpn]),
        NetworkAttachment.unknown,
      );
      expect(
        networkAttachmentOf([
          ConnectivityResult.wifi,
          ConnectivityResult.mobile,
        ]),
        NetworkAttachment.wifi,
      );
    },
  );

  test(
    'open UI receives wifi to cellular without a lifecycle resume',
    () async {
      final changes = StreamController<List<ConnectivityResult>>(sync: true);
      final observed = <NetworkAttachment>[];
      final observer = NetworkReconnect(
        current: () async => [ConnectivityResult.wifi],
        changes: changes.stream,
        notify: (kind, _) async => observed.add(kind),
      );
      await observer.start();
      changes.add([ConnectivityResult.mobile]);
      await _flush();
      expect(observed, [NetworkAttachment.wifi, NetworkAttachment.cellular]);
      await observer.dispose();
      expect(changes.hasListener, isFalse);
      await changes.close();
    },
  );

  test(
    'a late initial query cannot overwrite a newer platform event',
    () async {
      final initial = Completer<List<ConnectivityResult>>();
      final changes = StreamController<List<ConnectivityResult>>(sync: true);
      final observed = <NetworkAttachment>[];
      final observer = NetworkReconnect(
        current: () => initial.future,
        changes: changes.stream,
        notify: (kind, _) async => observed.add(kind),
      );
      final starting = observer.start();
      changes.add([ConnectivityResult.mobile]);
      initial.complete([ConnectivityResult.wifi]);
      await starting;
      await _flush();
      expect(observed, [NetworkAttachment.cellular]);
      await observer.dispose();
      await changes.close();
    },
  );

  test('duplicate events do not tear down sessions twice', () async {
    final changes = StreamController<List<ConnectivityResult>>(sync: true);
    final gate = Completer<void>();
    final observed = <NetworkAttachment>[];
    final observer = NetworkReconnect(
      current: () async => [ConnectivityResult.wifi],
      changes: changes.stream,
      notify: (kind, _) async {
        observed.add(kind);
        await gate.future;
      },
    );
    await observer.start();
    changes.add([ConnectivityResult.wifi, ConnectivityResult.mobile]);
    changes.add([ConnectivityResult.wifi]);
    expect(observed, [NetworkAttachment.wifi]);
    gate.complete();
    await _flush();
    changes.add([ConnectivityResult.wifi]);
    await _flush();
    expect(observed, [NetworkAttachment.wifi]);
    await observer.dispose();
    await changes.close();
  });

  test(
    'handover during notification retains only the newest attachment',
    () async {
      final changes = StreamController<List<ConnectivityResult>>(sync: true);
      final gate = Completer<void>();
      final observed = <NetworkAttachment>[];
      final observer = NetworkReconnect(
        current: () async => [ConnectivityResult.wifi],
        changes: changes.stream,
        notify: (kind, _) async {
          observed.add(kind);
          if (observed.length == 1) await gate.future;
        },
      );
      await observer.start();
      changes.add([ConnectivityResult.none]);
      changes.add([ConnectivityResult.mobile]);
      expect(observed, [NetworkAttachment.wifi]);
      gate.complete();
      await _flush();
      expect(observed, [NetworkAttachment.wifi, NetworkAttachment.cellular]);
      await observer.dispose();
      await changes.close();
    },
  );

  test('wifi mobile wifi during IPC still reconnects the final wifi', () async {
    final changes = StreamController<List<ConnectivityResult>>(sync: true);
    final gate = Completer<void>();
    final observed = <NetworkAttachment>[];
    final observer = NetworkReconnect(
      current: () async => [ConnectivityResult.wifi],
      changes: changes.stream,
      notify: (kind, _) async {
        observed.add(kind);
        if (observed.length == 1) await gate.future;
      },
    );
    await observer.start();
    changes.add([ConnectivityResult.mobile]);
    changes.add([ConnectivityResult.wifi]);
    gate.complete();
    await _flush();
    expect(observed, [NetworkAttachment.wifi, NetworkAttachment.wifi]);
    await observer.dispose();
    await changes.close();
  });

  test(
    'failed notification can retry on the next same-kind observation',
    () async {
      final changes = StreamController<List<ConnectivityResult>>(sync: true);
      var attempts = 0;
      final observer = NetworkReconnect(
        current: () async => [ConnectivityResult.wifi],
        changes: changes.stream,
        notify: (_, _) async {
          if (++attempts == 1) throw StateError('synthetic');
        },
      );
      await observer.start();
      await _flush();
      changes.add([ConnectivityResult.wifi]);
      await _flush();
      expect(attempts, 2);
      await observer.dispose();
      await changes.close();
    },
  );

  test(
    'dispose discards a queued handover and a pending initial query',
    () async {
      final changes = StreamController<List<ConnectivityResult>>(sync: true);
      final initial = Completer<List<ConnectivityResult>>();
      final gate = Completer<void>();
      final observed = <NetworkAttachment>[];
      final observer = NetworkReconnect(
        current: () => initial.future,
        changes: changes.stream,
        notify: (kind, _) async {
          observed.add(kind);
          await gate.future;
        },
      );
      final starting = observer.start();
      changes.add([ConnectivityResult.wifi]);
      changes.add([ConnectivityResult.mobile]);
      await observer.dispose();
      gate.complete();
      initial.complete([ConnectivityResult.mobile]);
      await starting;
      await _flush();
      expect(observed, [NetworkAttachment.wifi]);
      expect(changes.hasListener, isFalse);
      await changes.close();
    },
  );

  test(
    'provider notifies all online identities and deduplicates active stack',
    () async {
      final connectivity = _Connectivity();
      final a = _Transport();
      final b = _Transport();
      final stackA = _stack(a);
      final stackB = _stack(b);
      final container = ProviderContainer(
        overrides: [
          networkConnectivityProvider.overrideWithValue(connectivity),
          realStackProvider.overrideWith((_) => stackA),
          sessionProvider.overrideWith(
            (_) => _Session({'a': stackA, 'b': stackB}),
          ),
        ],
      );
      container.read(networkReconnectProvider);
      await _flush();
      connectivity.changes.add([ConnectivityResult.mobile]);
      await _flush();
      expect(a.observed, [NetworkAttachment.wifi, NetworkAttachment.cellular]);
      expect(b.observed, a.observed);
      container.dispose();
      await _flush();
      expect(connectivity.changes.hasListener, isFalse);
      await connectivity.changes.close();
      await a.dispose();
      await b.dispose();
    },
  );
}
