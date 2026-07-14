import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/debug/ui_driver.dart';

void main() {
  group('boundedScreenshotScale', () {
    test('preserves a phone scale=4 screenshot below the RGBA budget', () {
      expect(boundedScreenshotScale(const Size(407, 904), 4), 4);
    });

    test('caps a large desktop surface to the raw-pixel budget', () {
      const size = Size(2560, 1440);
      final scale = boundedScreenshotScale(size, 4);

      expect(scale, lessThan(4));
      expect(
        size.width * size.height * scale * scale,
        closeTo(maxDebugScreenshotPixels, 1),
      );
    });

    test('normalizes a non-finite requested scale', () {
      expect(boundedScreenshotScale(const Size(100, 100), double.nan), 1);
    });
  });

  group('ScreenshotOperationGate', () {
    test('serializes the complete async operation in FIFO order', () async {
      final gate = ScreenshotOperationGate();
      var active = 0;
      var maxActive = 0;
      final entered = <int>[];

      final results = await Future.wait([
        for (var i = 0; i < 8; i++)
          gate.run(() async {
            active++;
            maxActive = active > maxActive ? active : maxActive;
            entered.add(i);
            await Future<void>.delayed(const Duration(milliseconds: 2));
            active--;
            return i;
          }),
      ]);

      expect(maxActive, 1);
      expect(entered, orderedEquals(List<int>.generate(8, (i) => i)));
      expect(results, orderedEquals(List<int>.generate(8, (i) => i)));
    });

    test('releases the next request after an operation throws', () async {
      final gate = ScreenshotOperationGate();
      final first = gate.run<void>(() => throw StateError('capture failed'));
      final second = gate.run(() async => 42);

      await expectLater(first, throwsStateError);
      await expectLater(second, completion(42));
    });
  });
}
