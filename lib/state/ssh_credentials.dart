import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/node/ssh_credentials.dart';
import '../data/storage/storage.dart';
import 'providers.dart';

const _sshCredentialsPrefix = 'managed_node_ssh_credentials.v1:';

/// Per-node SSH-secret persistence inside the encrypted, deniable xVeil space.
/// Nothing is written to SharedPreferences, platform plaintext preferences, or
/// the managed-node catalog itself.
abstract interface class SshCredentialsStore {
  Future<SavedSshCredentials> load(String nodeId);
  Future<void> save(String nodeId, SavedSshCredentials credentials);
  Future<void> clear(String nodeId);
}

class SshCredentialsRepository implements SshCredentialsStore {
  const SshCredentialsRepository(this._storage);

  final Storage _storage;

  String _key(String nodeId) => '$_sshCredentialsPrefix$nodeId';

  @override
  Future<SavedSshCredentials> load(String nodeId) async {
    try {
      return SavedSshCredentials.decode(
        await _storage.getSetting(_key(nodeId)),
      );
    } catch (_) {
      return const SavedSshCredentials();
    }
  }

  @override
  Future<void> save(String nodeId, SavedSshCredentials credentials) =>
      _storage.putSetting(
        _key(nodeId),
        credentials.isEmpty ? '' : credentials.encode(),
      );

  @override
  Future<void> clear(String nodeId) => _storage.putSetting(_key(nodeId), '');
}

final sshCredentialsRepositoryProvider = Provider<SshCredentialsStore>(
  (ref) => SshCredentialsRepository(ref.watch(storageProvider)),
);
