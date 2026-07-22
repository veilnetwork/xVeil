import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/app_localizations.dart';

/// Full-screen camera scanner for redeeming a contact's invite QR. Pops with
/// the scanned `veil:` URI string, or null if the user backs out. Non-veil
/// codes are ignored (with a brief hint) so a stray barcode can't be mistaken
/// for an invite. The camera feed is never recorded or transmitted — frames are
/// decoded on-device and discarded.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

/// Classifies one camera result before it touches navigation. Looking at the
/// whole capture first avoids flashing a "not an invite" warning when the same
/// frame also contains a valid xVeil QR code.
({String? invite, bool sawNonInvite}) classifyScannedInviteValues(
  Iterable<String?> rawValues,
) {
  var sawNonInvite = false;
  for (final raw in rawValues) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) continue;
    if (value.startsWith('veil:')) {
      return (invite: value, sawNonInvite: sawNonInvite);
    }
    sawNonInvite = true;
  }
  return (invite: null, sawNonInvite: sawNonInvite);
}

class _QrScanScreenState extends State<QrScanScreen>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    autoZoom: true,
  );
  // One-shot: stop reacting after the first valid invite so we pop exactly once.
  bool _handled = false;
  bool _showedNotInvite = false;
  Timer? _cameraInitTimer;
  bool _cameraInitTimedOut = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onControllerChanged);
    _cameraInitTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted || _controller.value.isInitialized) return;
      setState(() => _cameraInitTimedOut = true);
    });
  }

  void _onControllerChanged() {
    if (!_controller.value.isInitialized) return;
    _cameraInitTimer?.cancel();
    _cameraInitTimer = null;
    if (_cameraInitTimedOut && mounted) {
      setState(() => _cameraInitTimedOut = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final scanner = _controller.value;
    // The camera-permission dialog can emit lifecycle events before the native
    // scanner is initialized. Starting or stopping in that window would race
    // the permission request.
    if (!scanner.hasCameraPermission) return;
    switch (state) {
      case AppLifecycleState.resumed:
        if (!scanner.isRunning) unawaited(_controller.start());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (scanner.isRunning) unawaited(_controller.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _cameraInitTimer?.cancel();
    super.dispose();
    unawaited(_controller.dispose());
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final decision = classifyScannedInviteValues(
      capture.barcodes.map((code) => code.rawValue),
    );
    if (decision.invite case final invite?) {
      _handled = true;
      Navigator.of(context).pop(invite);
      return;
    }
    // A readable code that isn't an invite — nudge once, keep scanning.
    if (decision.sawNonInvite && !_showedNotInvite && mounted) {
      _showedNotInvite = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).scanNotInvite)),
      );
    }
  }

  Rect _scanWindow(Size size) {
    const hintHeight = 96.0;
    final availableHeight = math.max(0.0, size.height - hintHeight);
    final side = math.min(
      320.0,
      math.min(size.width * 0.72, availableHeight * 0.72),
    );
    if (side < 96) return Rect.zero;
    return Rect.fromCenter(
      center: Offset(size.width / 2, availableHeight / 2),
      width: side,
      height: side,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.scanTitle),
        actions: [
          ValueListenableBuilder(
            valueListenable: _controller,
            builder: (context, scanner, _) {
              final torchOn = scanner.torchState == TorchState.on;
              final available = scanner.torchState != TorchState.unavailable;
              return IconButton(
                tooltip: torchOn ? l.scanTorchOff : l.scanTorchOn,
                icon: Icon(
                  torchOn
                      ? Icons.flashlight_off_outlined
                      : Icons.flashlight_on_outlined,
                ),
                onPressed: available
                    ? () => unawaited(_controller.toggleTorch())
                    : null,
              );
            },
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final scanWindow = _scanWindow(constraints.biggest);
          return Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                scanWindow: scanWindow.isEmpty ? null : scanWindow,
                scanWindowUpdateThreshold: 2,
                tapToFocus: true,
                placeholderBuilder: (_) =>
                    const Center(child: CircularProgressIndicator()),
                errorBuilder: (context, error) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.no_photography_outlined, size: 48),
                        const SizedBox(height: 16),
                        Text(l.scanUnavailable, textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              ),
              if (!scanWindow.isEmpty && !_cameraInitTimedOut)
                IgnorePointer(
                  child: ScanWindowOverlay(
                    controller: _controller,
                    scanWindow: scanWindow,
                    borderRadius: BorderRadius.circular(20),
                    borderWidth: 3,
                  ),
                ),
              if (_cameraInitTimedOut)
                ColoredBox(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.no_photography_outlined, size: 48),
                          const SizedBox(height: 16),
                          Text(l.scanUnavailable, textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  ),
                ),
              // Framing hint at the bottom so the user knows what to aim at.
              if (!_cameraInitTimedOut)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    color: Colors.black54,
                    child: Text(
                      l.scanHint,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
