import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/state/managed_nodes_controller.dart';

import 'package:xveil/state/providers.dart';

import 'support/fake_setting_storage.dart';

/// One record, several writers, and each of them used to write the whole
/// thing.
///
/// The SSH dialog pins a host key on first contact and saves it. The callback
/// that runs immediately afterwards — inventory, auto-update, a fleet version
/// refresh — was handed the node as it looked BEFORE that, and wrote it back.
/// The pin was gone, so the next connection was first contact again: a key
/// confirmed once could be replaced by somebody else's and confirmed again,
/// over a connection that carries a root-capable credential and a command.
void main() {
  ManagedNode pinned() => const ManagedNode(
    id: 'n1',
    label: 'exit-host',
    sshHost: '203.0.113.10',
    sshUser: 'root',
    sshHostFingerprint: 'SHA256:aaaa',
    autoUpdate: true,
    veilVersion: '0.8.0',
  );

  /// The same node before its host key was ever confirmed. Built rather than
  /// derived: `copyWith` cannot clear a field — it keeps the current value
  /// when handed null — so `copyWith(sshHostFingerprint: null)` returns a node
  /// that is still pinned.
  ManagedNode unpinned() => const ManagedNode(
    id: 'n1',
    label: 'exit-host',
    sshHost: '203.0.113.10',
    sshUser: 'root',
    autoUpdate: true,
    veilVersion: '0.8.0',
  );

  late ProviderContainer container;
  late ManagedNodesController controller;

  setUp(() async {
    container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => FakeSettingStorage())],
    );
    controller = container.read(managedNodesProvider.notifier);
    await container.read(managedNodesProvider.future);
    addTearDown(container.dispose);
  });

  Future<ManagedNode?> stored(String id) async {
    final nodes = container.read(managedNodesProvider).value ?? const [];
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  test('an update applies to the record as it stands, not to a stale copy', () async {
      final stale = unpinned();
      await controller.upsert(stale);
      // What the dialog does on first contact.
      await controller.updateById(
        'n1',
        (cur) => cur.copyWith(sshHostFingerprint: 'SHA256:bbbb'),
      );
      // What the callback does next, holding the object from before the pin.
      await controller.updateById(
        stale.id,
        (cur) => cur.copyWith(veilVersion: '0.8.1'),
      );

      final now = await stored('n1');
      expect(
        now!.sshHostFingerprint,
        'SHA256:bbbb',
        reason: 'the pin was wiped by a writer that had an older copy',
      );
    expect(now.veilVersion, '0.8.1', reason: 'the update did not apply');
  });

  test('a whole-record write from a stale copy still loses the pin', () async {
    // The premise, stated rather than assumed: `upsert` genuinely does replace
    // everything. Without this the test above could pass against a controller
    // where nothing was ever at risk.
    final stale = unpinned();
    await controller.upsert(stale);
    await controller.updateById(
      'n1',
      (cur) => cur.copyWith(sshHostFingerprint: 'SHA256:bbbb'),
    );
    await controller.upsert(stale.copyWith(veilVersion: '0.8.1'));

    expect((await stored('n1'))!.sshHostFingerprint, isNull);
  });

  test('updating a node that is gone is not an error', () async {
    expect(
      await controller.updateById('nobody', (cur) => cur),
      isNull,
      reason: 'a record somebody deleted is not a failed write',
    );
  });

  test('everything the caller did not change is left alone', () async {
    // Field by field through `toJson`, so a field added later is covered
    // without anyone remembering to add it here — which is exactly how
    // `autoUpdate` and `veilVersion` came to be dropped.
    final node = pinned();
    await controller.upsert(node);
    await controller.updateById('n1', (cur) => cur.copyWith(label: 'renamed'));

    final now = await stored('n1');
    expect(now!.toJson(), node.copyWith(label: 'renamed').toJson());
  });

  test('the screens that write from an SSH callback do not write whole records',
      () {
    // Structural, because the behaviour is not otherwise reachable from a
    // unit test: these writes happen inside `onSuccess` of a dialog that
    // performs a real SSH session.
    //
    // The rule is narrow and the reason is specific. A callback here is handed
    // the node as it looked BEFORE the dialog ran, and the dialog pins a host
    // key on first contact. Writing that object back is what wiped the pin.
    for (final path in const [
      'lib/features/network/node_management_screen.dart',
      'lib/features/network/node_fleet_update_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        isNot(contains('.upsert(')),
        reason:
            '$path writes a whole record; use updateById so the pin the SSH '
            'dialog just saved is not overwritten by an older copy',
      );
      expect(
        source,
        contains('.updateById('),
        reason: '$path stopped writing to the registry at all',
      );
    }
  });

  test('nobody drops the answer the registry gives them', () {
    // The controller REPORTS a failed write instead of throwing, deliberately:
    // these writes happen inside SSH flows that catch SshException and nothing
    // else, so throwing would turn a settings write into an unhandled error in
    // three places that have nothing to do with settings.
    //
    // The cost of that choice is that `await notifier.upsert(...)` with the
    // result discarded compiles, reads fine, and says nothing when the write
    // fails. The dangerous shape is the one where the SERVER has already been
    // changed: the timer is installed, the pin was offered, the config was
    // written — and the app quietly does not record it. The switch then shows
    // "off" while a root timer keeps updating that machine.
    //
    // Structural, because the alternative is a widget test per call site
    // against a storage that fails, and this catches a new call site too.
    for (final path in const [
      'lib/features/network/ssh_command_dialog.dart',
      'lib/features/network/node_config_screen.dart',
      'lib/features/network/managed_nodes_screen.dart',
      'lib/features/network/node_management_screen.dart',
      'lib/features/network/node_fleet_update_screen.dart',
      'lib/features/network/node_provision_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      for (final call in const ['.upsert(', '.updateById(']) {
        var at = source.indexOf(call);
        while (at >= 0) {
          // Back to whatever introduced the statement: the previous `;`, or
          // the brace that opened the block.
          var start = source.lastIndexOf(';', at);
          for (final mark in const ['{', '}']) {
            final m = source.lastIndexOf(mark, at);
            if (m > start) start = m;
          }
          final head = source.substring(start + 1, at);
          expect(
            head,
            anyOf(contains('='), contains('return')),
            reason:
                '$path calls $call and throws the result away; a write that '
                'failed then says nothing, while the server has already been '
                'changed',
          );
          at = source.indexOf(call, at + 1);
        }
      }
    }
  });
}
