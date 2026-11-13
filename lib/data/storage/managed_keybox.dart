import 'dart:math';
import 'dart:typed_data';

import 'hv_kv_log_store.dart';
import 'kv_log_store.dart';
import 'managed_identity_catalog.dart';
import 'managed_store_tag.dart';

/// Immutable keybox for one enumerable encrypted identity. Its native space
/// uses the user password; random internal passwords remain encrypted inside
/// it. Exported outer keys stay stable when only content/maintenance repack.
///
/// Ownership of [HvKvLogStore] transfers on entry, including failed opens.
/// The file owner must admit/create the private path before supplying it.
final class ManagedKeybox {
  ManagedKeybox._(this._store, this.identity, Uint8List record)
    : _passwords = record.sublist(8);

  final HvKvLogStore _store;
  final ManagedIdentityId identity;
  final Uint8List _passwords;
  bool _closing = false;
  bool _closed = false;
  static const _magic = [0x58, 0x56, 0x4b, 0x42, 1, 0, 0, 0];
  static Uint8List get _key => Uint8List.fromList([0x78, 0x56, 0x4b, 1]);

  /// Only a fresh admitted native space (bootstrap sequence one) may be initialized.
  /// Role and secret record publish in the same native transaction. This is
  /// never a fallback when an existing keybox cannot be authenticated/read.
  factory ManagedKeybox.initializeNew(
    HvKvLogStore store, {
    required ManagedIdentityId identity,
  }) {
    final record = Uint8List(72)..setRange(0, 8, _magic);
    try {
      if (store.commitSeq() != 1) {
        throw StateError('Managed keybox is not a new space');
      }
      final random = Random.secure();
      do {
        for (var i = 8; i < record.length; i++) {
          record[i] = random.nextInt(256);
        }
      } while (_passwordsEqual(record));
      store.commit([
        ManagedStoreTag(
          identity: identity,
          role: ManagedStoreRole.keybox,
        ).putOp(),
        PutOp(Ns.settings, _key, record),
      ]);
      return ManagedKeybox._(store, identity, record);
    } catch (_) {
      store.close();
      rethrow;
    } finally {
      record.fillRange(0, record.length, 0);
    }
  }

  factory ManagedKeybox.openOwned(
    HvKvLogStore store, {
    required ManagedIdentityId identity,
  }) {
    Uint8List? record;
    try {
      ManagedStoreTag.read(
        store,
        identity: identity,
        role: ManagedStoreRole.keybox,
      );
      record = store.get(Ns.settings, _key);
      if (record == null || record.length != 72) {
        throw const FormatException('Invalid managed keybox secret record');
      }
      for (var i = 0; i < _magic.length; i++) {
        if (record[i] != _magic[i]) {
          throw const FormatException('Unknown managed keybox secret format');
        }
      }
      if (_passwordsEqual(record)) {
        throw const FormatException('Invalid managed keybox credentials');
      }
      return ManagedKeybox._(store, identity, record);
    } catch (_) {
      store.close();
      rethrow;
    } finally {
      record?.fillRange(0, record.length, 0);
    }
  }

  static bool _passwordsEqual(Uint8List record) {
    var different = 0;
    for (var i = 0; i < 32; i++) {
      different |= record[8 + i] ^ record[40 + i];
    }
    return different == 0;
  }

  void _requireOpen() {
    if (_closing || _closed) throw StateError('Managed keybox is closed');
  }

  /// Owned secret copy for native open/compaction. The caller must wipe its
  /// copy after the operation settles; no user password is stored here.
  Uint8List copyContentPassword() {
    _requireOpen();
    return _passwords.sublist(0, 32);
  }

  Uint8List copyMaintenancePassword() {
    _requireOpen();
    return _passwords.sublist(32);
  }

  Uint8List exportKeys() {
    _requireOpen();
    return _store.exportKeys();
  }

  SlotUtilization? slotUtilization() {
    _requireOpen();
    return _store.slotUtilization();
  }

  String? hardeningWarning() {
    _requireOpen();
    return _store.hardeningWarning();
  }

  void acknowledgeHardeningWarning() {
    _requireOpen();
    _store.acknowledgeHardeningWarning();
  }

  void close() {
    if (_closed) return;
    _closing = true;
    try {
      _store.close();
      _closed = true;
    } finally {
      _passwords.fillRange(0, _passwords.length, 0);
    }
  }
}
