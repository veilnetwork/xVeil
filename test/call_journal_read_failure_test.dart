import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/call_log_sync.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/messaging.dart';

// Refuse only the namespace read. All real container operations, including
// commits, publication markers and reopen, still go through the backing store.
class _JournalReadFault implements AsyncKvLogStore {
  _JournalReadFault(this.inner);
  final AsyncKvLogStore inner;
  bool refuse = false;
  int reads = 0;

  @override
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) {
    if (namespace == Ns.callLog) {
      reads++;
      if (refuse) throw StateError('PRIVATE_CALL_JOURNAL_PATH');
    }
    return inner.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    );
  }

  @override
  Future<int> commit(List<KvLogOp> ops) => inner.commit(ops);
  @override
  Future<Uint8List?> get(int namespace, Uint8List key) =>
      inner.get(namespace, key);
  @override
  Future<Uint8List?> readLog(int namespace, int logId) =>
      inner.readLog(namespace, logId);
  @override
  Future<int> count(int namespace) => inner.count(namespace);
  @override
  Future<List<Uint8List>> kvKeys(int namespace) => inner.kvKeys(namespace);
  @override
  Future<int> eraseNamespace(int namespace) => inner.eraseNamespace(namespace);
  @override
  Future<void> scrub() => inner.scrub();
  @override
  Future<Uint8List> exportKeys() => inner.exportKeys();
  @override
  Future<SlotUtilization?> slotUtilization() => inner.slotUtilization();
  @override
  Future<String?> hardeningWarning() => inner.hardeningWarning();
  @override
  Future<void> acknowledgeHardeningWarning() =>
      inner.acknowledgeHardeningWarning();
  @override
  Future<void> close() => inner.close();
}

final _peer = NodeId(Uint8List(32)..fillRange(0, 32, 2));
CallLogEntry _entry(String id, int time) => CallLogEntry(
  id: id,
  peerHex: _peer.hex,
  outgoing: false,
  video: false,
  outcome: CallLogOutcome.missed,
  atMs: time,
);

void main() {
  for (final native in [false, true]) {
    group(
      'call namespace read failure native=$native',
      () {
        late HiddenVolumeStorage storage;
        late _JournalReadFault fault;
        late AsyncSpaceOpener open;
        Directory? dir;
        setUp(() async {
          diagnosticJournal.clear();
          if (native) {
            expect(
              ensureHiddenVolumeLoaded(
                dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
              ),
              true,
            );
            dir = await Directory.systemTemp.createTemp(
              'xveil-call-read-fault-',
            );
            final path = '${dir!.path}/store.hv';
            HvKvLogStore(
              hv.HvSpace.create(
                path: path,
                password: Uint8List.fromList(utf8.encode('fixture')),
                argon: hv.ArgonPreset.min,
              ),
            ).close();
            open = workerSpaceOpener(path);
          } else {
            final raw = FakeKvLogStore();
            open = ({required password, required bool create}) async =>
                SyncWrappedAsyncKvLogStore(raw);
          }
          storage = HiddenVolumeStorage.async(({
            required password,
            required bool create,
          }) async {
            final backing = await open(password: password, create: create);
            if (backing == null) return null;
            return fault = _JournalReadFault(backing);
          });
          expect(
            await storage.open(password: 'fixture', createIfMissing: true),
            true,
          );
          await storage.appendCallLogEntry(_entry('retained', 1000), cap: 200);
        });
        tearDown(() async {
          await storage.close();
          await dir?.delete(recursive: true);
          dir = null;
        });

        test('read failure is not an empty journal', () async {
          fault.refuse = true;
          await expectLater(storage.callLogEntries(), throwsStateError);
          fault.refuse = false;
          expect((await storage.callLogEntries()).map((r) => r.id), [
            'retained',
          ]);
        });

        test(
          'read failure cannot admit a blind append or sync intent',
          () async {
            fault.refuse = true;
            await expectLater(
              storage.appendCallLogEntry(
                _entry('new', 2000),
                cap: 200,
                queueForSync: true,
              ),
              throwsStateError,
            );
            expect(await storage.pendingCallLogSync(), isEmpty);
            expect(await storage.namespaceCounts(), containsPair('callLog', 1));
            fault.refuse = false;
            expect((await storage.callLogEntries()).map((r) => r.id), [
              'retained',
            ]);
            expect(
              await storage.appendCallLogEntry(
                _entry('new', 2000),
                cap: 200,
                queueForSync: true,
              ),
              true,
            );
            expect((await storage.callLogEntries()).map((r) => r.id), [
              'new',
              'retained',
            ]);
            expect((await storage.pendingCallLogSync()).single.entry.id, 'new');
          },
        );

        test(
          'legacy seed retries after a refused read, including cold reopen',
          () async {
            final journal = ErrorJournal();
            final posts = <CallLogEntry>[];
            CallLogPublisher publisher() => CallLogPublisher(
              storage: storage,
              isLinked: () async => true,
              loadPublished: () async => posts.toList(),
              post: (row) async {
                posts.add(row);
                return true;
              },
              reconcile: (_) async {},
              journal: journal,
            );
            var worker = publisher();
            fault.refuse = true;
            final flushed = await worker.flush();
            expect(
              await storage.getSetting('call.sync.migrated.v1'),
              isNull,
              reason:
                  'an unread namespace must not finish the one-time migration',
            );
            expect(flushed, false);
            expect(posts, isEmpty);
            expect(
              journal.toJson(
                platform: 'fixture',
                osVersion: 'fixture',
                appVersion: 'fixture',
                phase: 'fixture',
              ),
              isNot(contains('PRIVATE_CALL_JOURNAL_PATH')),
            );
            await worker.close();
            await storage.close();
            expect(await storage.open(password: 'fixture'), true);
            worker = publisher();
            try {
              expect(await worker.flush(), true);
              expect(posts.map((r) => r.id), ['retained']);
              expect(await storage.getSetting('call.sync.migrated.v1'), '1');
              expect(await storage.pendingCallLogSync(), isEmpty);
              expect(await worker.flush(), true);
              expect(posts, hasLength(1));
              expect((await storage.callLogEntries()).single.id, 'retained');
            } finally {
              await worker.close();
            }
          },
        );

        test(
          'actual storage failure reaches restore diagnostics; fresh calls remain usable',
          () async {
            await storage.upsertContact(
              Contact(nodeId: _peer, status: ContactStatus.accepted),
            );
            final transport = LoopbackTransport();
            final messaging = MessagingService(transport, storage);
            fault.refuse = true;
            final calls = CallService(
              messaging,
              loadFinishedCalls: storage.callLogEntries,
            )..start();
            try {
              await pumpEventQueue();
              expect(fault.reads, greaterThan(0));
              expect(messaging.onCallSignal, isNotNull);
              if (kDiagnosticReportEnabled) {
                final evidence =
                    (diagnosticJournal.toJson()['last_evidence']
                            as Map)['callHistoryRestore']
                        as Map;
                expect(evidence['values'], {'success': 0, 'sources': 0});
              }
              messaging.onCallSignal!(
                _peer,
                const CallSignal(callId: 'fresh', type: CallSignalType.offer),
              );
              expect(calls.current?.status, CallStatus.ringing);
              expect(
                jsonEncode(diagnosticJournal.toJson()),
                isNot(contains('PRIVATE_CALL_JOURNAL_PATH')),
              );
            } finally {
              calls.dispose();
              await messaging.dispose();
              await transport.dispose();
            }
          },
        );

        test(
          'one malformed row does not hide readable retained calls',
          () async {
            await fault.inner.commit([
              AppendLogOp(
                Ns.callLog,
                99999,
                Uint8List.fromList(utf8.encode('{bad')),
              ),
            ]);
            expect((await storage.callLogEntries()).map((r) => r.id), [
              'retained',
            ]);
          },
        );
      },
      skip: native && (Platform.environment['XVEIL_HV_DYLIB'] ?? '').isEmpty
          ? 'set XVEIL_HV_DYLIB to the qualified native library'
          : false,
    );
  }
}
