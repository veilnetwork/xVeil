import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/storage_acl_vault.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/managed_fs_contract.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import 'package:xveil/data/veil_stack.dart'
    show claimRuntimeDirUnder, RuntimeDirNotPrivate, RuntimeDirectoryRefusal;
import 'package:xveil/desktop/desktop_tray.dart'
    show initDesktopWindow, isDesktopTrayPlatform;
import 'package:xveil/features/bootstrap/profile_erasure_pending_app.dart';
import 'package:xveil/features/bootstrap/startup_failed_app.dart';
import 'package:xveil/features/settings/error_report.dart';
import 'package:xveil/main.dart' show runStartup;

/// Everything between `main()` and `runApp` runs inside the guarded zone, and
/// that zone can only LOG an uncaught error — it cannot un-skip the `runApp`
/// the throw jumped over. A failure anywhere in bootstrap therefore ended as an
/// EMPTY WINDOW: process alive, log written where nobody looks, and a user with
/// no way to tell whether their data had been touched.
void main() {
  test('forgetting durable ACL decisions preserves other secure entries', () async {
    final fingerprint = 'a' * 64;
    const unrelated = 'unrelated-entry';
    const storage = FlutterSecureStorage();
    FlutterSecureStorage.setMockInitialValues({
      'xveil.storage.acl.v1.$fingerprint': '1',
      unrelated: 'value',
    });
    expect(await forgetRememberedStorageAclApprovals(), isTrue);
    expect(await storage.readAll(), {unrelated: 'value'});
  }, skip: Platform.isWindows);

  setUp(errorJournal.clear);

  List<dynamic> startupErrors() =>
      (jsonDecode(buildErrorReport(phase: 'startup-failed')) as Map)['errors']
          as List<dynamic>;

  for (final duringOpen in [true, false]) {
    testWidgets('can retry a busy preferences file (open=$duringOpen)', (
      tester,
    ) async {
      final busy = ManagedWorkerFailure(
        ManagedWorkerFailureKind.busy,
        preferencesOpenReason: duringOpen
            ? ManagedPreferencesFailureReason.busy
            : null,
        preferencesReadReason: duringOpen
            ? null
            : ManagedPreferencesFailureReason.busy,
      );
      final retryGate = Completer<void>();
      var attempts = 0;
      Widget? presented;
      await runStartup(
        loadPreferences: () async {
          attempts++;
          if (attempts == 1) throw busy;
          if (attempts == 2) {
            await retryGate.future;
            throw busy;
          }
          return (
            profile: null,
            supportDirectory: null,
            erasurePending: true,
            legacyPreferences: null,
          );
        },
        present: (widget) => presented = widget,
      );

      await tester.pumpWidget(presented!);
      expect(find.textContaining('settings file is in use'), findsOneWidget);
      expect(find.byType(CopyErrorReportTile), findsOneWidget);
      final retry = find.widgetWithText(FilledButton, 'Try again');
      await tester.tap(retry);
      await tester.tap(retry);
      await tester.pump();
      expect(attempts, 2);
      expect(tester.widget<FilledButton>(retry).onPressed, isNull);
      retryGate.complete();
      await tester.pump();
      await tester.pumpWidget(presented!);
      expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
      await tester.tap(retry);
      await tester.pump();
      expect(attempts, 3);
      await tester.pumpWidget(presented!);
      expect(find.byType(ProfileErasurePendingApp), findsOneWidget);
      expect(find.byType(StartupFailedApp), findsNothing);
    });
  }

  for (final (failure, code) in const [
    (ProfileChoiceReadFailure(busy: false), 0),
    (ProfileChoiceReadFailure(busy: true), 1),
    (ProfileChoiceReadFailure(busy: false, fromLegacy: true), 2),
    (ProfileChoiceReadFailure(busy: true, fromLegacy: true), 3),
    (ProfileChoiceReadFailure.malformed(), 4),
  ]) {
    test('startup reports profile choice read failure code $code', () async {
      diagnosticJournal.clear();
      addTearDown(diagnosticJournal.clear);
      Widget? presented;
      await runStartup(
        loadPreferences: () async => throw failure,
        present: (widget) => presented = widget,
      );
      expect(
        (presented as StartupFailedApp).retryPreferences != null,
        failure.busy,
      );
      expect(startupErrors().single['profile_preferences'], {
        'stage': 'choice',
        'code': code,
      });
      final retained = diagnosticJournal.toJson()['last_evidence'] as Map?;
      final event = retained?['profileChoiceReadFailed'] as Map?;
      expect(
        event?['values'],
        diagnosticJournal.enabled ? {'code': code} : isNull,
      );
    });
  }

  testWidgets('a busy preference error during resumed startup stays generic', (
    tester,
  ) async {
    Widget? presented;
    await runStartup(
      boot: () async => throw const ManagedWorkerFailure(
        ManagedWorkerFailureKind.busy,
        preferencesReadReason: ManagedPreferencesFailureReason.busy,
      ),
      present: (widget) => presented = widget,
    );
    await tester.pumpWidget(presented!);
    expect(find.byType(StartupFailedApp), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  test('startup exposes only the bounded preference admission codes', () async {
    diagnosticJournal.clear();
    addTearDown(diagnosticJournal.clear);
    Widget? presented;
    await runStartup(
      loadPreferences: () async => throw const ManagedWorkerFailure(
        ManagedWorkerFailureKind.invalid,
        preferencesOpenReason: ManagedPreferencesFailureReason.filesystemUnsafe,
      ),
      present: (w) => presented = w,
    );
    expect(
      presented,
      isA<StartupFailedApp>().having(
        (w) => w.retryPreferences,
        'retry',
        isNull,
      ),
    );
    expect(startupErrors().single['profile_preferences'], {
      'stage': 'open',
      'state': ManagedWorkerFailureKind.invalid.index,
      'code': ManagedPreferencesFailureReason.filesystemUnsafe.index,
    });
    final retained = diagnosticJournal.toJson()['last_evidence'] as Map?;
    final entry = retained?['profilePreferencesOpenFailed'] as Map?;
    expect(
      entry?['values'],
      diagnosticJournal.enabled
          ? {
              'state': ManagedWorkerFailureKind.invalid.index,
              'code': ManagedPreferencesFailureReason.filesystemUnsafe.index,
            }
          : isNull,
    );
  });

  testWidgets('startup explains the unsafe ancestor and exports its category', (
    tester,
  ) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    diagnosticJournal.clear();
    addTearDown(diagnosticJournal.clear);
    Widget? presented;
    await runStartup(
      loadPreferences: () async => throw const ManagedWorkerFailure(
        ManagedWorkerFailureKind.invalid,
        preferencesOpenReason: ManagedPreferencesFailureReason.unsafeAncestor,
        ancestorRefusal: (
          depth: 2,
          cause: ManagedAncestorRefusalCause.unsafePermissions,
        ),
      ),
      present: (widget) => presented = widget,
    );
    await tester.pumpWidget(presented!);
    expect(
      find.textContaining('разрешение на изменение для другой учётной записи'),
      findsOneWidget,
    );
    expect(find.textContaining('на уровне 2'), findsOneWidget);
    expect(find.byType(CopyErrorReportTile), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(startupErrors().single['profile_preferences'], {
      'stage': 'open',
      'state': 7,
      'code': 21,
      'ancestor': {'depth': 2, 'cause': 'unsafePermissions'},
    });
    final retained = diagnosticJournal.toJson()['last_evidence'] as Map?;
    final event = retained?['profilePreferencesOpenFailed'] as Map?;
    expect(
      event?['values'],
      diagnosticJournal.enabled
          ? {'state': 7, 'code': 21, 'ancestorDepth': 2, 'ancestorCause': 2}
          : isNull,
    );
  });

  for (final remember in [false, true]) {
    testWidgets('Windows ACL approval requires a choice (remember=$remember)', (
      tester,
    ) async {
      const localPath = r'C:\fixture-private\xveil';
      const localAccount = 'fixture-local-account';
      final warning = ManagedStorageAclWarning(
        path: localPath,
        fingerprint: 'a' * 64,
        grants: const [
          (
            account: localAccount,
            rights: {ManagedAclRight.read, ManagedAclRight.delete},
          ),
        ],
      );
      final parentWarning = ManagedStorageAclWarning(
        path: r'C:\fixture-private',
        fingerprint: 'b' * 64,
        grants: const [
          (account: 'another-local-account', rights: {ManagedAclRight.write}),
        ],
      );
      final choices = <(ManagedStorageAclWarning, bool)>[];
      var attempts = 0;
      Widget? presented;
      await runStartup(
        loadPreferences: () async {
          attempts++;
          if (choices.isEmpty) {
            throw ManagedWorkerFailure(
              ManagedWorkerFailureKind.invalid,
              preferencesOpenReason:
                  ManagedPreferencesFailureReason.unsafeAncestor,
              aclWarnings: [warning, parentWarning],
            );
          }
          return (
            profile: null,
            supportDirectory: null,
            erasurePending: true,
            legacyPreferences: null,
          );
        },
        restoreAclApproval: (_) async => false,
        recordAclApproval: (candidate, {required remember}) {
          choices.add((candidate, remember));
          return true;
        },
        present: (widget) => presented = widget,
      );
      await tester.pumpWidget(presented!);
      expect(find.text('Review access permissions'), findsOneWidget);
      expect(find.text(localPath), findsOneWidget);
      expect(find.text(parentWarning.path), findsOneWidget);
      expect(find.textContaining('another-local-account'), findsOneWidget);
      expect(find.textContaining(localAccount), findsOneWidget);
      expect(find.text('Do not start'), findsOneWidget);
      expect(choices, isEmpty);
      expect(attempts, 1);
      final report = buildErrorReport(phase: 'startup-failed');
      expect(report, isNot(contains('fixture-private')));
      expect(report, isNot(contains(localAccount)));

      expect(find.textContaining('PowerShell'), findsNothing);
      expect(find.textContaining('delete or rename'), findsWidgets);

      final action = find.text(
        remember ? 'Start and remember my choice' : 'Start once',
      );
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pump();
      expect(choices, [(warning, remember), (parentWarning, remember)]);
      expect(attempts, 2);
      await tester.pumpWidget(presented!);
      expect(find.byType(ProfileErasurePendingApp), findsOneWidget);
    });
  }

  testWidgets('storage consent works after preferences have loaded', (
    tester,
  ) async {
    final warning = ManagedStorageAclWarning(
      path: '/fixture/visible-storage',
      fingerprint: 'b' * 64,
      grants: const [
        (account: 'collaborators', rights: {ManagedAclRight.write}),
      ],
    );
    final opened = Container();
    var choice = false;
    Widget? presented;
    await runStartup(
      boot: () async {
        if (!choice) {
          throw ManagedFsFailure(
            ManagedFsFailureKind.unsafe,
            aclWarnings: [warning],
          );
        }
        presented = opened;
      },
      restoreAclApproval: (_) async => false,
      recordAclApproval: (candidate, {required remember}) {
        expect(candidate, warning);
        expect(remember, isTrue);
        choice = true;
        return true;
      },
      present: (widget) => presented = widget,
    );

    await tester.pumpWidget(presented!);
    expect(find.text(warning.path), findsOneWidget);
    await tester.tap(find.text('Start and remember my choice'));
    await tester.pumpAndSettle();
    expect(presented, same(opened));
  });

  testWidgets('runtime failure offers local access without retrying the node', (
    tester,
  ) async {
    const folder = r'C:ixture-runtime';
    final opened = Container();
    var networkAttempts = 0;
    Widget? presented;
    await runStartup(
      bootWithRuntimeBase: (_) async {
        networkAttempts++;
        throw RuntimeDirNotPrivate(
          folder,
          'unsafe Windows directory permissions',
          retryable: true,
          refusal: RuntimeDirectoryRefusal.unsafeAncestor,
        );
      },
      bootOffline: () async => presented = opened,
      present: (widget) => presented = widget,
    );

    await tester.pumpWidget(presented!);
    final button = find.text('Open without network');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(presented, same(opened));
    expect(networkAttempts, 1);
  });

  testWidgets(
    'a POSIX runtime with denied write access offers recovery',
    (tester) async {
      final folder = Directory.systemTemp.createTempSync(
        'xveil-runtime-no-write-',
      );
      expect(Process.runSync('/bin/chmod', ['0500', folder.path]).exitCode, 0);
      addTearDown(() {
        Process.runSync('/bin/chmod', ['0700', folder.path]);
        folder.deleteSync(recursive: true);
      });
      Widget? presented;
      await tester.runAsync(
        () => runStartup(
          bootWithRuntimeBase: (_) async {
            await claimRuntimeDirUnder(folder.path, uniqueSuffix: 'denied');
          },
          bootOffline: () async {},
          present: (widget) => presented = widget,
        ),
      );
      final screen = presented! as StartupFailedApp;
      expect(
        screen.runtimeFailure!.refusal,
        RuntimeDirectoryRefusal.cannotWrite,
      );
      expect(screen.retryWithRuntimeBase, isNotNull);
      expect(screen.openOffline, isNotNull);
      await tester.pumpWidget(screen);
      expect(
        find.textContaining('Check your account’s write access'),
        findsOneWidget,
      );
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );

  testWidgets('bootstrap leaves the native close button enabled', (
    tester,
  ) async {
    const channel = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await initDesktopWindow();
    expect(calls, isDesktopTrayPlatform ? ['ensureInitialized'] : isEmpty);
  });

  testWidgets('a runtime refusal explains the affected folder locally', (
    tester,
  ) async {
    const folder = r'C:\fixture-runtime';
    const account = 'runtime-fixture-account';
    final warning = ManagedStorageAclWarning(
      path: folder,
      fingerprint: 'f' * 64,
      grants: const [
        (account: account, rights: {ManagedAclRight.deleteChildren}),
      ],
    );
    const otherFolder = r'C:\other-runtime';
    Widget? presented;
    var boots = 0;
    final recheck = Completer<void>();
    final first = RuntimeDirNotPrivate(
      otherFolder,
      'Windows directory write failed',
      refusal: RuntimeDirectoryRefusal.cannotWrite,
    );
    final last = RuntimeDirNotPrivate(
      folder,
      'unsafe Windows directory permissions',
      aclWarning: warning,
      refusal: RuntimeDirectoryRefusal.unsafeAncestor,
    );
    await runStartup(
      boot: () async {
        if (++boots > 1) await recheck.future;
        throw RuntimeDirNotPrivate(
          folder,
          last.reason,
          retryable: true,
          windowsAttempts: [(0, first), (2, last)],
        );
      },
      present: (widget) => presented = widget,
    );
    await tester.pumpWidget(presented!);
    expect(find.textContaining('files that control'), findsOneWidget);
    expect(find.text(folder), findsOneWidget);
    expect(find.text(otherFolder), findsOneWidget);
    expect(find.textContaining(account), findsOneWidget);
    expect(find.textContaining('Check your account'), findsOneWidget);
    expect(find.text('Start once'), findsNothing);
    expect(find.byType(CopyErrorReportTile), findsOneWidget);
    await tester.ensureVisible(find.text('Try again'));
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(find.textContaining('Checking access'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Try again'))
          .onPressed,
      isNull,
    );
    recheck.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Check complete'), findsOneWidget);
    expect(boots, 2);

    final report = buildErrorReport(phase: 'startup-failed');
    expect(report, contains('RuntimeDirNotPrivate'));
    expect(report, isNot(contains(folder)));
    expect(report, isNot(contains(otherFolder)));
    expect(report, isNot(contains(account)));
  });

  testWidgets('the folder chooser retries the same boot with the chosen base', (
    tester,
  ) async {
    const selected = r'D:\private folder';
    final bases = <String?>[];
    Widget? presented;
    await runStartup(
      bootWithRuntimeBase: (base) async {
        bases.add(base);
        if (base == null) {
          throw RuntimeDirNotPrivate(
            r'C:\unavailable',
            'unsafe Windows directory permissions',
            retryable: true,
          );
        }
        presented = const ProfileErasurePendingApp();
      },
      present: (widget) => presented = widget,
    );
    final refusal = presented! as StartupFailedApp;
    var choice = 0;
    await tester.pumpWidget(
      StartupFailedApp(
        runtimeFailure: refusal.runtimeFailure,
        retryWithRuntimeBase: refusal.retryWithRuntimeBase,
        pickRuntimeDirectory: () async => ++choice == 1 ? null : selected,
      ),
    );
    final choose = find.text('Choose a different folder');
    await tester.ensureVisible(choose);
    await tester.tap(choose);
    await tester.pumpAndSettle();
    expect(bases, [null]);
    await tester.tap(choose);
    await tester.pumpAndSettle();
    expect(bases, [null, selected]);
    await tester.pumpWidget(presented!);
    expect(find.byType(ProfileErasurePendingApp), findsOneWidget);
  });

  testWidgets('an OS access refusal shows what to check', (tester) async {
    Widget? presented;
    await runStartup(
      loadPreferences: () async => throw const ManagedWorkerFailure(
        ManagedWorkerFailureKind.invalid,
        preferencesOpenReason:
            ManagedPreferencesFailureReason.windowsPathAccessDenied,
      ),
      present: (widget) => presented = widget,
    );

    await tester.pumpWidget(presented!);
    expect(
      find.textContaining('Check whether your account has access'),
      findsOneWidget,
    );
    expect(find.text('Start once'), findsNothing);
    expect(find.byType(CopyErrorReportTile), findsOneWidget);
  });

  test('startup retains the distinct preference read refusal', () async {
    diagnosticJournal.clear();
    addTearDown(diagnosticJournal.clear);
    Widget? presented;
    await runStartup(
      loadPreferences: () async => throw const ManagedWorkerFailure(
        ManagedWorkerFailureKind.invalid,
        preferencesReadReason: ManagedPreferencesFailureReason.filePermissions,
      ),
      present: (widget) => presented = widget,
    );
    expect(
      presented,
      isA<StartupFailedApp>().having(
        (w) => w.retryPreferences,
        'retry',
        isNull,
      ),
    );
    expect(startupErrors().single['profile_preferences'], {
      'stage': 'read',
      'state': ManagedWorkerFailureKind.invalid.index,
      'code': ManagedPreferencesFailureReason.filePermissions.index,
    });
    final retained = diagnosticJournal.toJson()['last_evidence'] as Map?;
    expect(retained?['profilePreferencesOpenFailed'], isNull);
    final event = retained?['profilePreferencesReadFailed'] as Map?;
    expect(
      event?['values'],
      diagnosticJournal.enabled
          ? {
              'state': ManagedWorkerFailureKind.invalid.index,
              'code': ManagedPreferencesFailureReason.filePermissions.index,
            }
          : isNull,
    );
  });

  testWidgets(
    'invalid preference format preserves a specific startup failure',
    (tester) async {
      diagnosticJournal.clear();
      addTearDown(diagnosticJournal.clear);
      Widget? presented;
      const reason = ProfilePreferencesFormatReason.unsupportedVersion;
      await runStartup(
        loadPreferences: () async =>
            throw const ProfilePreferencesFormatFailure(reason),
        present: (widget) => presented = widget,
      );
      await tester.pumpWidget(presented!);
      expect(find.textContaining('unsupported format'), findsOneWidget);
      expect(startupErrors().single['profile_preferences'], {
        'stage': 'format',
        'code': reason.index,
      });
      final retained = diagnosticJournal.toJson()['last_evidence'] as Map?;
      final event = retained?['profilePreferencesFormatFailed'] as Map?;
      expect(
        event?['values'],
        diagnosticJournal.enabled ? {'code': reason.index} : isNull,
      );
    },
  );

  test(
    'different preference failures with the same worker kind survive retries',
    () async {
      for (final reason in [
        ManagedPreferencesFailureReason.filesystemUnsafe,
        ManagedPreferencesFailureReason.fileOwner,
        ManagedPreferencesFailureReason.filesystemUnsafe,
      ]) {
        await runStartup(
          present: (_) {},
          loadPreferences: () async => throw ManagedWorkerFailure(
            ManagedWorkerFailureKind.invalid,
            preferencesOpenReason: reason,
          ),
        );
      }
      final errors = startupErrors();
      expect(errors, hasLength(2));
      expect(
        errors.first['profile_preferences']['code'],
        ManagedPreferencesFailureReason.fileOwner.index,
      );
      expect(
        errors.last['profile_preferences']['code'],
        ManagedPreferencesFailureReason.filesystemUnsafe.index,
      );
      expect(errors.last['count'], 2);
    },
  );

  testWidgets('a startup that throws still puts something on screen', (
    tester,
  ) async {
    Widget? presented;
    await runStartup(
      boot: () async =>
          throw StateError('the container path would not resolve'),
      present: (w) => presented = w,
    );

    expect(
      presented,
      isNotNull,
      reason: 'the throw skipped runApp and left an empty window',
    );
    // ...and it must actually PAINT. A widget that cannot build is the blank
    // window by another name, so it is pumped rather than merely type-checked.
    await tester.pumpWidget(presented!);
    expect(find.byType(StartupFailedApp), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    // Localized text, not a placeholder: the fallback is the only thing the
    // user will read, so it has to be readable.
    expect(find.textContaining('xVeil'), findsWidgets);
    expect(startupErrors().single, isNot(contains('profile_preferences')));
    expect(startupErrors().single, isNot(contains('message')));
  });

  testWidgets('CONTROL: a startup that succeeds is left alone — no second app '
      'is presented over it', (tester) async {
    var booted = 0;
    Widget? presented;
    await runStartup(boot: () async => booted++, present: (w) => presented = w);
    expect(booted, 1);
    expect(
      presented,
      isNull,
      reason: 'the fallback ran over a startup that had already succeeded',
    );
  });

  testWidgets(
    'an asynchronous failure counts too, not only a synchronous one',
    (tester) async {
      Widget? presented;
      await runStartup(
        boot: () async {
          // A suspension, not a timer: `testWidgets` runs on a fake clock that
          // only advances when pumped, so a real delay here would hang.
          await null;
          throw 'a plugin channel answered nothing';
        },
        present: (w) => presented = w,
      );
      expect(presented, isA<StartupFailedApp>());
    },
  );
}
