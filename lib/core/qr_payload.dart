import 'dart:convert';

/// Will this string survive being drawn as a QR code?
///
/// Asked because `qr_flutter` cannot be asked. `QrValidator.validate` — which
/// is what `QrImageView` calls, and the only thing that decides whether
/// `errorStateBuilder` ever runs — reports VALID for a payload of any size:
/// `QrCode.fromData` picks a version with `for (typeNumber = 1; typeNumber < 40;
/// typeNumber++)`, so version 40 is never tested and is returned by falling out
/// of the loop, unchecked (qr 3.0.2, `qr_code.dart`). The real refusal
/// (`QrInputTooLongException`) is raised lazily from `_createData`, which runs
/// during PAINT. Measured: a 2 022-char string draws at version 33; 2 975
/// chars validate as "valid", build a `CustomPaint`, and then throw
/// `Input too long. 23820 > 23648` inside the render pipeline — so the failure
/// arrives as a broken frame rather than as an error state anybody can catch.
///
/// Check the length first, and the widget never sees a string it cannot draw.
bool fitsInQrCode(String data) => utf8.encode(data).length <= kQrMaxBytes;

/// The most a QR code can carry at all: byte mode, version 40, error
/// correction L — `qr_flutter`'s default and the largest of the four.
///
/// 23 648 bits of data capacity, less the 4-bit mode and the 16-bit length that
/// precede the payload at version 40, is 2 953 whole bytes. Nothing about this
/// is an xVeil budget; it is the ceiling of the format, and a payload above it
/// has to reach the other device by some other means.
const int kQrMaxBytes = (23648 - 20) ~/ 8;
