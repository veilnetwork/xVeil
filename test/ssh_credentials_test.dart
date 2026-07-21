import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/ssh_credentials.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/state/ssh_credentials.dart';

void main() {
  test(
    'SSH credentials persist per node in the encrypted settings store',
    () async {
      final backing = FakeKvLogStore();
      final storage = HiddenVolumeStorage(
        ({required Uint8List password, required bool create}) =>
            password.isEmpty ? null : backing,
      );
      await storage.open(password: 'container-password', createIfMissing: true);
      final repository = SshCredentialsRepository(storage);

      const first = SavedSshCredentials(password: 'first-secret');
      const second = SavedSshCredentials(
        privateKeyPem: 'PRIVATE KEY',
        publicKeyOpenSsh: 'ssh-ed25519 PUBLIC xveil',
      );
      await repository.save('node-a', first);
      await repository.save('node-b', second);

      expect((await repository.load('node-a')).password, 'first-secret');
      expect(
        (await repository.load('node-b')).publicKeyOpenSsh,
        contains('PUBLIC'),
      );
      await repository.clear('node-a');
      expect((await repository.load('node-a')).isEmpty, isTrue);
      expect((await repository.load('node-b')).hasKey, isTrue);
    },
  );
}
