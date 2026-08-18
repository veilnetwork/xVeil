// The QR ceiling, checked against the renderer rather than against a number
// somebody wrote down.
//
// `QrImageView` cannot be asked whether it can draw a string. `QrValidator`
// answers "valid" for a payload of any length — `QrCode.fromData` loops
// `typeNumber` from 1 to 39 and returns 40 by falling out of the loop, never
// testing it — so `errorStateBuilder` is unreachable for the one failure it
// exists for, and the refusal arrives from inside the paint instead. These pin
// both halves: that the constant is exactly where the renderer's own limit is,
// and that the library really does behave the way the constant assumes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:xveil/core/qr_payload.dart';

Future<Object?> _paint(WidgetTester tester, String data) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(child: QrImageView(data: data, size: 200)),
      ),
    ),
  );
  await tester.pump();
  return tester.takeException();
}

void main() {
  testWidgets('the ceiling is the renderer\'s, to the byte', (tester) async {
    expect(await _paint(tester, 'a' * kQrMaxBytes), isNull);
    expect(
      await _paint(tester, 'a' * (kQrMaxBytes + 1)),
      isNotNull,
      reason:
          'one byte over must be where the renderer gives up, or the '
          'constant is guessing',
    );
  });

  testWidgets('an oversized payload validates as VALID and then throws', (
    tester,
  ) async {
    // Why the length is checked instead of the error state being handled: the
    // library reports success and fails later, in the render pipeline.
    final tooLong = 'a' * (kQrMaxBytes + 1);
    expect(QrValidator.validate(data: tooLong).isValid, isTrue);
    expect(await _paint(tester, tooLong), isNotNull);
  });

  test('fitsInQrCode measures bytes, not code units', () {
    expect(fitsInQrCode('a' * kQrMaxBytes), isTrue);
    expect(fitsInQrCode('a' * (kQrMaxBytes + 1)), isFalse);
    // A multi-byte character costs what it costs on the wire — the QR carries
    // utf8, so counting characters would let a payload past the ceiling.
    expect(fitsInQrCode('é' * (kQrMaxBytes ~/ 2)), isTrue);
    expect(fitsInQrCode('é' * (kQrMaxBytes ~/ 2 + 1)), isFalse);
  });
}
