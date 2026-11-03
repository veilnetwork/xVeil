import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/stand_cpu_profile.dart';

int _profileWork(int value) {
  var result = value;
  for (var i = 0; i < 500000; i++) {
    result = (result * 31 + i) & 0x7fffffff;
  }
  return result;
}

void main() {
  testWidgets(
    'stand profiler observes its own CPU work through loopback',
    (tester) async {
      await tester.runAsync(() async {
      final profile = StandCpuProfile();
      addTearDown(profile.close);
      await profile.reset();
      final timer = Stopwatch()..start();
      var value = 1;
      while (timer.elapsedMilliseconds < 500) {
        value = _profileWork(value);
        await Future<void>.delayed(Duration.zero);
      }
      expect(value, isNonNegative);
      final result = await profile.snapshot();
      expect(result['endMicros'], greaterThan(result['originMicros'] as int));
      final samples = result['isolates'] as List;
      expect(samples, isNotEmpty);
      expect(
        samples.any(
          (entry) =>
              (entry['samples']['sampleCount'] as int) > 0 &&
              (entry['samples']['functions'] as List).any(
                (function) =>
                    '${function['function']}'.contains('_profileWork'),
              ),
        ),
        isTrue,
        reason: 'an empty response is not a usable CPU profile',
      );
      });
    },
    skip: Platform.environment['XVEIL_E2E_CPU_PROFILE'] != '1',
  );
}
