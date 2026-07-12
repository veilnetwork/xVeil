import 'package:flutter/widgets.dart';

class Barcode {
  const Barcode({this.rawValue});

  final String? rawValue;
}

class BarcodeCapture {
  const BarcodeCapture({this.barcodes = const []});

  final List<Barcode> barcodes;
}

class MobileScannerException implements Exception {
  const MobileScannerException();

  MobileScannerErrorDetails get errorDetails => const MobileScannerErrorDetails(
    'Camera scanning is unavailable in iOS Simulator',
  );

  @override
  String toString() => 'Camera scanning is unavailable in iOS Simulator';
}

class MobileScannerErrorDetails {
  const MobileScannerErrorDetails(this.message);

  final String message;
}

class MobileScannerController {
  Future<void> toggleTorch() async {}

  Future<void> dispose() async {}
}

typedef MobileScannerErrorBuilder =
    Widget Function(
      BuildContext context,
      MobileScannerException error,
      Widget? child,
    );

/// Simulator-only stand-in for the MLKit-backed camera view. QR scanning is a
/// physical-device feature; showing the production error UI is more honest
/// than a fabricated camera feed.
class MobileScanner extends StatelessWidget {
  const MobileScanner({
    super.key,
    this.controller,
    required this.onDetect,
    this.errorBuilder,
  });

  final MobileScannerController? controller;
  final void Function(BarcodeCapture capture) onDetect;
  final MobileScannerErrorBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) =>
      errorBuilder?.call(context, const MobileScannerException(), null) ??
      const SizedBox.expand();
}
