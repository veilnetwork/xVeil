import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Progress ring whose centre is an explicit cancel affordance. The whole
/// circular hit target is tappable, while the visual remains compact enough for
/// file rows, voice notes, image previews, and round video messages.
class CancelableDownloadProgress extends StatelessWidget {
  const CancelableDownloadProgress({
    super.key,
    required this.progress,
    required this.onCancel,
    this.size = 36,
    this.strokeWidth = 2.5,
    this.color,
  });

  final double? progress;
  final VoidCallback onCancel;
  final double size;
  final double strokeWidth;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      label: AppL10n.of(context).actionCancel,
      child: InkResponse(
        onTap: onCancel,
        radius: size / 2 + 6,
        customBorder: const CircleBorder(),
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: progress == null || progress == 0 ? null : progress,
                  strokeWidth: strokeWidth,
                  color: resolved,
                ),
              ),
              Icon(Icons.close_rounded, size: size * 0.48, color: resolved),
            ],
          ),
        ),
      ),
    );
  }
}
