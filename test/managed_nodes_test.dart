import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/features/network/managed_nodes_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/managed_nodes_controller.dart';
import 'package:xveil/state/proxy_routing_controller.dart';

const _exit =
    'aa11bb22cc33dd44ee55ff66007788990011223344556677889900aabbccddee';

Widget _host() => const ProviderScope(
  child: MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: ManagedNodesScreen(),
  ),
);

void main() {
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

    expect(find.widgetWithText(TextField, l.nodeIdLabel), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, l.nodeLabelLabel),
      'Existing relay',
    );
    await tester.ensureVisible(find.text(l.actionSave));
    await tester.tap(find.text(l.actionSave));
    await tester.pumpAndSettle();
    expect(find.text(l.nodeIdRequired), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, l.nodeIdLabel),
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

    await tester.tap(find.byIcon(Icons.edit_outlined).last);
    await tester.pumpAndSettle();
    // Repoint at a DIFFERENT host — the old pin must not authorize it.
    await tester.enterText(
      find.widgetWithText(TextField, l.nodeSshHostLabel),
      'other.example',
    );
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
  });
}
