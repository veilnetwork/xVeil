// A Storage that remembers settings and the chunked file store.
//
// Kept to that, deliberately: anything else a test reaches for through this
// hits noSuchMethod and fails loudly, rather than quietly returning a default
// that makes the test pass for a reason nobody chose.
import 'dart:convert';
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
/// The container's real number: `MAX_VALUE_LEN` in hidden-volume's
/// `space/index.rs`, checked by `Tx::put` before the commit.
///
/// It read 4000 and was measured in Dart CODE UNITS. Both were wrong in the
/// permissive direction: the real cap is 2048, and what it counts is UTF-8
/// BYTES — a multibyte character costs two or three of them and one code unit
/// here (report27 X24). A fake that admits what the container refuses is a
/// fake that certifies the wrong design, which is the whole reason this file
/// exists.
const int kFakeSettingCap = 2048;

class FakeSettingStorage implements Storage {
  final settings = <String, String>{};

  /// The chunked file store: no per-record cap, because the real one splits
  /// across as many chunks as it needs. This is where anything past
  /// [kFakeSettingCap] belongs.
  final files = <String, Uint8List>{};

  @override
  Future<void> putSetting(String key, String value) async {
    // BYTES, not code units: `putSetting` hands the string to `utf8.encode`
    // and the container counts what comes out.
    final bytes = utf8.encode(value).length;
    if (bytes > kFakeSettingCap) {
      throw StateError(
        'PayloadTooLarge: a setting holds at most $kFakeSettingCap bytes and '
        '$key was given $bytes. Put it in the file store '
        '(storeFile/loadFile).',
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
