@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';

class _Stop implements Exception {}

class _Fault extends ManagedFsPlatform {
  _Fault(this.point);
  final String point;
  bool enabled = true;
  bool published = false;
  @override
  bool publishFileNoReplace(String from, String to) {
    if (enabled && point == 'beforePublication') {
      throw FileSystemException('synthetic private message', from);
    }
    final result = super.publishFileNoReplace(from, to);
    published = result;
    return result;
  }

  @override
  void syncDirectory(String path) {
    if (enabled && published) {
      final completion = File('$path/${ManagedRootErasure.completionName}');
      final pending = Directory('$path/${ManagedRootErasure.pendingName}');
      final fail =
          point == 'afterPublication' ||
          point == 'afterPlan' &&
              path.endsWith('/${ManagedRootErasure.pendingName}') ||
          point == 'afterPending' &&
              completion.existsSync() &&
              !pending.existsSync() ||
          point == 'afterTerminal' &&
              !completion.existsSync() &&
              !pending.existsSync() &&
              !path.endsWith('/${ManagedRootErasure.pendingName}');
      if (fail) throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    super.syncDirectory(path);
  }
}

void main() {
  const fs = ManagedFsPlatform();
  late Directory fixture;
  late String profile;
  final live = <ManagedRootErasure>[];
  final faults = <_Fault>[];
  String directory() => '$profile/${StorageProfileCoordinator.directoryName}';
  String pending() => '${directory()}/${ManagedRootErasure.pendingName}';
  String plan() => '${pending()}/plan.json';
  String terminal() => '${directory()}/${ManagedRootErasure.completionName}';
  final failure = throwsA(isA<ManagedFsFailure>());
  Future<void> verifyNever() async =>
      fail('Terminal recovery reran the enclosing verifier');

  Future<ManagedRootErasure> prepare({
    bool remove = true,
    ManagedFsPlatform platform = fs,
    bool encrypted = false,
    bool stablePlanTime = false,
  }) async {
    final owner = ManagedDirectoryCatalog.createOrOpen(profile);
    try {
      final store = encrypted
          ? ManagedIdentityFiles.createEncrypted(
              owner,
              id: ManagedIdentityId('1' * 32),
              password: Uint8List.fromList('synthetic password'.codeUnits),
            )
          : ManagedIdentityFiles.createUnencrypted(
              owner,
              id: ManagedIdentityId('1' * 32),
            );
      try {
        store.commit([
          PutOp(1, Uint8List.fromList([1]), Uint8List.fromList([2, 3, 4])),
        ]);
      } finally {
        store.close();
      }
    } finally {
      owner.close();
    }
    final exclusive = ManagedDirectoryCatalog.openExclusiveMaintenance(
      profile,
    )!;
    try {
      await ManagedRootErasure.prepare(
        exclusive,
        unlockScopes: StorageUnlockScopes(['a' * 64]),
      );
    } finally {
      exclusive.close();
    }
    if (stablePlanTime) {
      // File.lastModifiedSync and FileStat.modified have different precision
      // on this host. Establish an exactly representable time BEFORE admission.
      File(plan()).setLastModifiedSync(DateTime.utc(2020));
      expect(
        File(plan()).statSync().modified.microsecondsSinceEpoch,
        DateTime.utc(2020).microsecondsSinceEpoch,
      );
    }
    final erasure = ManagedRootErasure.openPending(profile, fs: platform);
    live.add(erasure);
    if (remove) {
      await erasure.removeManagedFiles(
        retireScopes: (catalog) async {
          expect(catalog.identities, hasLength(1));
          expect(erasure.unlockScopes.ids, ['a' * 64]);
        },
      );
    }
    return erasure;
  }

  ManagedRootErasure reopen() {
    final result = ManagedRootErasure.openPending(profile);
    live.add(result);
    return result;
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-erasure-completion-');
    profile = '${fixture.path}/profile';
    expect(fs.createPrivateDirectory(profile), isTrue);
  });
  tearDown(() async {
    for (final fault in faults) {
      fault.enabled = false;
    }
    for (final owner in live) {
      try {
        owner.close();
      } on Object {
        await owner.finish(verifyOtherDataAbsent: () async {});
        owner.close();
      }
    }
    live.clear();
    faults.clear();
    fixture.deleteSync(recursive: true);
  });

  test(
    'finish requires absent managed root and successful enclosing verification',
    () async {
      final e = await prepare(remove: false);
      var verified = 0;
      await expectLater(
        e.finish(
          verifyOtherDataAbsent: () async {
            verified++;
          },
        ),
        failure,
      );
      expect(verified, 0);
      await e.removeManagedFiles(retireScopes: (_) async {});
      final bytes = File(plan()).readAsBytesSync();
      final extra = File('$profile/legacy-fixture')
        ..writeAsStringSync('unremoved external data');
      await expectLater(
        e.finish(
          verifyOtherDataAbsent: () async {
            throw _Stop();
          },
        ),
        throwsA(isA<_Stop>()),
      );
      expect(File(plan()).readAsBytesSync(), bytes);
      expect(File(terminal()).existsSync(), isFalse);
      expect(extra.readAsStringSync(), 'unremoved external data');
      await e.finish(
        verifyOtherDataAbsent: () async {
          extra.deleteSync();
          expect(extra.existsSync(), isFalse);
          verified++;
        },
      );
      expect(verified, 1);
      expect(e.phase, ManagedRootErasurePhase.complete);
      expect(
        Directory(
          directory(),
        ).listSync().map((f) => f.uri.pathSegments.last).toSet(),
        {'profile.meta', 'profile.meta.lock'},
      );
      // Lost final reply can be retried only by this still-held owner.
      await e.finish(verifyOtherDataAbsent: verifyNever);
      e.close();
      final fresh = ManagedDirectoryCatalog.createOrOpen(profile);
      fresh.close();
      await expectLater(
        e.finish(verifyOtherDataAbsent: verifyNever),
        throwsA(isA<ManagedLeaseFailure>()),
      );
    },
  );

  test(
    'enclosing verifier holds the lifetime gate across awaits and rejects reentry',
    () async {
      final e = await prepare();
      final entered = Completer<void>(), release = Completer<void>();
      final finishing = e.finish(
        verifyOtherDataAbsent: () async {
          entered.complete();
          await release.future;
        },
      );
      await entered.future;
      try {
        expect(e.close, throwsA(isA<ManagedLeaseFailure>()));
        expect(
          () => ManagedDirectoryCatalog.createOrOpen(profile),
          throwsA(anything),
        );
        await expectLater(
          e.finish(verifyOtherDataAbsent: verifyNever),
          throwsA(isA<ManagedLeaseFailure>()),
        );
        await expectLater(
          e.removeManagedFiles(retireScopes: (_) async {}),
          throwsA(isA<ManagedLeaseFailure>()),
        );
        expect(File(terminal()).existsSync(), isFalse);
      } finally {
        release.complete();
        await finishing;
      }
    },
  );

  for (final stage in ManagedErasureFinishStage.values) {
    test('recover after observer interruption at ${stage.name}', () async {
      final e = await prepare();
      await expectLater(
        e.finish(
          verifyOtherDataAbsent: () async {},
          afterStage: (current) async {
            if (current == stage) throw _Stop();
          },
        ),
        throwsA(isA<_Stop>()),
      );
      e.close();
      if (stage == ManagedErasureFinishStage.completionRemoved) {
        expect(ManagedDirectoryCatalog.openExisting(profile), isNull);
      } else {
        expect(() => ManagedDirectoryCatalog.createOrOpen(profile), failure);
        final recovered = reopen();
        expect(
          recovered.phase,
          stage == ManagedErasureFinishStage.beforeCompletion
              ? ManagedRootErasurePhase.removing
              : ManagedRootErasurePhase.finishing,
        );
        if (recovered.phase == ManagedRootErasurePhase.finishing) {
          expect(() => recovered.unlockScopes, failure);
          await expectLater(
            recovered.removeManagedFiles(retireScopes: (_) async {}),
            failure,
          );
        }
        await recovered.finish(
          verifyOtherDataAbsent:
              stage == ManagedErasureFinishStage.beforeCompletion
              ? () async {}
              : verifyNever,
        );
        recovered.close();
      }
      final fresh = ManagedDirectoryCatalog.createOrOpen(profile);
      expect(fresh.snapshot().catalog.identities, isEmpty);
      fresh.close();
    });
  }

  for (final point in [
    'beforePublication',
    'afterPublication',
    'afterPlan',
    'afterPending',
    'afterTerminal',
  ]) {
    test(
      'retry filesystem failure at $point without forgetting the gate or plan',
      () async {
        final platform = _Fault(point);
        faults.add(platform);
        final e = await prepare(platform: platform);
        final bytes = File(plan()).readAsBytesSync();
        await expectLater(
          e.finish(verifyOtherDataAbsent: () async {}),
          throwsA(
            isA<ManagedFsFailure>().having(
              (f) => f.toString(),
              'bounded failure',
              isNot(contains(fixture.path)),
            ),
          ),
        );
        if (point == 'beforePublication') {
          expect(File(plan()).readAsBytesSync(), bytes);
          expect(File(terminal()).existsSync(), isFalse);
          expect(
            Directory(
              directory(),
            ).listSync().where((f) => f.path.contains('.completion-')),
            isEmpty,
          );
        }
        if (point == 'afterPublication') {
          expect(File(plan()).readAsBytesSync(), bytes);
          expect(File(terminal()).existsSync(), isTrue);
        }
        if (point == 'afterTerminal') {
          expect(e.close, throwsA(isA<ManagedLeaseFailure>()));
          expect(
            () => ManagedDirectoryCatalog.createOrOpen(profile),
            throwsA(anything),
          );
        }
        platform.enabled = false;
        await e.finish(
          verifyOtherDataAbsent: point == 'beforePublication'
              ? () async {}
              : verifyNever,
        );
        e.close();
        ManagedDirectoryCatalog.createOrOpen(profile).close();
      },
    );
  }

  test(
    'late foreign entries and a changed plan are preserved before any tail unlink',
    () async {
      final e = await prepare(stablePlanTime: true);
      final bytes = File(plan()).readAsBytesSync();
      final intruder = File('${pending()}/unknown');
      await expectLater(
        e.finish(
          verifyOtherDataAbsent: () async {},
          afterStage: (stage) async {
            if (stage == ManagedErasureFinishStage.completionPublished) {
              intruder.writeAsStringSync('foreign bytes');
            }
          },
        ),
        failure,
      );
      expect(intruder.readAsStringSync(), 'foreign bytes');
      expect(File(plan()).readAsBytesSync(), bytes);
      expect(File(terminal()).existsSync(), isTrue);
      intruder
          .deleteSync(); // Only the test removes its own synthetic intrusion.
      final stamp = File(plan()).statSync().modified;
      final changed = List<int>.of(bytes)..[0] = bytes[0] ^ 1;
      File(plan()).writeAsBytesSync(changed);
      File(plan()).setLastModifiedSync(stamp);
      expect(File(plan()).statSync().modified, stamp);
      expect(File(plan()).lengthSync(), bytes.length);
      await expectLater(e.finish(verifyOtherDataAbsent: verifyNever), failure);
      expect(File(plan()).readAsBytesSync(), changed);
      File(plan()).writeAsBytesSync(bytes);
      File(plan()).setLastModifiedSync(stamp);
      await e.finish(verifyOtherDataAbsent: verifyNever);
    },
  );

  test(
    'a replacement terminal after final unlink is retained and cannot release ownership',
    () async {
      final fault = _Fault('afterTerminal');
      faults.add(fault);
      final e = await prepare(platform: fault);
      await expectLater(e.finish(verifyOtherDataAbsent: () async {}), failure);
      final foreign = File(terminal())..writeAsStringSync('foreign terminal');
      fs.restrictNewFile(foreign.path);
      fault.enabled = false;
      await expectLater(e.finish(verifyOtherDataAbsent: verifyNever), failure);
      expect(e.close, throwsA(isA<ManagedLeaseFailure>()));
      expect(foreign.readAsStringSync(), 'foreign terminal');
      foreign.deleteSync(); // Never cleaned up by the erasure actor.
      await e.finish(verifyOtherDataAbsent: verifyNever);
    },
  );

  Future<void> stopWithTerminal() async {
    final e = await prepare();
    await expectLater(
      e.finish(
        verifyOtherDataAbsent: () async {},
        afterStage: (stage) async {
          if (stage == ManagedErasureFinishStage.completionPublished) {
            throw _Stop();
          }
        },
      ),
      throwsA(isA<_Stop>()),
    );
    e.close();
  }

  for (final target in ['terminal', 'directory', 'plan', 'unknown', 'root']) {
    test(
      'foreign or replaced $target refuses terminal recovery without unlinking',
      () async {
        await stopWithTerminal();
        if (target == 'terminal') {
          final bytes = File(terminal()).readAsBytesSync();
          File(terminal()).renameSync('${terminal()}.saved');
          File(terminal()).writeAsBytesSync(bytes);
          fs.restrictNewFile(terminal());
          // Changing the binding of a syntactically valid witness also refuses.
          final raw = jsonDecode(utf8.decode(bytes)) as Map;
          raw['coordinator'] = 'foreign-object';
          File(terminal()).writeAsStringSync(jsonEncode(raw));
        }
        if (target == 'directory') {
          Directory(pending()).renameSync('${pending()}.saved');
          expect(fs.createPrivateDirectory(pending()), isTrue);
        }
        if (target == 'plan') {
          final bytes = File(plan()).readAsBytesSync();
          File(plan()).renameSync('${pending()}/saved');
          File(plan()).writeAsBytesSync(bytes);
          fs.restrictNewFile(plan());
        }
        if (target == 'unknown') {
          File('${pending()}/unknown').writeAsStringSync('foreign bytes');
        }
        if (target == 'root') {
          expect(fs.createPrivateDirectory('$profile/identities'), isTrue);
        }
        final before = {
          for (final f in Directory(
            profile,
          ).listSync(recursive: true, followLinks: false).whereType<File>())
            f.path: f.readAsBytesSync(),
        };
        expect(() => ManagedRootErasure.openPending(profile), failure);
        for (final entry in before.entries) {
          expect(File(entry.key).readAsBytesSync(), entry.value);
        }
        expect(() => ManagedDirectoryCatalog.createOrOpen(profile), failure);
      },
    );
  }

  for (final target in ['terminal', 'directory', 'plan']) {
    test(
      'linked $target refuses without reading or deleting outside data',
      () async {
        await stopWithTerminal();
        final path = target == 'terminal'
            ? terminal()
            : target == 'directory'
            ? pending()
            : plan();
        if (target == 'directory') {
          Directory(path).renameSync('$path.saved');
        } else {
          File(path).renameSync('$path.saved');
        }
        final outside = File('${fixture.path}/outside')
          ..writeAsStringSync('outside bytes');
        Link(path).createSync(outside.path);
        expect(() => ManagedRootErasure.openPending(profile), failure);
        expect(Link(path).existsSync(), isTrue);
        expect(outside.readAsStringSync(), 'outside bytes');
      },
      skip: Platform.isWindows,
    );
  }

  for (final bad in [
    'missing',
    'trailing',
    'oversize',
    'version',
    'size',
    'digest',
  ]) {
    test(
      'bounded terminal decoder rejects $bad metadata and preserves it',
      () async {
        await stopWithTerminal();
        final original = jsonDecode(File(terminal()).readAsStringSync()) as Map;
        if (bad == 'missing') original.remove('plan');
        if (bad == 'version') original['v'] = 1.0;
        if (bad == 'size') original['size'] = 8 * 1024 * 1024 + 1;
        if (bad == 'digest') original['sha256'] = 'no digest';
        final malformed = bad == 'oversize'
            ? ' ' * 4097
            : '${jsonEncode(original)}${bad == 'trailing' ? '!' : ''}';
        File(terminal()).writeAsStringSync(malformed);
        expect(() => ManagedRootErasure.openPending(profile), failure);
        expect(File(terminal()).readAsStringSync(), malformed);
        expect(File(plan()).existsSync(), isTrue);
      },
    );
  }

  test(
    'terminal has only object witnesses and a plan digest, including encrypted root',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final e = await prepare(encrypted: true);
      await e.finish(
        verifyOtherDataAbsent: () async {},
        afterStage: (stage) async {
          if (stage != ManagedErasureFinishStage.completionPublished) return;
          final text = File(terminal()).readAsStringSync();
          final raw = jsonDecode(text) as Map;
          expect(raw.keys.toSet(), {
            'v',
            'profile',
            'coordinator',
            'directory',
            'plan',
            'size',
            'modified',
            'sha256',
            'auxiliary',
          });
          expect(raw['auxiliary'], isNull);
          for (final secret in [
            'synthetic password',
            '1' * 32,
            'a' * 64,
            profile,
            'catalog',
            'unlockScopes',
          ]) {
            expect(text, isNot(contains(secret)));
          }
        },
      );
    },
  );
}
