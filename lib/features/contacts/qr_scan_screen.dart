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

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController();
  // One-shot: stop reacting after the first valid invite so we pop exactly once.
  bool _handled = false;
  bool _showedNotInvite = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null || raw.isEmpty) continue;
      if (raw.startsWith('veil:')) {
        _handled = true;
        Navigator.of(context).pop(raw.trim());
        return;
      }
      // A readable code that isn't an invite — nudge once, keep scanning.
      if (!_showedNotInvite && mounted) {
        _showedNotInvite = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).scanNotInvite)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.scanTitle),
        actions: [
          IconButton(
            tooltip: l.scanTorch,
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error, _) => Center(
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
      ),
    );
  }
}
