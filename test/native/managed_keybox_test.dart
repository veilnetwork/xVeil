import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_keybox.dart';
import 'package:xveil/data/storage/managed_store_tag.dart';

final _id = ManagedIdentityId('1' * 32);
final _userPassword = Uint8List.fromList([1, 2, 3]);
HvKvLogStore _open(
  String path, {
  bool create = false,
  Uint8List? keys,
  Uint8List? password,
}) {
  final space = create
      ? hv.HvSpace.create(
          path: path,
          password: _userPassword,
          argon: hv.ArgonPreset.min,
        )
      : keys != null
      ? hv.HvSpace.openWithKeys(path: path, keys: keys)
      : hv.HvSpace.open(path: path, password: password ?? _userPassword);
  if (!create) space.cancelDeferredVacuum();
  space.setPaddingPolicy(hv.PaddingPreset.none);
  return HvKvLogStore(space);
}

class _LostResponse implements Exception {}

class _InterruptCommit extends HvKvLogStore {
  _InterruptCommit(super.space, this.after);
  final bool after;
  @override
  int commit(List<KvLogOp> ops) {
    if (after) super.commit(ops);
    throw _LostResponse();
  }
}

void main() {
  setUp(() => expect(ensureHiddenVolumeLoaded(), isTrue));
  Future<String> fixture() async {
    final dir = await Directory.systemTemp.createTemp('xveil-keybox-');
    addTearDown(() => dir.delete(recursive: true));
    return '${dir.path}/keybox.hv';
  }

  test(
    'random internal passwords survive password and outer-key reopen',
    () async {
      final path = await fixture();
      final box = ManagedKeybox.initializeNew(
        _open(path, create: true),
        identity: _id,
      );
      final expectedContent = box.copyContentPassword();
      final expectedMaintenance = box.copyMaintenancePassword();
      final keys = box.exportKeys();
      expect(expectedContent.length, 32);
      expect(expectedMaintenance.length, 32);
      expect(expectedContent, isNot(expectedMaintenance));
      final borrowed = box.copyContentPassword()..fillRange(0, 32, 0);
      expect(borrowed, isNot(expectedContent));
      expect(box.copyContentPassword(), expectedContent);
      box.close();
      expect(box.copyContentPassword, throwsStateError);
      expect(box.exportKeys, throwsStateError);
      for (final byKeys in [false, true]) {
        final reopened = ManagedKeybox.openOwned(
          _open(path, keys: byKeys ? keys : null),
          identity: _id,
        );
        try {
          expect(reopened.copyContentPassword(), expectedContent);
          expect(reopened.copyMaintenancePassword(), expectedMaintenance);
          expect(reopened.exportKeys(), keys);
        } finally {
          reopened.close();
        }
      }
      final bytes = await File(path).readAsBytes();
      bool contains(Uint8List needle) {
        for (var i = 0; i <= bytes.length - needle.length; i++) {
          var equal = true;
          for (var j = 0; j < needle.length; j++) {
            if (bytes[i + j] != needle[j]) {
              equal = false;
              break;
            }
          }
          if (equal) return true;
        }
        return false;
      }

      expect(contains(expectedContent), isFalse);
      expect(contains(expectedMaintenance), isFalse);
    },
  );

  test(
    'wrong credentials and wrong owner do not create replacement data or leak a lock',
    () async {
      final path = await fixture();
      ManagedKeybox.initializeNew(
        _open(path, create: true),
        identity: _id,
      ).close();
      final before = await File(path).readAsBytes();
      expect(
        () => _open(path, password: Uint8List.fromList([99])),
        throwsA(isA<hv.HvException>()),
      );
      expect(
        () => _open(path, keys: Uint8List(64)),
        throwsA(isA<hv.HvException>()),
      );
      expect(await File(path).readAsBytes(), before);
      expect(
        () => ManagedKeybox.openOwned(
          _open(path),
          identity: ManagedIdentityId('2' * 32),
        ),
        throwsStateError,
      );
      ManagedKeybox.openOwned(_open(path), identity: _id).close();
    },
  );

  test('existing non-keybox data is never adopted or reset', () async {
    final path = await fixture();
    final original = _open(path, create: true);
    original.commit([
      PutOp(Ns.settings, Uint8List.fromList([7]), Uint8List.fromList([8, 9])),
    ]);
    expect(
      () => ManagedKeybox.initializeNew(original, identity: _id),
      throwsStateError,
    );
    final cold = _open(path);
    try {
      expect(cold.get(Ns.settings, Uint8List.fromList([7])), [8, 9]);
    } finally {
      cold.close();
    }
    expect(
      () => ManagedKeybox.openOwned(_open(path), identity: _id),
      throwsStateError,
    );
  });

  test('wrong-role space is refused before reading keybox secrets', () async {
    final path = await fixture();
    final original = _open(path, create: true);
    original.commit([
      ManagedStoreTag(
        identity: _id,
        role: ManagedStoreRole.maintenance,
      ).putOp(),
    ]);
    expect(
      () => ManagedKeybox.openOwned(original, identity: _id),
      throwsStateError,
    );
    final cold = _open(path);
    try {
      expect(
        ManagedStoreTag.read(
          cold,
          identity: _id,
          role: ManagedStoreRole.maintenance,
        ).role,
        ManagedStoreRole.maintenance,
      );
    } finally {
      cold.close();
    }
  });

  test(
    'role and secrets remain atomic when the initialization response is lost',
    () async {
      for (final after in [false, true]) {
        final path = await fixture();
        final space = hv.HvSpace.create(
          path: path,
          password: _userPassword,
          argon: hv.ArgonPreset.min,
        );
        space.setPaddingPolicy(hv.PaddingPreset.none);
        expect(
          () => ManagedKeybox.initializeNew(
            _InterruptCommit(space, after),
            identity: _id,
          ),
          throwsA(isA<_LostResponse>()),
        );
        if (after) {
          final recovered = ManagedKeybox.openOwned(_open(path), identity: _id);
          try {
            expect(recovered.copyContentPassword().length, 32);
            expect(recovered.copyMaintenancePassword().length, 32);
          } finally {
            recovered.close();
          }
        } else {
          expect(
            () => ManagedKeybox.openOwned(_open(path), identity: _id),
            throwsStateError,
          );
          ManagedKeybox.initializeNew(_open(path), identity: _id).close();
        }
      }
    },
  );
}
