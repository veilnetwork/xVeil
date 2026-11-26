import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import 'package:xveil/data/storage/storage_acl_approval.dart';
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
  testWidgets(
    'the profile picker explains a readable choice and accepts one-time consent',
    (tester) async {
      final support = Directory.systemTemp.createTempSync(
        'xveil-profile-acl-ui-',
      );
      addTearDown(() => support.deleteSync(recursive: true));
      final previous = storageAclApprovalsForWorker();
      addTearDown(() => restoreStorageAclApprovals(previous));
      FlutterSecureStorage.setMockInitialValues({});
      Directory('${support.path}/profiles/known').createSync(recursive: true);
      final pointer = File(activeProfilePath(support.path))
        ..writeAsStringSync('known');
      expect(Process.runSync('/bin/chmod', ['0640', pointer.path]).exitCode, 0);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        _pathProvider,
        (_) async => support.path,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(_pathProvider, null),
      );

      await tester.runAsync(() async {
        await _pumpScreen(tester, locale: const Locale('en'));
        final continueOnce = find.text('Continue once');
        await _waitFor(tester, continueOnce);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text(pointer.path), findsOneWidget);
        expect(find.textContaining('GID '), findsOneWidget);
        await tester.tap(continueOnce);
        await _waitFor(tester, find.text('known'));
      });
      expect(pointer.statSync().mode & 0x1ff, 0x1a0);
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );

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
      await tester.runAsync(() async {
        expect(await writeRememberedProfile(support.path, 'known'), isTrue);
      });
      final pointer = File('${support.path}/xveil.profile');
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
