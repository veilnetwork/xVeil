import 'package:flutter_test/flutter_test.dart';

import 'support/fake_setting_storage.dart';

void main() {
  /// The shared fake refuses exactly what a container refuses.
  ///
  /// It read 4000 and counted Dart CODE UNITS. Both were wrong in the
  /// permissive direction: the real cap is `MAX_VALUE_LEN` = 2048, and what is
  /// counted is UTF-8 BYTES — a Cyrillic character costs two of them and one
  /// code unit. So a value between 2048 and 4000 bytes, or a multibyte value
  /// under 4000 code units, passed every closed-loop test and was refused by
  /// the real thing (report27 X24). This file exists because that has happened
  /// five times.
  group('the setting fake and the container agree', () {
    test('the cap is 2048', () {
      expect(kFakeSettingCap, 2048);
    });

    test('exactly the cap is accepted and one byte past it is not', () async {
      final storage = FakeSettingStorage();
      await storage.putSetting('at', 'a' * 2048);
      expect(storage.settings['at']!.length, 2048);
      await expectLater(
        storage.putSetting('past', 'a' * 2049),
        throwsA(isA<StateError>()),
      );
    });

    test('what it counts is bytes, not code units', () async {
      final storage = FakeSettingStorage();
      // 1024 two-byte characters: 1024 code units, 2048 bytes — the last
      // value that fits.
      await storage.putSetting('multibyte-at', 'д' * 1024);
      await expectLater(
        storage.putSetting('multibyte-past', 'д' * 1025),
        throwsA(isA<StateError>()),
        reason:
            'this is 1025 code units and 2050 bytes — a fake counting code '
            'units admits it and the container refuses it',
      );
    });
  });
}
