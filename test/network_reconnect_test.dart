import 'dart:async';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
  @override
  Future<void> networkChanged(NetworkAttachment attachment) async {
    observed.add(attachment);
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
        notify: (kind) async => observed.add(kind),
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
        notify: (kind) async => observed.add(kind),
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
      notify: (kind) async {
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
        notify: (kind) async {
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
      notify: (kind) async {
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
        notify: (_) async {
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
        notify: (kind) async {
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
