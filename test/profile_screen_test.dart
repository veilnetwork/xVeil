import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/settings/profile_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

Future<void> _pumpScreen(WidgetTester tester, {Locale? locale}) =>
    tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: const ProfileScreen(),
        ),
      ),
    );

Future<void> _waitFor(WidgetTester tester, Finder widget) async {
  final elapsed = Stopwatch()..start();
  while (widget.evaluate().isEmpty &&
      elapsed.elapsed < const Duration(seconds: 5)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(widget, findsOneWidget);
}

void main() {
  for (final keyboard in [false, true]) {
    testWidgets('profile creation supports large text (keyboard=$keyboard)', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 460);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final support = Directory.systemTemp.createTempSync('xveil-profile-ui-');
      addTearDown(() => support.deleteSync(recursive: true));
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        _pathProvider,
        (_) async => support.path,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(_pathProvider, null),
      );

      await tester.runAsync(() async {
        final createProfile = find.byType(FloatingActionButton);
        await _pumpScreen(tester, locale: const Locale('ru'));
        await _waitFor(tester, createProfile);
        final l = AppL10n.of(tester.element(find.byType(ProfileScreen)));
        await tester.pumpAndSettle();
        await tester.tap(createProfile);
        await tester.pumpAndSettle();
        if (keyboard) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 230);
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        final rule = find.text(l.profileNameRule);
        await tester.ensureVisible(rule);
        await tester.pumpAndSettle();
        final paragraph = tester.renderObject<RenderParagraph>(rule);
        expect(paragraph.didExceedMaxLines, isFalse);

        final confirm = find.widgetWithText(FilledButton, l.commonCreate);
        final field = find.byType(TextField);
        await tester.ensureVisible(field);
        await tester.enterText(field, 'testing');
        await tester.pumpAndSettle();
        expect(confirm.hitTestable(), findsOneWidget);
        await tester.tap(confirm);
        tester.view.resetViewInsets();
        await _waitFor(tester, find.text(l.profileRestartRequired));
        final choice = File('${support.path}/xveil.profile');
        expect(choice.readAsStringSync(), 'testing');
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reports a failed profile load and offers a retry', (
    tester,
  ) async {
    final support = Directory.systemTemp.createTempSync(
      'xveil-profile-screen-',
    );
    addTearDown(() => support.deleteSync(recursive: true));
    final obstruction = File('${support.path}/profiles')
      ..writeAsStringSync('occupied');
    var available = false;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_pathProvider, (_) async {
      if (available) return support.path;
      throw PlatformException(code: 'unavailable');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_pathProvider, null));

    await _pumpScreen(tester);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text("Couldn't load this"), findsOneWidget);

    available = true;
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await _waitFor(tester, find.text("Couldn't load this"));
    });
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(obstruction.readAsStringSync(), 'occupied');

    obstruction.deleteSync();
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.refresh));
      await _waitFor(tester, find.text('Default (production)'));
    });
    expect(find.text("Couldn't load this"), findsNothing);
  });

  testWidgets(
    'creation failure keeps the selected profile and can be retried',
    (tester) async {
      final support = Directory.systemTemp.createTempSync(
        'xveil-profile-screen-',
      );
      addTearDown(() => support.deleteSync(recursive: true));
      Directory('${support.path}/profiles/known').createSync(recursive: true);
      final pointer = File('${support.path}/xveil.profile')
        ..writeAsStringSync('known');
      final obstruction = File('${support.path}/profiles/secondary')
        ..writeAsStringSync('occupied');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        _pathProvider,
        (_) async => support.path,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(_pathProvider, null),
      );

      await tester.runAsync(() async {
        await _pumpScreen(tester);
        await _waitFor(tester, find.text('known'));
      });
      await tester.pumpAndSettle();

      Future<void> openDialog() async {
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'secondary');
      }

      final confirm = find.widgetWithText(FilledButton, 'Create');
      await tester.runAsync(() async {
        await openDialog();
        await tester.tap(confirm);
        await _waitFor(tester, find.text('Could not create the profile.'));
      });
      expect(tester.takeException(), isNull);
      expect(pointer.readAsStringSync(), 'known');
      expect(obstruction.readAsStringSync(), 'occupied');

      obstruction.deleteSync();
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await openDialog();
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        await _waitFor(
          tester,
          find.descendant(
            of: find.widgetWithText(ListTile, 'secondary'),
            matching: find.byIcon(Icons.radio_button_checked),
          ),
        );
      });
      expect(Directory(obstruction.path).existsSync(), isTrue);
      expect(pointer.readAsStringSync(), 'secondary');
    },
  );
}
