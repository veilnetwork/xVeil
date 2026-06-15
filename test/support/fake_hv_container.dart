import 'dart:convert';
import 'dart:typed_data';

import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

/// Multi-space fake container for master-mode tests: a password opener and a
/// keys opener that share the same underlying spaces, so a space created by
/// password can be reopened by its exported keys — mirroring the real
/// `HvSpace` create/open/openWithKeys over one container file. Each space gets
/// deterministic 64-byte "SpaceKeys".
class FakeHvContainer {
  final _byKeys = <String, FakeKvLogStore>{};
  final _pwToKeyHex = <String, String>{};

  /// Models the native EXCLUSIVE per-file flock: at most one space open at a
  /// time. Acquiring while held throws (mirrors `HvException.Busy`); a store's
  /// close() releases it.
  bool _locked = false;

  String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  Uint8List _keysFor(String pw) {
    final base = utf8.encode(pw);
    return Uint8List.fromList(
        List.generate(64, (i) => (base[i % base.length] + i) & 0xff));
  }

  KvLogStore _acquire(FakeKvLogStore store) {
    if (_locked) {
      throw StateError('container is busy'); // mirrors HvException.Busy
    }
    _locked = true;
    store.onClose = () => _locked = false;
    return store;
  }

  SpaceOpener get passwordOpener =>
      ({required Uint8List password, required bool create}) {
        final pw = utf8.decode(password);
        final existing = _pwToKeyHex[pw];
        if (existing != null) return _acquire(_byKeys[existing]!);
        if (!create) return null; // AuthFailed
        final keys = _keysFor(pw);
        final hex = _hex(keys);
        _pwToKeyHex[pw] = hex;
        return _acquire(_byKeys[hex] = FakeKvLogStore(keys: keys));
      };

  KeysSpaceOpener get keysOpener => (Uint8List keys) {
        final store = _byKeys[_hex(keys)];
        return store == null ? null : _acquire(store);
      };

  /// A fresh storage handle wired to this container's password + keys openers.
  HiddenVolumeStorage storage() =>
      HiddenVolumeStorage(passwordOpener, keysOpener: keysOpener);
}
