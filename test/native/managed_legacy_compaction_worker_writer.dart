import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/storage_locator.dart';

// Only the parent harness supplies these private, synthetic capabilities.
Future<void> main(List<String> args) async {
  if (args.length != 2) exit(2);
  final fixture = Directory(args[0]).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!fixture.startsWith('$temporary/xveil-compaction-worker-') ||
      !['prepared', 'reply-pending'].contains(args[1])) {
    exit(3);
  }
  if (!ensureHiddenVolumeLoaded()) exit(4);
  final body =
      jsonDecode(File('$fixture/capabilities-private.json').readAsStringSync())
          as Map<String, dynamic>;
  final keys = <ManagedIdentityId, Uint8List>{
    for (final entry in (body['masters'] as Map<String, dynamic>).entries)
      ManagedIdentityId(entry.key): base64.decode(entry.value as String),
  };
  final credentials = [
    for (final entry in (body['legacy'] as Map<String, dynamic>).entries)
      (
        password: Uint8List.fromList(utf8.encode(entry.key)),
        oldSpaceKeys: base64.decode(entry.value as String),
      ),
  ];
  final approved = <ManagedIdentityId>{
    for (final id in body['plaintext'] as List<dynamic>)
      ManagedIdentityId(id as String),
  };
  void ready() {
    final marker = File('$fixture/ready.pending');
    marker.writeAsStringSync('$pid:${args[1]}', flush: true);
    marker.renameSync('$fixture/ready');
  }

  final gate = ReceivePort();
  final subscription = gate.listen((dynamic message) {
    if (message is! SendPort || args[1] != 'reply-pending') exit(5);
    // Do not acknowledge: publication and recovery have finished, but the RPC
    // result is still withheld while the worker holds its exclusive roles.
    ready();
  });
  final worker = args[1] == 'reply-pending'
      ? await ManagedLegacyCompactionWorker.openWithReplyGateForTesting(
          profileDirectory: '$fixture/visible-storage',
          authorizations: keys,
          credentials: credentials,
          plaintextApproved: approved,
          beforeReply: gate.sendPort,
        )
      : await ManagedLegacyCompactionWorker.open(
          profileDirectory: '$fixture/visible-storage',
          authorizations: keys,
          credentials: credentials,
          plaintextApproved: approved,
        );
  try {
    await worker.run(
      beforePublication: () async {
        if (args[1] == 'prepared') {
          ready();
          // Keep a real VM event source alive until the parent sends SIGKILL.
          while (true) {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }
      },
    );
    // Either returning or replying at these gates invalidates the test.
    exit(6);
  } finally {
    await worker.close();
    await subscription.cancel();
    gate.close();
    for (final key in keys.values) {
      key.fillRange(0, key.length, 0);
    }
    for (final entry in credentials) {
      entry.password.fillRange(0, entry.password.length, 0);
      entry.oldSpaceKeys.fillRange(0, entry.oldSpaceKeys.length, 0);
    }
  }
}
