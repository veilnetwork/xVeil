import 'dart:convert';
import 'dart:math' as math;
import 'storage_commit_labels.dart';

typedef _Span = ({
  int start,
  int end,
  String? operation,
  int? sequence,
  String? commitClass,
});

/// Strict FIFO qualification for ONE synchronous storage worker. Boundary
/// partial spans are trimmed, never repaired; gaps, missing middle events,
/// empty traces and mismatched counts refuse attribution.
Map<String, Object> analyzeStorageTimeline(List<Map<String, dynamic>> records) {
  final open = records.first;
  if (open['kind'] != 'open' ||
      open['schema'] != 'xveil-private-storage-timeline/1' ||
      records.last['kind'] != 'close' ||
      records.last['capped'] != false ||
      records.last['pollFailed'] == true) {
    throw StateError('incomplete or capped storage timeline');
  }
  final workers = open['workers'] as List;
  if (workers.length != 1) throw StateError('exactly one worker is required');
  final events = <Map<String, dynamic>>[];
  final seen = <String>{};
  var end = open['originUs'] as int;
  for (final record in records.skip(1)) {
    if (record['kind'] != 'chunk') continue;
    if (record['fromUs'] != end || (record['toUs'] as int) < end) {
      throw StateError('timeline capture gap');
    }
    end = record['toUs'] as int;
    for (final raw in record['events'] as List) {
      final event = Map<String, dynamic>.from(raw as Map);
      if ((event['name'] == 'stand.storage.rpc' ||
              (event['name'] == 'HandleMessage' &&
                  (event['args'] as Map?)?['isolateId'] == workers.single)) &&
          seen.add(jsonEncode(event))) {
        events.add(event);
      }
    }
  }
  // VM events on one thread may share a microsecond. List.sort is unstable;
  // keep their recorded order rather than inventing nested HandleMessage spans.
  final order = Map<Map<String, dynamic>, int>.identity();
  for (var i = 0; i < events.length; i++) {
    order[events[i]] = i;
  }
  events.sort((a, b) {
    final time = (a['ts'] as int).compareTo(b['ts'] as int);
    return time != 0 ? time : order[a]!.compareTo(order[b]!);
  });
  final rpcOpen = <Object, Map<String, dynamic>>{};
  final workerOpen = <Object, Map<String, dynamic>>{};
  final rpc = <_Span>[], worker = <_Span>[];
  var start = open['originUs'] as int;
  for (final event in events) {
    final isRpc = event['name'] == 'stand.storage.rpc';
    final pending = isRpc ? rpcOpen : workerOpen;
    final key = isRpc ? event['id'] : event['tid'];
    if (key == null) throw StateError('timeline span has no key');
    final phase = event['ph'];
    if (phase == (isRpc ? 'b' : 'B')) {
      if (pending.containsKey(key)) throw StateError('nested storage span');
      pending[key] = event;
    } else if (phase == (isRpc ? 'e' : 'E')) {
      final begin = pending.remove(key);
      if (begin == null) {
        if ((isRpc ? rpc : worker).isNotEmpty) {
          throw StateError('orphan event inside captured timeline');
        }
        start = math.max(start, event['ts'] as int);
        continue;
      }
      final args = begin['args'] as Map?;
      if (isRpc && (event['args'] as Map?)?['ok'] != true) {
        throw StateError('failed RPC cannot prove queue correspondence');
      }
      (isRpc ? rpc : worker).add((
        start: begin['ts'] as int,
        end: event['ts'] as int,
        operation: isRpc ? (args?['operation'] as String?) : null,
        sequence: isRpc ? (args?['sequence'] as int?) : null,
        commitClass:
            isRpc && storageCommitLabels.contains(args?['commit_class'])
            ? args!['commit_class'] as String
            : null,
      ));
    }
  }
  final captureWindowUs = end - (open['originUs'] as int);
  for (final begin in [...rpcOpen.values, ...workerOpen.values]) {
    end = math.min(end, begin['ts'] as int);
  }
  // Keep a closed window: no known RPC/handler may cross either boundary.
  var changed = true;
  while (changed) {
    changed = false;
    for (final span in [...rpc, ...worker]) {
      if (span.start < start && span.end > start) {
        start = span.end;
        changed = true;
      }
      if (span.start < end && span.end > end) {
        end = span.start;
        changed = true;
      }
    }
  }
  List<_Span> inside(List<_Span> spans) =>
      spans.where((s) => s.start >= start && s.end <= end).toList()..sort((
        a,
        b,
      ) {
        final time = a.start.compareTo(b.start);
        return time != 0 ? time : (a.sequence ?? 0).compareTo(b.sequence ?? 0);
      });
  final calls = inside(rpc), handlers = inside(worker);
  if (calls.isEmpty || calls.length != handlers.length) {
    throw StateError('RPC/worker span count mismatch or empty trace');
  }
  const operations = {
    'kv.commit',
    'kv.get',
    'kv.getBatch',
    'kv.readLog',
    'kv.readLogBatch',
    'kv.readLogGroups',
    'kv.iterLogRange',
    'kv.count',
    'kv.keys',
    'kv.erase',
    'kv.scrub',
    'kv.exportKeys',
    'kv.slots',
    'kv.hardeningWarning',
    'kv.ackHardening',
    'kv.close',
    'anchor.sequence',
    'anchor.history',
    'anchor.roots',
  };
  final categories = <String, Map<String, int>>{};
  final commits = <String, Map<String, int>>{};
  for (var i = 0; i < calls.length; i++) {
    final call = calls[i], handler = handlers[i];
    if (!operations.contains(call.operation) ||
        call.sequence == null ||
        (i > 0 && call.sequence != calls[i - 1].sequence! + 1) ||
        handler.start < call.start ||
        handler.start > call.end ||
        (i > 0 && handler.start < handlers[i - 1].end)) {
      throw StateError('storage FIFO correspondence not proven');
    }
    final stats = categories.putIfAbsent(
      call.operation!,
      () => {
        'count': 0,
        'awaitUs': 0,
        'beforeHandlerUs': 0,
        'handlerUs': 0,
        'signedReplyTailUs': 0,
        'negativeReplyTails': 0,
      },
    );
    stats['count'] = stats['count']! + 1;
    stats['awaitUs'] = stats['awaitUs']! + call.end - call.start;
    stats['beforeHandlerUs'] =
        stats['beforeHandlerUs']! + handler.start - call.start;
    stats['handlerUs'] = stats['handlerUs']! + handler.end - handler.start;
    final tail = call.end - handler.end;
    stats['signedReplyTailUs'] = stats['signedReplyTailUs']! + tail;
    if (tail < 0) {
      stats['negativeReplyTails'] = stats['negativeReplyTails']! + 1;
    }
    if (call.operation == 'kv.commit') {
      final aggregate = commits.putIfAbsent(
        call.commitClass ?? 'unclassified',
        () => {for (final key in stats.keys) key: 0},
      );
      aggregate['count'] = aggregate['count']! + 1;
      aggregate['awaitUs'] = aggregate['awaitUs']! + call.end - call.start;
      aggregate['beforeHandlerUs'] =
          aggregate['beforeHandlerUs']! + handler.start - call.start;
      aggregate['handlerUs'] =
          aggregate['handlerUs']! + handler.end - handler.start;
      aggregate['signedReplyTailUs'] = aggregate['signedReplyTailUs']! + tail;
      if (tail < 0) {
        aggregate['negativeReplyTails'] = aggregate['negativeReplyTails']! + 1;
      }
    }
  }
  return {
    'schema': 'xveil-test-storage-queue-summary/1',
    'qualified': true,
    'rpcCount': calls.length,
    'workerCount': handlers.length,
    'windowUs': end - start,
    'captureWindowUs': captureWindowUs,
    'capturedCompleteRpcs': rpc.length,
    'capturedCompleteHandlers': worker.length,
    'trimmedRpcs': rpc.length - calls.length,
    'trimmedHandlers': worker.length - handlers.length,
    'operations': categories,
    'commitClasses': commits,
  };
}
