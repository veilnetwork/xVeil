import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'call screen host belongs to the Activity lifetime, not engine setup',
    () {
      final source = File(
        'android/app/src/main/kotlin/network/veil/xveil/MainActivity.kt',
      ).readAsStringSync();
      final configureStart = source.indexOf(
        'override fun configureFlutterEngine(',
      );
      final configureEnd = source.indexOf(
        '\n    override fun ',
        configureStart + 1,
      );
      expect(configureStart, greaterThanOrEqualTo(0));
      expect(configureEnd, greaterThan(configureStart));
      final configure = source.substring(configureStart, configureEnd);
      expect(configure, contains('CallScreenActivity.attachHost(this)'));
      expect(
        configure.contains('CallScreenActivity.detachHost('),
        isFalse,
        reason: 'engine configuration must leave the call-screen host attached',
      );

      final destroy = RegExp(
        r'override fun onDestroy\(\)\s*\{([\s\S]*?)\n    \}',
      ).firstMatch(source)!.group(1)!;
      expect(destroy, contains('CallScreenActivity.detachHost(this)'));
      expect(source.split('CallScreenActivity.detachHost(this)').length - 1, 1);
    },
  );
}
