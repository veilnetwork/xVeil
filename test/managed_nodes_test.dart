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
import 'package:xveil/state/ssh_credentials.dart';

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

Widget _host({_MemorySshCredentialsStore? credentials}) => ProviderScope(
  overrides: [
    sshCredentialsRepositoryProvider.overrideWithValue(
      credentials ?? _MemorySshCredentialsStore(),
    ),
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
  });

  testWidgets('empty registry shows the hint; adding a node lists it', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
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
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ManagedNodesScreen)));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text(l.nodesAddChoiceTitle), findsOneWidget);
    expect(find.text(l.nodesAddExisting), findsOneWidget);
    expect(find.text(l.nodesBootstrapNew), findsOneWidget);
  });

  testWidgets('an existing node requires its node id', (tester) async {
    await tester.pumpWidget(_host());
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
    await tester.pumpWidget(_host());
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
    await tester.pumpWidget(_host(credentials: credentials));
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
    await tester.pumpWidget(_host());
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
    await tester.pumpWidget(_host());
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
    expect(find.text(l.nodeServices), findsOneWidget);
    expect(find.text('oproxy-server'), findsWidgets);
  });

  testWidgets('editing a node keeps its pinned SSH host key (SSH-MITM)', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
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
  });

  testWidgets('changing the SSH endpoint drops the stale pin (SSH-MITM)', (
    tester,
  ) async {
    final credentials = _MemorySshCredentialsStore()
      ..values['p'] = const SavedSshCredentials(
        password: 'old-server-password',
      );
    await tester.pumpWidget(_host(credentials: credentials));
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
