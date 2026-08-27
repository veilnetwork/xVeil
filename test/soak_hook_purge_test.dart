import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/debug/soak_hook.dart';

/// A storage that answers every relief leg, and can be told to refuse one.
///
/// Only the four methods a purge calls; anything else hits `noSuchMethod` and
/// fails loudly rather than returning a default nobody chose.
class _PurgeableStorage implements Storage {
  _PurgeableStorage({this.refuseFiles = false, this.breakLog = false});

  /// What the multi-space view does in all-online: erasing a space goes
  /// through the single-space path, so this one refuses by contract.
  final bool refuseFiles;

  /// A leg that fails for an ordinary reason rather than a contractual one.
  final bool breakLog;

  int filesCalls = 0;
  int logCalls = 0;
  int settingsCalls = 0;

  @override
  Future<int> purgeFileStore() async {
    filesCalls++;
    if (refuseFiles) {
      throw UnsupportedError(
        'erase a space via the single-space path, not the multi-space view',
      );
    }
    return 7;
  }

  @override
  Future<int> purgeMessageLog() async {
    logCalls++;
    if (breakLog) throw StateError('the log would not open');
    return 5;
  }

  @override
  Future<int> sweepSettingsGarbage({bool wholesale = false}) async {
    settingsCalls++;
    return 3;
  }

  @override
  Future<Map<String, int>> namespaceCounts() async => {'chunks': 1};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A purge that cannot do one thing still does the rest (report17 XV17-L6).
///
/// The legs were a plain `await` chain, and the FIRST of them is not supported
/// at all in all-online: `storageProvider` hands back a multi-space view whose
/// erase throws by contract. The endpoint answered 500 and the four legs after
/// it — the message log, the resume registry, the settings sweep — never ran.
/// A soak series then wedged on IndexFull with the relief it had been told it
/// had.
void main() {
  test('a refused leg does not stop the ones after it', () async {
    final storage = _PurgeableStorage(refuseFiles: true);
    var pendingCleared = 0;

    final out = await runPurgeFiles(
      storage: storage,
      clearPendingDownloads: () async {
        pendingCleared++;
        return 2;
      },
    );

    expect(
      storage.logCalls,
      1,
      reason: 'the message log was never purged — the chain stopped',
    );
    expect(pendingCleared, 1, reason: 'the resume registry was never cleared');
    expect(storage.settingsCalls, 1, reason: 'the settings sweep never ran');
    expect(out.erasedLog, 5);
    expect(out.erasedPending, 2);
    expect(out.sweptSettings, 3);
  });

  test('and the answer says which leg could not be done', () async {
    final out = await runPurgeFiles(
      storage: _PurgeableStorage(refuseFiles: true),
      clearPendingDownloads: () async => 2,
    );

    expect(
      out.toJson()['ok'],
      isFalse,
      reason: 'a caller reading ok:true believes it got the whole relief',
    );
    expect(out.toJson()['unsupported'], contains('files'));
    expect(out.status, 200, reason: 'four legs DID run; this is not a refusal');
  });

  test('a leg that fails for another reason is reported apart', () async {
    // Unsupported is an answer about the mode; a throw is a defect. They must
    // not read the same to whoever is looking at a wedged soak.
    final out = await runPurgeFiles(
      storage: _PurgeableStorage(breakLog: true),
      clearPendingDownloads: () async => 2,
    );

    expect(out.toJson()['unsupported'], isNull);
    expect((out.toJson()['failed']! as Map).keys, contains('messageLog'));
    expect(out.erased, 7, reason: 'the legs around it still ran');
    expect(out.sweptSettings, 3);
  });

  test('nothing at all is a 409 about the mode, not a 500', () async {
    // Every leg refused: the request was fine, this mode simply cannot do it.
    final out = await runPurgeFiles(
      storage: _PurgeableStorage(refuseFiles: true),
      clearPendingDownloads: () async =>
          throw UnsupportedError('no messaging in this mode'),
    );
    // The two that answer here are the log and the settings sweep; take them
    // out of the picture to reach the all-refused case.
    out.erasedLog = null;
    out.sweptSettings = null;

    expect(out.ranSomething, isFalse);
    expect(out.status, 409);
  });

  test('CONTROL: a storage that supports everything answers ok', () async {
    // Vacuity guard: an outcome that never reports ok would satisfy the
    // assertions above while telling a healthy soak it is broken.
    final out = await runPurgeFiles(
      storage: _PurgeableStorage(),
      clearPendingDownloads: () async => 2,
    );

    expect(out.toJson()['ok'], isTrue);
    expect(out.status, 200);
    expect(out.toJson()['unsupported'], isNull);
    expect(out.toJson()['failed'], isNull);
    expect(out.erased, 7);
  });
}
