// A Storage that remembers settings and the chunked file store.
//
// Kept to that, deliberately: anything else a test reaches for through this
// hits noSuchMethod and fails loudly, rather than quietly returning a default
// that makes the test pass for a reason nobody chose.
import 'dart:typed_data';

import 'package:xveil/data/storage/storage.dart';

/// What ONE setting record can hold in a real container.
///
/// The store seals a setting into a single 4 KiB chunk whose usable payload
/// after nonce, tag and header is about 4040 bytes. This fake used to enforce
/// nothing, and that gap is not theoretical: FIVE times now a value has grown
/// past this limit, every closed-loop test stayed green, and the failure only
/// appeared against a real container as `PayloadTooLarge` — most recently the
/// sovereign identity material, whose hybrid master public key alone is 929
/// bytes (found by running a daemon, 2026-09-12). A fake that cannot fail the
/// way the real thing fails is a fake that certifies the wrong design.
const int kFakeSettingCap = 4000;

class FakeSettingStorage implements Storage {
  final settings = <String, String>{};

  /// The chunked file store: no per-record cap, because the real one splits
  /// across as many chunks as it needs. This is where anything past
  /// [kFakeSettingCap] belongs.
  final files = <String, Uint8List>{};

  @override
  Future<void> putSetting(String key, String value) async {
    if (value.length > kFakeSettingCap) {
      throw StateError(
        'PayloadTooLarge: payload exceeds chunk capacity — a setting holds at '
        'most $kFakeSettingCap bytes and $key was given ${value.length}. Put '
        'it in the file store (storeFile/loadFile).',
      );
    }
    settings[key] = value;
  }

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    files[fileId] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) async =>
      files[fileId];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
