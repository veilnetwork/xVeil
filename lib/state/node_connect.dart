import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/node/managed_node.dart';
import '../data/node/node_connect.dart';
import '../data/node/ssh_client.dart' show SshResult;
import '../data/storage/storage.dart';
import 'app_controller.dart' show IdentityLease;
import 'identity_guard.dart';
import 'providers.dart';

class NodeConnectRepository {
  const NodeConnectRepository(this.storage);
  final Storage storage;
  String _key(String id) => 'managed_node_connect.v1:$id';
  Future<NodeConnectSession?> load(String id) async =>
      NodeConnectSession.decode(await storage.getSetting(_key(id)));
  Future<void> save(String id, NodeConnectSession session) =>
      storage.putSetting(_key(id), session.encode());
  Future<void> clear(String id) => storage.putSetting(_key(id), '');
}

final nodeConnectRepositoryProvider = Provider(
  (ref) => NodeConnectRepository(ref.watch(storageProvider)),
);

typedef NodeConnectClientFactory =
    NodeConnectClient Function({
      required Uri endpoint,
      required String pin,
      bool Function()? isCurrent,
    });
final nodeConnectClientFactoryProvider = Provider<NodeConnectClientFactory>(
  (ref) => NodeConnectClient.new,
);

Future<SshResult> runNodeConnect(
  WidgetRef ref,
  ManagedNode node,
  IdentityLease lease,
  String command, {
  Duration timeout = const Duration(minutes: 2),
  bool Function()? isMounted,
}) async {
  bool current() => (isMounted?.call() ?? true) && ref.holdsIdentity(lease);
  if (!current()) {
    throw const NodeConnectException(NodeConnectFailure.identityChanged);
  }
  final session = await ref.read(nodeConnectRepositoryProvider).load(node.id);
  if (!current()) {
    throw const NodeConnectException(NodeConnectFailure.identityChanged);
  }
  if (session == null || session.endpoint.toString() != node.connectEndpoint) {
    throw const NodeConnectException(NodeConnectFailure.expired);
  }
  final client = ref.read(nodeConnectClientFactoryProvider)(
    endpoint: session.endpoint,
    pin: session.pin,
    isCurrent: current,
  );
  try {
    return await client.run(session, command, timeout: timeout);
  } finally {
    client.close();
  }
}
