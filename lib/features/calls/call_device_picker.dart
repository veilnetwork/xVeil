import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/call_service.dart';

class CallDevicePickerPanel extends StatelessWidget {
  const CallDevicePickerPanel({
    super.key,
    required this.devices,
    required this.onDismiss,
    required this.onSelect,
  });

  final List<CallMediaDevice> devices;
  final VoidCallback onDismiss;
  final ValueChanged<CallMediaDevice> onSelect;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final cameras = devices
        .where((device) => device.kind == CallMediaDeviceKind.camera)
        .toList(growable: false);
    final microphones = devices
        .where((device) => device.kind == CallMediaDeviceKind.microphone)
        .toList(growable: false);
    final screens = devices
        .where((device) => device.kind == CallMediaDeviceKind.screen)
        .toList(growable: false);
    return Stack(
      fit: StackFit.expand,
      children: [
        Semantics(
          label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: const ColoredBox(color: Color(0x99000000)),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.72,
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: SizedBox(
                        width: 32,
                        child: Divider(thickness: 4, height: 4),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Text(
                      l.callDevices,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (cameras.isNotEmpty) ...[
                    _SectionLabel(l.callCameras),
                    for (final device in cameras)
                      _DeviceTile(
                        device: device,
                        onTap: () => onSelect(device),
                      ),
                  ],
                  if (microphones.isNotEmpty) ...[
                    _SectionLabel(l.callMicrophones),
                    for (final device in microphones)
                      _DeviceTile(
                        device: device,
                        onTap: () => onSelect(device),
                      ),
                  ],
                  if (screens.isNotEmpty) ...[
                    _SectionLabel(l.callScreens),
                    for (final device in screens)
                      _DeviceTile(
                        device: device,
                        onTap: () => onSelect(device),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
    child: Text(label, style: Theme.of(context).textTheme.labelLarge),
  );
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.onTap});

  final CallMediaDevice device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(switch (device.kind) {
      CallMediaDeviceKind.camera => Icons.videocam,
      CallMediaDeviceKind.microphone => Icons.mic,
      CallMediaDeviceKind.screen => Icons.monitor,
    }),
    title: Text(device.label),
    trailing: device.selected ? const Icon(Icons.check) : null,
    onTap: onTap,
  );
}
