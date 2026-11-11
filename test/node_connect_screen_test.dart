import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/data/node/node_connect.dart';
import 'package:xveil/data/node/ssh_client.dart';
import 'package:xveil/features/network/node_connect_screen.dart';
import 'package:xveil/features/network/node_management_screen.dart';
import 'package:xveil/features/network/ssh_command_dialog.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/managed_nodes_controller.dart';
import 'package:xveil/state/node_connect.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_setting_storage.dart';

class _Owner extends AppController {
  bool current = true;
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  bool holdsIdentity(IdentityLease lease) =>
      current && super.holdsIdentity(lease);
}

class _Client extends NodeConnectClient {
  _Client()
    : super(endpoint: Uri.parse('https://server.example:8443'), pin: 'a' * 64);
  final entered = Completer<void>();
  final finish = Completer<SshResult>();
  int claims = 0;
  NodeConnectSession get session => NodeConnectSession(
    endpoint: endpoint,
    pin: pin,
    token: base64UrlEncode(List.filled(32, 17)).replaceAll('=', ''),
    expires: DateTime.now().add(const Duration(minutes: 10)),
  );
  @override
  Future<NodeConnectSession> claim(NodeConnectInvite invite) async {
    claims++;
    return session;
  }

  @override
  Future<Map<String, dynamic>> info(NodeConnectSession session) async => {
    'host_os': 'linux',
  };
  @override
  Future<SshResult> run(
    NodeConnectSession session,
    String script, {
    Duration timeout = const Duration(minutes: 2),
  }) {
    if (!entered.isCompleted) entered.complete();
    return finish.future;
  }
}

void main() {
  String invite(_Client client) => Uri(
    scheme: 'xveil',
    path: 'node',
    queryParameters: {
      'v': '1',
      'endpoint': client.endpoint.toString(),
      'pin': client.pin,
      'token': client.session.token,
      'expires':
          '${DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000}',
    },
  ).toString();
  const node = ManagedNode(
    id: 'qa',
    label: 'server',
    connectEndpoint: 'https://server.example:8443',
  );
  SshResult inventory() => SshResult(
    stdout: 'NODE_ID: ${'a' * 64}\n',
    stderr: '',
    exitCode: 0,
    hostFingerprint: '',
  );

  Future<ProviderContainer> host(
    WidgetTester tester,
    _Owner owner,
    _Client client,
    FakeSettingStorage storage,
    Widget screen,
  ) async {
    final container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(() => owner),
        storageProvider.overrideWith((ref) => storage),
        nodeConnectClientFactoryProvider.overrideWithValue(
          ({required endpoint, required pin, isCurrent}) => client,
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(client.close);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: screen,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  for (final switched in [false, true]) {
    testWidgets(
      'pairing completion ${switched ? 'cannot cross identity change' : 'saves node and separate secret'}',
      (tester) async {
        final owner = _Owner(),
            client = _Client(),
            storage = FakeSettingStorage();
        final container = await host(
          tester,
          owner,
          client,
          storage,
          const NodeConnectScreen(),
        );
        await tester.enterText(
          find.byKey(const ValueKey('node-connect-code')),
          invite(client),
        );
        await tester.tap(find.byKey(const ValueKey('node-connect-pair')));
        await tester.pump();
        expect(client.entered.isCompleted, isTrue);
        if (switched) owner.current = false;
        client.finish.complete(inventory());
        if (switched) {
          await tester.pump();
        } else {
          await tester.pumpAndSettle();
        }
        final nodes = await container.read(managedNodesProvider.future);
        expect(nodes.length, switched ? 0 : 1);
        if (!switched) {
          expect(find.byType(NodeManagementScreen), findsOneWidget);
          expect(nodes.single.hasSsh, isFalse);
          expect(nodes.single.hasManagement, isTrue);
          final session = await container
              .read(nodeConnectRepositoryProvider)
              .load(nodes.single.id);
          expect(session!.token, client.session.token);
          expect(ManagedNode.encodeList(nodes), isNot(contains(session.token)));
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      'operation callback ${switched ? 'is rejected after identity change' : 'is accepted for original identity'}',
      (tester) async {
        final owner = _Owner(),
            client = _Client(),
            storage = FakeSettingStorage();
        await NodeConnectRepository(storage).save(node.id, client.session);
        var callbacks = 0;
        await host(
          tester,
          owner,
          client,
          storage,
          SshCommandDialog(
            node: node,
            title: 'QA',
            command: 'true',
            onSuccess: (_) async {
              callbacks++;
            },
          ),
        );
        expect(find.byType(SegmentedButton<bool>), findsNothing);
        await tester.tap(find.text('Run command'));
        await tester.pump();
        expect(client.entered.isCompleted, isTrue);
        if (switched) owner.current = false;
        client.finish.complete(inventory());
        await tester.pump();
        expect(callbacks, switched ? 0 : 1);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
