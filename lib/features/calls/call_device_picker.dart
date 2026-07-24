import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/call_audio_route.dart';
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
    final windows = devices
        .where((device) => device.kind == CallMediaDeviceKind.window)
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
            key: const ValueKey('call-settings-panel'),
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.68,
              child: DefaultTabController(
                length: 2,
                child: Column(
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
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          l.callDevices,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ),
                    TabBar(
                      tabs: [
                        Tab(text: l.callSettingsAudio),
                        Tab(text: l.callSettingsVideo),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          ListView(
                            key: const ValueKey('call-settings-audio'),
                            padding: const EdgeInsets.only(bottom: 20),
                            children: [
                              if (callAudioRouter.supportsPhoneRouting) ...[
                                _SectionLabel(l.callAudioOutput),
                                ValueListenableBuilder<CallAudioRoute>(
                                  valueListenable: callAudioRouter.route,
                                  builder: (context, route, _) => Column(
                                    children: [
                                      _RouteTile(
                                        route: CallAudioRoute.speaker,
                                        selected:
                                            route == CallAudioRoute.speaker,
                                        label: l.callSpeaker,
                                      ),
                                      _RouteTile(
                                        route: CallAudioRoute.earpiece,
                                        selected:
                                            route == CallAudioRoute.earpiece,
                                        label: l.callEarpiece,
                                      ),
                                    ],
                                  ),
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
                            ],
                          ),
                          ListView(
                            key: const ValueKey('call-settings-video'),
                            padding: const EdgeInsets.only(bottom: 20),
                            children: [
                              if (cameras.isNotEmpty) ...[
                                _SectionLabel(l.callCameras),
                                for (final device in cameras)
                                  _DeviceTile(
                                    device: device,
                                    onTap: () => onSelect(device),
                                  ),
                              ],
                              if (screens.isNotEmpty) ...[
                                _SectionLabel(l.callDisplays),
                                for (final device in screens)
                                  _DeviceTile(
                                    device: device,
                                    onTap: () => onSelect(device),
                                  ),
                              ],
                              if (windows.isNotEmpty) ...[
                                _SectionLabel(l.callWindows),
                                for (final device in windows)
                                  _DeviceTile(
                                    device: device,
                                    onTap: () => onSelect(device),
                                  ),
                              ],
                              if (cameras.isEmpty &&
                                  screens.isEmpty &&
                                  windows.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(
                                    l.callNoCaptureDevices,
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RouteTile extends StatelessWidget {
  const _RouteTile({
    required this.route,
    required this.selected,
    required this.label,
  });

  final CallAudioRoute route;
  final bool selected;
  final String label;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('call-route-${route.name}'),
    leading: Icon(
      route == CallAudioRoute.speaker
          ? Icons.volume_up_rounded
          : Icons.phone_in_talk_rounded,
    ),
    title: Text(label),
    trailing: Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_off,
      color: selected ? Theme.of(context).colorScheme.primary : null,
    ),
    onTap: () => callAudioRouter.setRoute(route),
  );
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
      CallMediaDeviceKind.window => Icons.web_asset,
    }),
    title: Text(device.label),
    trailing: device.selected ? const Icon(Icons.check) : null,
    onTap: onTap,
  );
}
