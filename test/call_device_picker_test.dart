import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/calls/call_device_picker.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/call_service.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppL10n.localizationsDelegates,
  supportedLocales: AppL10n.supportedLocales,
  theme: ThemeData.dark(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('shared settings sheet has matching audio and video tabs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        theme: ThemeData.dark(),
        home: Scaffold(
          body: CallDevicePickerPanel(
            devices: const [],
            onDismiss: () {},
            onSelect: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('call-settings-panel')), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);

    await tester.tap(find.text('Video'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('call-settings-video')), findsOneWidget);
    expect(find.text('No capture devices available'), findsOneWidget);
  });

  testWidgets('screen devices have a dedicated selectable section', (
    tester,
  ) async {
    CallMediaDevice? selected;
    var dismissed = 0;
    const screen = CallMediaDevice(
      id: '42',
      label: 'Main display (2560x1440)',
      kind: CallMediaDeviceKind.screen,
      selected: true,
    );

    await tester.pumpWidget(
      _host(
        CallDevicePickerPanel(
          devices: const [screen],
          onDismiss: () => dismissed++,
          onSelect: (device) => selected = device,
        ),
      ),
    );
    await tester.tap(find.text('Video'));
    await tester.pumpAndSettle();

    expect(find.text('Screens'), findsOneWidget);
    expect(find.text(screen.label), findsOneWidget);
    expect(find.byIcon(Icons.monitor), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text(screen.label));
    expect(selected, screen);
    expect(dismissed, 0);
  });
}
