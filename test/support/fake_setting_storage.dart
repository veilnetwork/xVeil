// A Storage that only remembers settings.
//
// Kept to that, deliberately: anything else a test reaches for through this
// hits noSuchMethod and fails loudly, rather than quietly returning a default
// that makes the test pass for a reason nobody chose.
import 'package:xveil/data/storage/storage.dart';

class FakeSettingStorage implements Storage {
  final settings = <String, String>{};

  @override
  Future<void> putSetting(String key, String value) async =>
      settings[key] = value;

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
