import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/data/node/ssh_credentials.dart';
import 'package:xveil/features/network/managed_nodes_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/managed_nodes_controller.dart';
import 'package:xveil/state/proxy_routing_controller.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/ssh_credentials.dart';

import 'support/fake_hv_container.dart';

const _exit =
    'aa11bb22cc33dd44ee55ff66007788990011223344556677889900aabbccddee';

class _MemorySshCredentialsStore implements SshCredentialsStore {
  final values = <String, SavedSshCredentials>{};

  @override
  Future<SavedSshCredentials> load(String nodeId) async =>
      values[nodeId] ?? const SavedSshCredentials();

  @override
  Future<void> save(String nodeId, SavedSshCredentials credentials) async {
    if (credentials.isEmpty) {
      values.remove(nodeId);
    } else {
      values[nodeId] = credentials;
    }
  }

  @override
  Future<void> clear(String nodeId) async => values.remove(nodeId);
}

/// A store whose registry write always fails, and nothing else changes.
///
/// `HiddenVolumeStorage` is a class, so this overrides ONE method rather than
/// reimplementing the interface — which is what makes this a test of the
/// commit path and not of a mock's fidelity.
class _RegistryWriteFails extends HiddenVolumeStorage {
  _RegistryWriteFails(super.opener, {super.keysOpener});

  @override
  Future<void> putSetting(String key, String value) async {
    if (key == 'managed_nodes') {
      throw StateError('container is full');
    }
    return super.putSetting(key, value);
  }
}

/// An OPEN container for the screen to commit its registry into.
///
/// Before report9 X-05 the controller set its state optimistically and
/// swallowed the write error, so these tests passed with no storage at all —
/// on exactly the lie that finding is about. The registry is only reachable
/// after unlock in the app, so an open store is the honest fixture.
Future<Storage> _openStorage() async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  return storage;
}

Widget _host({_MemorySshCredentialsStore? credentials, Storage? storage}) =>
    ProviderScope(
  overrides: [
    sshCredentialsRepositoryProvider.overrideWithValue(
      credentials ?? _MemorySshCredentialsStore(),
    ),
    if (storage != null) storageProvider.overrideWith((ref) => storage),
  ],
  child: const MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: ManagedNodesScreen(),
  ),
);

void main() {
  group('SavedSshCredentials', () {
    test('round-trips password and key material', () {
      const credentials = SavedSshCredentials(
        password: 'secret',
        privateKeyPem: 'PRIVATE',
        publicKeyOpenSsh: 'ssh-ed25519 PUBLIC xveil',
      );
      final decoded = SavedSshCredentials.decode(credentials.encode());
      expect(decoded.password, 'secret');
      expect(decoded.privateKeyPem, 'PRIVATE');
      expect(decoded.publicKeyOpenSsh, 'ssh-ed25519 PUBLIC xveil');
      expect(decoded.hasPassword, isTrue);
      expect(decoded.hasKey, isTrue);
    });

    test('generates an OpenSSH-compatible Ed25519 pair', () async {
      final generated = await generateSshEd25519KeyPair(comment: 'xveil-test');
      final parsed = SSHKeyPair.fromPem(generated.privateKeyPem);
      expect(parsed, hasLength(1));
      expect(parsed.single, isA<OpenSSHEd25519KeyPair>());
      final fields = generated.publicKeyOpenSsh.split(' ');
      expect(fields.first, 'ssh-ed25519');
      expect(base64Decode(fields[1]), parsed.single.toPublicKey().encode());
      expect(fields.last, 'xveil-test');
    });
  });

  group('ManagedNode', () {
    test('round-trips a list through json', () {
      final nodes = [
        const ManagedNode(
          id: '1',
          label: 'vps',
          nodeId: _exit,
          sshHost: 'a.b',
          sshUser: 'u',
        ),
        const ManagedNode(id: '2', label: 'home'),
      ];
      final back = ManagedNode.decodeList(ManagedNode.encodeList(nodes));
      expect(back.length, 2);
      expect(back[0].nodeId, _exit);
      expect(back[0].hasNodeId, isTrue);
      expect(back[0].hasSsh, isTrue);
      expect(back[1].hasNodeId, isFalse);
      expect(back[1].sshPort, 22);
    });

    test('round-trips the pinned SSH host fingerprint', () {
      const fp = 'SHA256:abc123def456+/Pinned0HostKeyFingerprintValue';
      final nodes = [
        const ManagedNode(
          id: '1',
          label: 'vps',
          sshHost: 'a.b',
          sshUser: 'u',
          sshHostFingerprint: fp,
        ),
      ];
      final back = ManagedNode.decodeList(ManagedNode.encodeList(nodes));
      expect(back.single.sshHostFingerprint, fp);
      // copyWith preserves it unless explicitly overridden.
      expect(back.single.copyWith(label: 'x').sshHostFingerprint, fp);
    });

    test('decode tolerates junk', () {
      expect(ManagedNode.decodeList(null), isEmpty);
      expect(ManagedNode.decodeList('not json'), isEmpty);
      expect(ManagedNode.decodeList('{}'), isEmpty);
    });

    // report9 X-05. `fromJson` throws on a record with no `id`, and the throw
    // escaped the comprehension into the outer catch — so ONE malformed entry
    // returned an empty registry and every other node the user had configured
    // disappeared from the screen. Nothing was lost on disk, which made it
    // worse: the list came back empty, the user re-added a node, and that
    // write replaced the whole key.
    test('one unreadable record costs its own entry and nothing else', () {
      const raw = '['
          '{"id":"1","label":"first"},'
          '{"label":"no id at all"},'
          '{"id":"3","label":"third"}'
          ']';
      final back = ManagedNode.decodeList(raw);
      expect(
        back.map((n) => n.id),
        ['1', '3'],
        reason:
            'a single malformed record took the whole registry with it — the '
            'user sees an empty list and their nodes are still on disk',
      );
    });

    test('a wrongly-typed field is quarantined, not fatal', () {
      const raw = '['
          '{"id":"1","label":"first"},'
          '{"id":42,"label":"id is a number"},'
          '{"id":"3","label":"third"}'
          ']';
      expect(ManagedNode.decodeList(raw).map((n) => n.id), ['1', '3']);
    });
  });

  testWidgets('a write that fails leaves the list alone and says so', (
    tester,
  ) async {
    // report9 X-05. The controller set its state BEFORE the write and
    // swallowed the error, so the screen listed a node that was never
    // committed. The user found out at the next launch, when it was simply
    // gone and nothing had ever said so.
    final container = FakeHvContainer();
    final storage = _RegistryWriteFails(
      container.passwordOpener,
      keysOpener: container.keysOpener,
    );
    await storage.open(password: 'pw', createIfMissing: true);

    await tester.pumpWidget(_host(storage: storage));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ManagedNodesScreen)));
    expect(find.text(l.nodesEmpty), findsOneWidget);

    final scope = ProviderScope.containerOf(
      tester.element(find.byType(ManagedNodesScreen)),
    );
    final error = await scope
        .read(managedNodesProvider.notifier)
        .upsert(const ManagedNode(id: 'x', label: 'My exit', nodeId: _exit));
    await tester.pumpAndSettle();

    expect(
      error,
      isNotNull,
      reason: 'the write failed and the caller was told it succeeded',
    );
    expect(
      find.text('My exit'),
      findsNothing,
      reason:
          'the screen lists a node that is not on disk — it will be gone at '
          'the next launch with nothing having said so',
    );
    expect(find.text(l.nodesEmpty), findsOneWidget);
  });

  testWidgets('a write that succeeds still shows the node', (tester) async {
    // The other side of the boundary: an error path that refused everything
    // would satisfy the test above and break the feature.
    await tester.pumpWidget(_host(storage: await _openStorage()));
    await tester.pumpAndSettle();
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(ManagedNodesScreen)),
    );
    final error = await scope
        .read(managedNodesProvider.notifier)
        .upsert(const ManagedNode(id: 'x', label: 'My exit', nodeId: _exit));
    await tester.pumpAndSettle();
    expect(error, isNull);
    expect(find.text('My exit'), findsOneWidget);
  });

  testWidgets('empty registry shows the hint; adding a node lists it', (
    tester,
  ) async {
    await tester.pumpWidget(_host(storage: await _openStorage()));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ManagedNodesScreen)));
    expect(find.text(l.nodesEmpty), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ManagedNodesScreen)),
    );
    await container
        .read(managedNodesProvider.notifier)
        .upsert(const ManagedNode(id: 'x', label: 'My exit', nodeId: _exit));
    await tester.pumpAndSettle();

    expect(find.text('My exit'), findsOneWidget);
    expect(find.text(l.nodesEmpty), findsNothing);
  });

  testWidgets('add menu separates an existing node from SSH provisioning', (
    tester,
  ) async {
    await tester.pumpWidget(_host(storage: await _openStorage()));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ManagedNodesScreen)));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text(l.nodesAddChoiceTitle), findsOneWidget);
    expect(find.text(l.nodesAddExisting), findsOneWidget);
    expect(find.text(l.nodesBootstrapNew), findsOneWidget);
  });

  testWidgets('an existing node requires its node id', (tester) async {
    await tester.pumpWidget(_host(storage: await _openStorage()));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ManagedNodesScreen)));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ManagedNodesScreen)),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.nodesAddExisting));
    await tester.pumpAndSettle();

    expect(find.text(l.nodesAddExistingFieldsHint), findsOneWidget);
    expect(
      find.widgetWithText(TextField, l.nodeIdRequiredLabel),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(TextField, l.nodeLabelLabel),
      'Existing relay',
    );
    await tester.ensureVisible(find.text(l.actionSave));
    await tester.tap(find.text(l.actionSave));
    await tester.pumpAndSettle();
    expect(find.text(l.nodeIdRequired), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, l.nodeIdRequiredLabel),
      _exit,
    );
    await tester.ensureVisible(find.text(l.actionSave));
    await tester.tap(find.text(l.actionSave));
    await tester.pumpAndSettle();

    final saved = container.read(managedNodesProvider).requireValue.single;
    expect(saved.label, 'Existing relay');
    expect(saved.nodeId, _exit);
  });

  testWidgets('a new SSH node skips node id and continues to provisioning', (
    tester,
  ) async {
    await tester.pumpWidget(_host(storage: await _openStorage()));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ManagedNodesScreen)));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ManagedNodesScreen)),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.nodesBootstrapNew));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, l.nodeIdLabel), findsNothing);
    expect(find.text(l.nodesBootstrapFieldsHint), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, l.nodeLabelLabel),
      'Fresh VPS',
    );
    await tester.ensureVisible(find.text(l.nodesBootstrapContinue));
    await tester.tap(find.text(l.nodesBootstrapContinue));
    await tester.pumpAndSettle();
    expect(find.text(l.nodeSshHostRequired), findsOneWidget);
    expect(find.text(l.nodeSshUserRequired), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, l.nodeSshHostRequiredLabel),
      'vps.example',
    );
    await tester.enterText(
      find.widgetWithText(TextField, l.nodeSshUserRequiredLabel),
      'root',
    );
    await tester.ensureVisible(find.text(l.nodesBootstrapContinue));
    await tester.tap(find.text(l.nodesBootstrapContinue));
    await tester.pumpAndSettle();

    expect(find.text(l.provisionTitle), findsOneWidget);
    final saved = container.read(managedNodesProvider).requireValue.single;
    expect(saved.label, 'Fresh VPS');
    expect(saved.nodeId, isNull);
    expect(saved.sshHost, 'vps.example');
    expect(saved.sshUser, 'root');
  });

  testWidgets('password and generated Ed25519 key are saved per node', (
    tester,
  ) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final credentials = _MemorySshCredentialsStore();
    await tester.pumpWidget(_host(credentials: credentials, storage: await _openStorage()));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ManagedNodesScreen)));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.nodesAddExisting));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, l.nodeLabelLabel),
      'Saved SSH',
    );
    await tester.enterText(
      find.widgetWithText(TextField, l.nodeIdRequiredLabel),
      _exit,
    );
    await tester.ensureVisible(
      find.widgetWithText(TextField, l.sshSavedPasswordLabel),
    );
    await tester.enterText(
      find.widgetWithText(TextField, l.sshSavedPasswordLabel),
      'ssh-secret',
    );
    await tester.ensureVisible(find.text(l.sshGenerateEd25519));
    await tester.tap(find.text(l.sshGenerateEd25519));
    await tester.pumpAndSettle();

    expect(find.text(l.sshSavedEd25519Title), findsOneWidget);
    expect(find.byTooltip(l.sshCopyPublicKey), findsOneWidget);
    await tester.tap(find.byTooltip(l.sshCopyPublicKey));
    await tester.pump();
    expect(copied, startsWith('ssh-ed25519 '));
    await tester.ensureVisible(find.text(l.actionSave));
    await tester.tap(find.text(l.actionSave));
    await tester.pumpAndSettle();

    final saved = credentials.values.values.single;
    expect(saved.password, 'ssh-secret');
    expect(saved.hasKey, isTrue);
    expect(SSHKeyPair.fromPem(saved.privateKeyPem!), hasLength(1));
    expect(saved.publicKeyOpenSsh, startsWith('ssh-ed25519 '));
  });

  testWidgets('use-as-exit wires the node id into proxy routing', (
    tester,
  ) async {
    await tester.pumpWidget(_host(storage: await _openStorage()));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ManagedNodesScreen)),
    );
    await container
        .read(managedNodesProvider.notifier)
        .upsert(const ManagedNode(id: 'x', label: 'My exit', nodeId: _exit));
    await tester.pumpAndSettle();

    // Open the edit sheet, tap "use as exit".
    await tester.tap(find.byIcon(Icons.edit_outlined).last);
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ManagedNodesScreen)));
    await tester.ensureVisible(find.text(l.nodeUseAsExit));
    await tester.tap(find.text(l.nodeUseAsExit));
    await tester.pumpAndSettle();

    final routing = container.read(proxyRoutingProvider);
    expect(routing.socks5Enabled, isTrue);
    expect(routing.exitNodeId, _exit);
    expect(routing.socks5Active, isTrue);
  });

  testWidgets('tapping a node opens its full lifecycle management screen', (
    tester,
  ) async {
    await tester.pumpWidget(_host(storage: await _openStorage()));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ManagedNodesScreen)),
    );
    await container
        .read(managedNodesProvider.notifier)
        .upsert(
          const ManagedNode(
            id: 'managed',
            label: 'Managed VPS',
            sshHost: 'vps.example',
            sshUser: 'root',
          ),
        );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ManagedNodesScreen)));

    await tester.tap(find.text('Managed VPS'));
    await tester.pumpAndSettle();

    expect(find.text(l.nodeInventory), findsOneWidget);
    expect(find.text(l.nodeInstallUpdate), findsOneWidget);
    // Below the fold in the test viewport, and a ListView only builds what it
    // shows: scrolled to rather than asserted blind, so the check keeps
    // meaning "the screen offers this" instead of "it fits on one screen".
    await tester.scrollUntilVisible(find.text(l.nodeServices), 200);
    expect(find.text(l.nodeServices), findsOneWidget);
    await tester.scrollUntilVisible(find.text('oproxy-server'), 200);
    expect(find.text('oproxy-server'), findsWidgets);
  });

  testWidgets('editing a node keeps its pinned SSH host key (SSH-MITM)', (
    tester,
  ) async {
    await tester.pumpWidget(_host(storage: await _openStorage()));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ManagedNodesScreen)),
    );
    await container
        .read(managedNodesProvider.notifier)
        .upsert(
          const ManagedNode(
            id: 'p',
            label: 'Pinned',
            sshHost: 'srv.example',
            sshUser: 'u',
            sshHostFingerprint: 'SHA256:PINNEDKEY',
            // Two things the form does not ask about. `autoUpdate` says a
            // root timer is running on that server; rebuilding the record
            // from the form alone set it back to false, so renaming a node
            // told the operator unattended updates were off while they went
            // on happening.
            autoUpdate: true,
            veilVersion: '0.8.0',
          ),
        );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ManagedNodesScreen)));

    // Open the edit sheet and change ONLY the label (a benign edit).
    await tester.tap(find.byIcon(Icons.edit_outlined).last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, l.nodeLabelLabel),
      'Pinned renamed',
    );
    await tester.ensureVisible(find.text(l.actionSave));
    await tester.tap(find.text(l.actionSave));
    await tester.pumpAndSettle();

    final saved = container
        .read(managedNodesProvider)
        .requireValue
        .firstWhere((n) => n.id == 'p');
    expect(saved.label, 'Pinned renamed');
    expect(
      saved.sshHostFingerprint,
      'SHA256:PINNEDKEY',
      reason: 'a benign edit must NOT silently drop the pin',
    );
    expect(
      saved.autoUpdate,
      isTrue,
      reason: 'a rename turned off a switch that runs root updates remotely',
    );
    expect(saved.veilVersion, '0.8.0');
  });

  testWidgets('changing the SSH endpoint drops the stale pin (SSH-MITM)', (
    tester,
  ) async {
    final credentials = _MemorySshCredentialsStore()
      ..values['p'] = const SavedSshCredentials(
        password: 'old-server-password',
      );
    await tester.pumpWidget(_host(credentials: credentials, storage: await _openStorage()));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ManagedNodesScreen)),
    );
    await container
        .read(managedNodesProvider.notifier)
        .upsert(
          const ManagedNode(
            id: 'p',
            label: 'Pinned',
            sshHost: 'srv.example',
            sshUser: 'u',
            sshHostFingerprint: 'SHA256:PINNEDKEY',
          ),
        );
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ManagedNodesScreen)));

    await tester.tap(find.byIcon(Icons.edit_outlined).last);
    await tester.pumpAndSettle();
    // Repoint at a DIFFERENT host — the old pin must not authorize it.
    await tester.enterText(
      find.widgetWithText(TextField, l.nodeSshHostLabel),
      'other.example',
    );
    await tester.pump();
    expect(find.text(l.sshCredentialsEndpointCleared), findsOneWidget);
    final passwordField = tester.widget<TextField>(
      find.widgetWithText(TextField, l.sshSavedPasswordLabel),
    );
    expect(passwordField.controller!.text, isEmpty);
    await tester.ensureVisible(find.text(l.actionSave));
    await tester.tap(find.text(l.actionSave));
    await tester.pumpAndSettle();

    final saved = container
        .read(managedNodesProvider)
        .requireValue
        .firstWhere((n) => n.id == 'p');
    expect(saved.sshHost, 'other.example');
    expect(
      saved.sshHostFingerprint,
      isNull,
      reason: 'a changed endpoint must drop the pin for the old host',
    );
    expect(credentials.values.containsKey('p'), isFalse);
  });
}
