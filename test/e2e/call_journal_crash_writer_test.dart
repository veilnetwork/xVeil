@Timeout(Duration(minutes: 8))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/state/call_log.dart';

void main() {
  final dir = Platform.environment['XVEIL_CALL_CRASH_DIR'];
  test('owned container writer waits for a post-commit kill', () async {
    final resolved = await Directory(dir!).resolveSymbolicLinks();
    final temporary = await Directory.systemTemp.resolveSymbolicLinks();
    expect(resolved.startsWith('$temporary/xveil-process-'), true);
    expect(ensureHiddenVolumeLoaded(), true);
    final entry = CallLogEntry.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(Platform.environment['XVEIL_CALL_CRASH_ENTRY']!) as Map,
      ),
    )!;
    final storage = HiddenVolumeStorage(hvSpaceOpener('$resolved/store.hv'));
    expect(await storage.open(password: 'e2e-A-password'), true);
    // Deliberately no bridge/publisher: the parent kills this process after
    // the atomic store acknowledgement, before any publication can run.
    expect(await CallLogStore(storage).add(entry), true);
    await File(
      '$resolved/call-write-committed',
    ).writeAsString('committed', flush: true);
    await Completer<void>().future;
  }, skip: dir == null);
}
