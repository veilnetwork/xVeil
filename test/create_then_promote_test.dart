import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';

/// Stands in for the native node: it can be created, promoted and stopped, and
/// it records whether anyone stopped it.
class _FakeNode {
  bool stopped = false;
}

/// The deniable boot is two FFI calls — `startDeferred` binds the admin socket
/// and starts the node thread, then `applyConfig` promotes the real identity.
/// Between them the node exists and the controller does not own it yet, so a
/// throw from the second call stranded a RUNNING node: admin socket, IPC
/// socket and listen port all held, with no handle left to stop it. The next
/// boot then failed on a taken port, for a reason unrelated to why the first
/// one had not started (audit XV-03).
void main() {
  test('a node that fails to promote is stopped, not stranded', () {
    late final _FakeNode created;

    expect(
      () => createThenPromote<_FakeNode>(
        create: () => created = _FakeNode(),
        promote: (_) => throw StateError('applyConfig failed'),
        abandon: (n) => n.stopped = true,
      ),
      throwsA(isA<StateError>()),
      reason: 'the promotion failure is what the caller needs to see',
    );

    expect(
      created.stopped,
      isTrue,
      reason: 'nothing else holds a reference — this was the only chance',
    );
  });

  test('a successful boot is returned and NOT stopped', () {
    final node = createThenPromote<_FakeNode>(
      create: _FakeNode.new,
      promote: (_) {},
      abandon: (n) => n.stopped = true,
    );

    expect(node.stopped, isFalse, reason: 'the caller owns it now');
  });

  test('a cleanup that throws does not mask the real failure', () {
    // The promotion failure explains what went wrong; a throw from the
    // best-effort stop would replace it with something less useful.
    expect(
      () => createThenPromote<_FakeNode>(
        create: _FakeNode.new,
        promote: (_) => throw StateError('applyConfig failed'),
        abandon: (_) => throw StateError('stop also failed'),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'applyConfig failed',
        ),
      ),
    );
  });
}
