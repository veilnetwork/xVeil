import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/veil_stack.dart';

import 'support/fake_hv_container.dart';

/// The runtime directory holds the node's unix sockets and the public obfs4
/// PSK. Leaving it behind is a plaintext trace that identities RAN on this
/// machine, which is why removing it is a deniability control and not tidying
/// up — and why a teardown step that throws must not be able to skip it
/// (audit XV-12).
class _Controller implements NodeController {
  var stopped = 0;
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
  @override
  Future<void> stop() async => stopped++;
}

class _Transport implements VeilTransport {
  _Transport({this.failDispose = false});
  final bool failDispose;
  var disposed = 0;

  @override
  Future<NodeId> nodeId() async => NodeId(Uint8List(32));
  @override
  Stream<InboundMessage> messages() => const Stream.empty();
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) =>
      Future.value();
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) => Future.value();
  @override
  Future<void> sendReply(int replyId, Uint8List payload) => Future.value();
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async {
    disposed++;
    if (failDispose) throw StateError('ipc socket refused to close');
  }
}

BootstrapInvite _invite() =>
    BootstrapInvite(publicKey: Uint8List(32), nonce: Uint8List(8));

void main() {
  late Directory base;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('xveil-teardown-test');
  });

  tearDown(() async {
    // Only ever the directory this test made. Nothing here is allowed to
    // reach outside it.
    if (base.existsSync()) await base.delete(recursive: true);
  });

  test('a teardown step that throws does not take the runtime directory with '
      'it', () async {
    final lease = await RuntimeDirLease.acquire(base.path);
    expect(Directory(lease.path).existsSync(), isTrue);
    final controller = _Controller();
    final transport = _Transport(failDispose: true);
    final stack = RealVeilStack.overParts(
      controller: controller,
      transport: transport,
      myInvite: _invite(),
      runtimeLease: lease,
    );

    // The first error is still reported — an unclean teardown must not be
    // silent. It just no longer costs the rest of the teardown.
    await expectLater(
      stack.dispose(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'ipc socket refused to close',
        ),
      ),
    );

    expect(transport.disposed, 1);
    expect(
      controller.stopped,
      1,
      reason: 'the node kept its ports because an earlier leg threw',
    );
    expect(
      Directory(lease.path).existsSync(),
      isFalse,
      reason:
          'the sockets and the obfs4 PSK were left on disk — the trace that '
          'identities ran here survived, because a socket would not close',
    );
    expect(base.listSync(), isEmpty);
  });

  test('a clean teardown removes it too', () async {
    // The sanity half: "gone" above cannot mean the directory was never there
    // or that dispose removes it unconditionally.
    final lease = await RuntimeDirLease.acquire(base.path);
    final controller = _Controller();
    final transport = _Transport();
    final stack = RealVeilStack.overParts(
      controller: controller,
      transport: transport,
      myInvite: _invite(),
      runtimeLease: lease,
    );
    await stack.dispose();
    expect(transport.disposed, 1);
    expect(controller.stopped, 1);
    expect(base.listSync(), isEmpty);
  });

  test('a start that fails after claiming the directory leaves nothing behind',
      () async {
    // Every failure inside the boot — the readiness check, the IPC connect,
    // the seed registration, the invite — unwinds through ONE catch in
    // `startDeniable`, which is what makes this a property of the boot rather
    // than of whichever step happened to throw. Here the boot dies at the
    // first FFI call; what matters is that the claimed directory is gone
    // afterwards whatever killed it.
    final box = FakeHvContainer();
    final storage = box.storage();
    await storage.open(password: 'p', createIfMissing: true);
    addTearDown(storage.close);
    // A stored config, so the boot gets PAST identity provisioning and as far
    // as claiming a runtime directory — the state this is about.
    await storage.saveNodeConfig('[identity]\nsecret_key = "00"\n');

    await expectLater(
      RealVeilStack.startDeniable(
        storage: storage,
        runtimeDirBase: base.path,
        // Not veil, and deliberately: the first symbol lookup throws, on any
        // platform, whether or not a real libveil is installed here.
        lib: DynamicLibrary.executable(),
        listenPort: 0,
        obfs4Psk: 'PSK',
      ),
      throwsA(anything),
    );

    expect(
      base.listSync(),
      isEmpty,
      reason:
          'a boot that never completed still made a directory holding its '
          'sockets and PSK, and nothing will ever come back for it',
    );
  });
}
