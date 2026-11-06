import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'support/stand_storage_timeline.dart';
import 'support/storage_timeline_analysis.dart';

Map<String, dynamic> event(
  String name,
  String phase,
  int time, {
  Object? id,
  int tid = 1,
  Map<String, Object?> args = const {},
}) => {
  'name': name,
  'ph': phase,
  'ts': time,
  'tid': tid,
  'id': id,
  'args': args,
};
List<Map<String, dynamic>> trace({int sequence = 1, String op = 'kv.get'}) => [
  {
    'schema': 'xveil-private-storage-timeline/1',
    'kind': 'open',
    'originUs': 0,
    'workers': ['worker-private'],
  },
  {
    'kind': 'chunk',
    'fromUs': 0,
    'toUs': 100,
    'events': [
      event(
        'stand.storage.rpc',
        'b',
        10,
        id: 'rpc-private',
        args: {'sequence': sequence, 'operation': op},
      ),
      event(
        'HandleMessage',
        'B',
        20,
        tid: 2,
        args: {'isolateId': 'worker-private'},
      ),
      event(
        'HandleMessage',
        'E',
        60,
        tid: 2,
        args: {'isolateId': 'worker-private'},
      ),
      event(
        'stand.storage.rpc',
        'e',
        80,
        id: 'rpc-private',
        args: {'ok': true},
      ),
    ],
  },
  {'kind': 'close', 'capped': false},
];
void main() {
  test(
    'exclusive commit classes retain timing without trusting arbitrary labels',
    () {
      final data = trace(op: 'kv.commit');
      final events = data[1]['events'] as List;
      (events.first['args'] as Map)['commit_class'] = 'groupPair';
      var result = analyzeStorageTimeline(data);
      final classes = result['commitClasses'] as Map;
      expect(classes['groupPair'], (result['operations'] as Map)['kv.commit']);
      (events.first['args'] as Map)['commit_class'] = 'PRIVATE_CLASS_OR_PATH';
      result = analyzeStorageTimeline(data);
      expect((result['commitClasses'] as Map).keys, ['unclassified']);
      expect(jsonEncode(result), isNot(contains('PRIVATE')));
    },
  );

  test('equal VM timestamps retain recorded per-thread order', () async {
    // Sanitized event shape from a synthetic 36-RPC run: all IDs/thread names
    // replaced and timestamps relative. No paths, payloads or VM correlators.
    final raw =
        jsonDecode(
              await File(
                'test/fixtures/storage_worker_equal_timestamps.json',
              ).readAsString(),
            )
            as List;
    final records = raw
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    expect(analyzeStorageTimeline(records)['rpcCount'], 36);
  });

  test(
    'closed FIFO window decomposes RPC without leaking raw VM correlators',
    () {
      final result = analyzeStorageTimeline(trace());
      final get = (result['operations'] as Map)['kv.get'] as Map;
      expect(get, {
        'count': 1,
        'awaitUs': 70,
        'beforeHandlerUs': 10,
        'handlerUs': 40,
        'signedReplyTailUs': 20,
        'negativeReplyTails': 0,
      });
      final encoded = jsonEncode(result);
      expect(encoded, isNot(contains('private')));
      expect(result['rpcCount'], 1);
    },
  );
  test(
    'empty, capped, multi-worker, failed and missing spans cannot qualify',
    () {
      final empty = trace();
      (empty[1]['events'] as List).clear();
      final capped = trace();
      capped.last['capped'] = true;
      final multi = trace();
      multi.first['workers'] = ['w1', 'w2'];
      final failed = trace();
      ((failed[1]['events'] as List).last['args'] as Map)['ok'] = false;
      final missing = trace();
      (missing[1]['events'] as List).removeAt(1);
      for (final data in [empty, capped, multi, failed, missing]) {
        expect(() => analyzeStorageTimeline(data), throwsStateError);
      }
    },
  );
  test(
    'unknown operation labels, FIFO violations and capture gaps refuse attribution',
    () {
      final unknown = trace(op: 'raw-sensitive-value');
      final fifo = trace();
      (fifo[1]['events'] as List)[1]['ts'] = 5;
      final gap = trace();
      gap[1]['fromUs'] = 1;
      for (final data in [unknown, fifo, gap]) {
        expect(() => analyzeStorageTimeline(data), throwsStateError);
      }
    },
  );
  test(
    'capture deduplicates overlapping boundaries but preserves sequence gaps',
    () {
      final data = trace();
      data[1]['toUs'] = 80;
      data.insert(2, {
        'kind': 'chunk',
        'fromUs': 80,
        'toUs': 100,
        'events': [(data[1]['events'] as List).last],
      });
      expect(analyzeStorageTimeline(data)['rpcCount'], 1);
      final gap = trace();
      final events = gap[1]['events'] as List;
      events.addAll(<Map<String, dynamic>>[
        event(
          'stand.storage.rpc',
          'b',
          82,
          id: 'next',
          args: {'sequence': 3, 'operation': 'kv.get'},
        ),
        event(
          'HandleMessage',
          'B',
          85,
          tid: 2,
          args: {'isolateId': 'worker-private'},
        ),
        event(
          'HandleMessage',
          'E',
          90,
          tid: 2,
          args: {'isolateId': 'worker-private'},
        ),
        event('stand.storage.rpc', 'e', 95, id: 'next', args: {'ok': true}),
      ]);
      expect(() => analyzeStorageTimeline(gap), throwsStateError);
    },
  );
  test(
    'same-microsecond RPC starts use enqueue sequence, not completion order',
    () {
      final data = trace();
      data[1]['events'] = [
        event(
          'stand.storage.rpc',
          'b',
          10,
          id: 'one',
          args: {'sequence': 1, 'operation': 'kv.get'},
        ),
        event(
          'stand.storage.rpc',
          'b',
          10,
          id: 'two',
          args: {'sequence': 2, 'operation': 'kv.get'},
        ),
        event(
          'HandleMessage',
          'B',
          20,
          tid: 2,
          args: {'isolateId': 'worker-private'},
        ),
        event(
          'HandleMessage',
          'E',
          30,
          tid: 2,
          args: {'isolateId': 'worker-private'},
        ),
        event(
          'HandleMessage',
          'B',
          31,
          tid: 2,
          args: {'isolateId': 'worker-private'},
        ),
        event(
          'HandleMessage',
          'E',
          35,
          tid: 2,
          args: {'isolateId': 'worker-private'},
        ),
        event('stand.storage.rpc', 'e', 40, id: 'two', args: {'ok': true}),
        event('stand.storage.rpc', 'e', 45, id: 'one', args: {'ok': true}),
      ];
      expect(analyzeStorageTimeline(data)['rpcCount'], 2);
    },
  );

  test('reply may be observed before worker HandleMessage teardown ends', () {
    final data = trace();
    (data[1]['events'] as List)[2]['ts'] = 85;
    final get =
        (analyzeStorageTimeline(data)['operations'] as Map)['kv.get'] as Map;
    expect(get['signedReplyTailUs'], -5);
    expect(get['negativeReplyTails'], 1);
  });
  test(
    'collector preserves VM flags, captures a window and closes once',
    () async {
      final dir = await Directory.systemTemp.createTemp('xv-timeline-test-');
      addTearDown(() => dir.delete(recursive: true));
      final flags = <String>[];
      var closes = 0, now = 100;
      Future<Map<String, dynamic>> rpc(
        String name, [
        Map<String, String> args = const {},
      ]) async {
        switch (name) {
          case 'getVMTimelineFlags':
            return {
              'recordedStreams': ['GC'],
            };
          case 'setVMTimelineFlags':
            flags.add(args['recordedStreams']!);
            return {};
          case 'getVM':
            return {
              'isolates': [
                {'name': '_workerEntry', 'id': 'private-worker'},
              ],
            };
          case 'getVMTimelineMicros':
            return {'timestamp': now += 10};
          case 'getVMTimeline':
            return {
              'traceEvents': [
                event(
                  'stand.storage.rpc',
                  'b',
                  112,
                  id: 'known',
                  args: {
                    'operation': 'kv.commit',
                    'sequence': 1,
                    'commit_class': 'messageAllocator',
                    'secret': 'PRIVATE',
                  },
                ),
                event(
                  'stand.storage.rpc',
                  'b',
                  113,
                  id: 'unknown',
                  args: {
                    'operation': 'kv.commit',
                    'sequence': 2,
                    'commit_class': 'PRIVATE_CLASS',
                  },
                ),
              ],
            };
          default:
            throw StateError(name);
        }
      }

      final file = File('${dir.path}/timeline.jsonl');
      final collector = await StandStorageTimeline.withClient(
        file,
        rpc,
        () => closes++,
      );
      await collector.capture();
      await collector.close();
      await collector.close();
      expect(flags, ['[GC,Dart,Isolate]', '[GC]']);
      expect(closes, 1);
      final records = (await file.readAsLines()).map(jsonDecode).toList();
      expect(records.first['kind'], 'open');
      expect(records.last['capped'], false);
      expect(records.where((r) => r['kind'] == 'chunk'), hasLength(2));
      final events = [
        for (final r in records.where((r) => r['kind'] == 'chunk'))
          ...r['events'] as List,
      ];
      expect(events, hasLength(2));
      expect(events.first['args']['commit_class'], 'messageAllocator');
      expect((events.last['args'] as Map).containsKey('commit_class'), false);
      expect(jsonEncode(records), isNot(contains('PRIVATE')));
    },
  );
  test(
    'capture event budget fails qualification and restores VM flags',
    () async {
      final dir = await Directory.systemTemp.createTemp('xv-timeline-cap-');
      addTearDown(() => dir.delete(recursive: true));
      final flags = <String>[];
      var closes = 0, now = 0;
      Future<Map<String, dynamic>> rpc(
        String name, [
        Map<String, String> args = const {},
      ]) async {
        switch (name) {
          case 'getVMTimelineFlags':
            return {
              'recordedStreams': ['GC'],
            };
          case 'setVMTimelineFlags':
            flags.add(args['recordedStreams']!);
            return {};
          case 'getVM':
            return {
              'isolates': [
                {'name': '_workerEntry', 'id': 'worker'},
              ],
            };
          case 'getVMTimelineMicros':
            return {'timestamp': ++now};
          case 'getVMTimeline':
            return {
              'traceEvents': [
                for (var i = 0; i < 3; i++)
                  event(
                    'stand.storage.rpc',
                    'b',
                    2,
                    id: 'rpc-$i',
                    args: {'operation': 'kv.get', 'sequence': i},
                  ),
              ],
            };
          default:
            throw StateError(name);
        }
      }

      final file = File('${dir.path}/trace');
      final collector = await StandStorageTimeline.withClient(
        file,
        rpc,
        () => closes++,
        eventLimit: 2,
      );
      await collector.capture();
      await collector.close();
      final records = (await file.readAsLines())
          .map((s) => Map<String, dynamic>.from(jsonDecode(s) as Map))
          .toList();
      expect(records.last['capped'], true);
      expect(records.last['events'], 0);
      expect(() => analyzeStorageTimeline(records), throwsStateError);
      expect(flags.last, '[GC]');
      expect(closes, 1);
    },
  );

  test(
    'late-published worker durations retain their earlier begin event',
    () async {
      final dir = await Directory.systemTemp.createTemp('xv-timeline-late-');
      addTearDown(() => dir.delete(recursive: true));
      var now = 0;
      Future<Map<String, dynamic>> rpc(
        String name, [
        Map<String, String> args = const {},
      ]) async {
        switch (name) {
          case 'getVMTimelineFlags':
            return {'recordedStreams': <String>[]};
          case 'setVMTimelineFlags':
            return {};
          case 'getVM':
            return {
              'isolates': [
                {'name': '_workerEntry', 'id': 'worker-private'},
              ],
            };
          case 'getVMTimelineMicros':
            return {'timestamp': now += 10};
          case 'getVMTimeline':
            final from = int.parse(args['timeOriginMicros']!);
            final events = [
              event(
                'stand.storage.rpc',
                'b',
                12,
                id: 'one',
                args: {'sequence': 1, 'operation': 'kv.get'},
              ),
              if (now >= 30) ...[
                event(
                  'HandleMessage',
                  'B',
                  15,
                  tid: 2,
                  args: {'isolateId': 'worker-private'},
                ),
                event(
                  'HandleMessage',
                  'E',
                  25,
                  tid: 2,
                  args: {'isolateId': 'worker-private'},
                ),
                event(
                  'stand.storage.rpc',
                  'e',
                  26,
                  id: 'one',
                  args: {'ok': true},
                ),
              ],
            ].where((e) => (e['ts'] as int) >= from).toList();
            return {'traceEvents': events};
          default:
            throw StateError(name);
        }
      }

      final file = File('${dir.path}/trace');
      final collector = await StandStorageTimeline.withClient(file, rpc, () {});
      await collector.capture();
      await collector.capture();
      await collector.close();
      final records = (await file.readAsLines())
          .map((s) => Map<String, dynamic>.from(jsonDecode(s) as Map))
          .toList();
      expect(analyzeStorageTimeline(records)['rpcCount'], 1);
    },
  );

  test('an orphan worker end in the middle cannot hide earlier events', () {
    final data = trace();
    final events = data[1]['events'] as List;
    events.addAll(<Map<String, dynamic>>[
      event(
        'stand.storage.rpc',
        'b',
        81,
        id: 'two',
        args: {'sequence': 2, 'operation': 'kv.get'},
      ),
      event(
        'HandleMessage',
        'E',
        84,
        tid: 2,
        args: {'isolateId': 'worker-private'},
      ),
      event('stand.storage.rpc', 'e', 85, id: 'two', args: {'ok': true}),
      event(
        'stand.storage.rpc',
        'b',
        86,
        id: 'three',
        args: {'sequence': 3, 'operation': 'kv.get'},
      ),
      event(
        'HandleMessage',
        'B',
        87,
        tid: 2,
        args: {'isolateId': 'worker-private'},
      ),
      event(
        'HandleMessage',
        'E',
        88,
        tid: 2,
        args: {'isolateId': 'worker-private'},
      ),
      event('stand.storage.rpc', 'e', 90, id: 'three', args: {'ok': true}),
    ]);
    expect(() => analyzeStorageTimeline(data), throwsStateError);
  });

  test(
    'collector drops unrelated VM metadata and enforces its byte ceiling',
    () async {
      for (final byteLimit in [StandStorageTimeline.maxBytes, 1]) {
        final dir = await Directory.systemTemp.createTemp(
          'xv-timeline-private-',
        );
        addTearDown(() => dir.delete(recursive: true));
        var now = 0;
        Future<Map<String, dynamic>> rpc(
          String name, [
          Map<String, String> args = const {},
        ]) async {
          switch (name) {
            case 'getVMTimelineFlags':
              return {'recordedStreams': <String>[]};
            case 'setVMTimelineFlags':
              return {};
            case 'getVM':
              return {
                'isolates': [
                  {'name': '_workerEntry', 'id': 'worker-private'},
                ],
              };
            case 'getVMTimelineMicros':
              return {'timestamp': now += 10};
            case 'getVMTimeline':
              return {
                'traceEvents': [
                  {
                    'name': 'unrelated-private-value',
                    'ts': 12,
                    'ph': 'B',
                    'args': {'body': 'sensitive-payload'},
                  },
                  event(
                    'stand.storage.rpc',
                    'b',
                    12,
                    id: 'one',
                    args: {
                      'sequence': 1,
                      'operation': 'kv.get',
                      'body': 'sensitive-payload',
                    },
                  ),
                  event(
                    'HandleMessage',
                    'B',
                    13,
                    tid: 2,
                    args: {
                      'isolateId': 'worker-private',
                      'path': 'sensitive-payload',
                    },
                  ),
                  event(
                    'HandleMessage',
                    'E',
                    14,
                    tid: 2,
                    args: {
                      'isolateId': 'worker-private',
                      'plaintext': 'sensitive-payload',
                    },
                  ),
                  event(
                    'stand.storage.rpc',
                    'e',
                    15,
                    id: 'one',
                    args: {'ok': true, 'error': 'sensitive-payload'},
                  ),
                ],
              };
            default:
              throw StateError(name);
          }
        }

        final file = File('${dir.path}/trace');
        final collector = await StandStorageTimeline.withClient(
          file,
          rpc,
          () {},
          byteLimit: byteLimit,
        );
        await collector.capture();
        await collector.close();
        final encoded = await file.readAsString();
        expect(encoded, isNot(contains('sensitive-payload')));
        expect(encoded, isNot(contains('unrelated-private-value')));
        final records = (await file.readAsLines())
            .map((s) => Map<String, dynamic>.from(jsonDecode(s) as Map))
            .toList();
        expect(records.last['capped'], byteLimit == 1);
        if (byteLimit == 1) {
          expect(() => analyzeStorageTimeline(records), throwsStateError);
        } else {
          expect(analyzeStorageTimeline(records)['rpcCount'], 1);
        }
      }
    },
  );

  test(
    'independent polling coalesces pending captures and stops on close',
    () async {
      final dir = await Directory.systemTemp.createTemp('xv-timeline-poll-');
      addTearDown(() => dir.delete(recursive: true));
      final entered = Completer<void>(), release = Completer<void>();
      var now = 0, polls = 0, closes = 0;
      Future<Map<String, dynamic>> rpc(
        String name, [
        Map<String, String> args = const {},
      ]) async {
        switch (name) {
          case 'getVMTimelineFlags':
            return {'recordedStreams': <String>[]};
          case 'setVMTimelineFlags':
            return {};
          case 'getVM':
            return {
              'isolates': [
                {'name': '_workerEntry', 'id': 'worker'},
              ],
            };
          case 'getVMTimelineMicros':
            return {'timestamp': ++now};
          case 'getVMTimeline':
            polls++;
            if (!entered.isCompleted) {
              entered.complete();
              await release.future;
            }
            return {'traceEvents': []};
          default:
            throw StateError(name);
        }
      }

      final collector = await StandStorageTimeline.withClient(
        File('${dir.path}/trace'),
        rpc,
        () => closes++,
      );
      collector.startPolling(const Duration(milliseconds: 1));
      await entered.future.timeout(const Duration(seconds: 5));
      expect(identical(collector.capture(), collector.capture()), true);
      expect(polls, 1);
      final close = collector.close();
      release.complete();
      await close;
      expect(polls, 2);
      expect(closes, 1);
      expect(() => collector.startPolling(), throwsStateError);
      await expectLater(collector.capture(), throwsStateError);
    },
  );

  test('failed timeline startup restores flags and closes VM client', () async {
    final dir = await Directory.systemTemp.createTemp('xv-timeline-fail-');
    addTearDown(() => dir.delete(recursive: true));
    var closes = 0;
    final flags = <String>[];
    Future<Map<String, dynamic>> rpc(
      String name, [
      Map<String, String> args = const {},
    ]) async {
      if (name == 'getVMTimelineFlags') {
        return {
          'recordedStreams': ['GC'],
        };
      }
      if (name == 'setVMTimelineFlags') {
        flags.add(args['recordedStreams']!);
        return {};
      }
      throw StateError('synthetic VM failure');
    }

    await expectLater(
      StandStorageTimeline.withClient(
        File('${dir.path}/t'),
        rpc,
        () => closes++,
      ),
      throwsStateError,
    );
    expect(flags.last, '[GC]');
    expect(closes, 1);
  });
}
