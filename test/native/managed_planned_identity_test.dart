@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import '../support/erasure_writer_process.dart';

void main() {
  for (final phase in ['before', 'after', 'registered']) {
    test(
      'planned worker preserves interrupted existing creation at $phase',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final fixture = Directory.systemTemp.createTempSync(
          'xveil-managed-identity-crash-',
        );
        final profile = '${fixture.path}/profile';
        expect(
          const ManagedFsPlatform().createPrivateDirectory(profile),
          isTrue,
        );
        addTearDown(() => fixture.deleteSync(recursive: true));
        final id = ManagedIdentityId('1' * 32);
        await killErasureWriter(
          fixture.path,
          phase,
          () {},
          script: 'test/native/managed_identity_files_writer.dart',
        );
        await expectLater(
          ManagedWorkerIdentity.openPlannedEncrypted(
            profileDirectory: profile,
            id: id,
            password: Uint8List.fromList(utf8.encode('incorrect credential')),
          ),
          throwsA(
            isA<ManagedWorkerFailure>().having(
              (e) => e.kind,
              'kind',
              ManagedWorkerFailureKind.authentication,
            ),
          ),
        );
        await expectLater(
          ManagedWorkerIdentity.openPlannedUnencrypted(
            profileDirectory: profile,
            id: id,
          ),
          throwsA(isA<ManagedWorkerFailure>()),
        );
        final worker = await ManagedWorkerIdentity.openPlannedEncrypted(
          profileDirectory: profile,
          id: id,
          password: Uint8List.fromList(utf8.encode('fixture-crash-password')),
        );
        final keys = await worker.exportKeys();
        try {
          expect(
            await worker.get(1, Uint8List.fromList([1])),
            Uint8List.fromList([4, 5, 6]),
          );
        } finally {
          await worker.close();
        }
        final cold = await ManagedWorkerIdentity.openPlannedEncrypted(
          profileDirectory: profile,
          id: id,
          password: Uint8List.fromList(utf8.encode('fixture-crash-password')),
        );
        try {
          final actual = await cold.exportKeys();
          try {
            expect(actual, keys);
          } finally {
            actual.fillRange(0, actual.length, 0);
          }
          expect(
            await cold.get(1, Uint8List.fromList([1])),
            Uint8List.fromList([4, 5, 6]),
          );
        } finally {
          keys.fillRange(0, keys.length, 0);
          await cold.close();
        }
      },
    );
  }
}
