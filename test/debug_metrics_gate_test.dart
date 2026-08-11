// Who gets the loopback metrics endpoint, and who does not.
//
// audit report10 X-10. One define controlled two things with OPPOSITE
// defaults: the soak hook read XVEIL_DEBUG_HOOK plainly (default false, so a
// full control plane is not on for everyone who builds in debug), while the
// metrics endpoint read the SAME name with defaultValue: true. An ordinary
// debug build with no defines therefore got no hook and an unauthenticated
// Prometheus endpoint on 39997/39998 that any local process could read.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/veil_stack.dart';

void main() {
  test('a plain debug build opens nothing', () {
    // The defect, stated as a test. No defines at all is the ordinary case —
    // every developer, every CI debug build, every `flutter run`.
    expect(
      debugMetricsWanted(
        debugBuild: true,
        metricsDefine: false,
        hookDefine: false,
      ),
      isFalse,
      reason: 'an unasked-for endpoint on loopback is still an endpoint',
    );
  });

  test('asking for metrics gets metrics', () {
    // The positive control. Without it "opens nothing" would also pass against
    // a gate that refused everybody, and the stands would lose the endpoint
    // with no test to say so.
    expect(
      debugMetricsWanted(
        debugBuild: true,
        metricsDefine: true,
        hookDefine: false,
      ),
      isTrue,
    );
  });

  test('a stand that only asks for the hook still gets metrics', () {
    // Deliberate. The leak was the DEFAULT, not the coupling: taking metrics
    // away from existing stand recipes would trade one surprise for another.
    expect(
      debugMetricsWanted(
        debugBuild: true,
        metricsDefine: false,
        hookDefine: true,
      ),
      isTrue,
    );
  });

  test('release never opens it, however loudly it is asked', () {
    expect(
      debugMetricsWanted(
        debugBuild: false,
        metricsDefine: true,
        hookDefine: true,
      ),
      isFalse,
    );
  });

  test('the call site asks this function, not the environment', () {
    // Structural, because the defect was a decision made AT the call site: a
    // `bool.fromEnvironment(..., defaultValue: true)` inline. A gate that is
    // correct in isolation and bypassed where it matters is the shape this
    // project has been caught by before, so the check is on the caller.
    final source = File('lib/data/veil_stack.dart').readAsStringSync();
    expect(
      source,
      contains('debugMetricsWanted('),
      reason: 'the metrics decision must go through the documented gate',
    );
    expect(
      source.contains("bool.fromEnvironment('XVEIL_DEBUG_HOOK', defaultValue"),
      isFalse,
      reason: 'no default-on reading of the hook define may come back',
    );
  });
}
