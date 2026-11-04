// Read-only synthetic-stand oracle. Never imported by production code.
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/group_message.dart';

Map<String, int> queuedSnapshotStats(
  List<OutboxFrame> frames,
  String gid,
  Set<String> targetIds, {
  required String keepKey,
}) {
  final grouped = <String, List<OutboxFrame>>{};
  var relevantFrames = 0,
      complete = 0,
      partial = 0,
      malformed = 0,
      matches = 0,
      keeps = 0,
      mixed = 0;
  final seen = <String>{};
  for (final f in frames) {
    String? tid;
    if (f.frameId.startsWith('grp:$gid:')) {
      tid = f.frameId;
    } else if (f.frameId.startsWith('grpc:grp:$gid:')) {
      tid = f.frameId.substring(5, f.frameId.lastIndexOf(':'));
    }
    if (tid != null) {
      relevantFrames++;
      (grouped[tid] ??= []).add(f);
    }
  }
  for (final entry in grouped.entries) {
    try {
      final fields = entry.key.split(':');
      if (fields.length != 4 || fields[1] != gid) throw const FormatException();
      Uint8List bytes;
      if (entry.value.singleOrNull case final OutboxFrame f?
          when f.frameId == entry.key) {
        final e = WireEnvelope.decode(f.wire);
        if (e.kind != WireKind.groupEntry ||
            e.frameId != f.frameId ||
            f.peerHex != fields.last) {
          throw const FormatException();
        }
        bytes = Uint8List.fromList(utf8.encode(e.body));
      } else {
        final parts = <int, Uint8List>{};
        int? count;
        for (final f in entry.value) {
          final e = WireEnvelope.decode(f.wire);
          if (e.kind != WireKind.groupEntryChunk ||
              e.frameId != f.frameId ||
              f.peerHex != fields.last) {
            throw const FormatException();
          }
          final p = parseGroupEntryChunk(e.body);
          if (p.transferId != entry.key ||
              p.count < 1 ||
              p.count > 4096 ||
              p.index < 0 ||
              p.index >= p.count ||
              (count != null && p.count != count) ||
              parts.containsKey(p.index)) {
            throw const FormatException();
          }
          count = p.count;
          parts[p.index] = p.data;
        }
        if (count == null || parts.length != count) {
          partial++;
          continue;
        }
        bytes = Uint8List.fromList([
          for (var i = 0; i < count; i++) ...parts[i]!,
        ]);
      }
      final digest = crypto.sha256.convert([
        ...utf8.encode('xveil.replication.group-snapshot.v1\u0000$gid\u0000'),
        ...bytes,
      ]).toString();
      if (digest != fields[2]) throw const FormatException();
      complete++;
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map || json['g'] is! List) continue;
      var hit = false, keep = false;
      for (final raw in json['g'] as List) {
        final row = GroupMessage.fromJson(raw);
        final event = row == null ? null : DeviceSyncEvent.fromBody(row.body);
        if (event == null) continue;
        if ((event.kind == DeviceSyncKind.msgMirror ||
                event.kind == DeviceSyncKind.msgEdit) &&
            targetIds.contains(event.key)) {
          matches++;
          seen.add(event.key);
          hit = true;
        }
        if (event.kind == DeviceSyncKind.settingSet && event.key == keepKey) {
          keeps++;
          keep = true;
        }
      }
      if (hit && keep) mixed++;
    } catch (_) {
      malformed++;
    }
  }
  return {
    'frames': relevantFrames,
    'completeTransfers': complete,
    'partialTransfers': partial,
    'malformedTransfers': malformed,
    'matchingRows': matches,
    'matchingIds': seen.length,
    'keepRows': keeps,
    'mixedTransfers': mixed,
  };
}

/// Inspect committed native roots without the application's automatic Outbox
/// loader/garbage collector. Caller must stop the owning process first.
Future<Map<String, int>> stoppedOutboxStats(
  AsyncKvLogStore store,
  String gid,
  Set<String> ids, {
  required String keepKey,
  void Function(List<OutboxFrame>)? inspectFrames,
}) async {
  final records = <int, Uint8List>{};
  int? start;
  while (true) {
    final page = await store.iterLogRange(
      namespace: Ns.outbox,
      start: start,
      limit: 256,
    );
    if (page.isEmpty) break;
    for (final row in page) {
      records[row.logId] = row.payload;
    }
    start = page.last.logId + 1;
  }
  final referenced = <int>{};
  final frames = <OutboxFrame>[];
  for (final key in await store.kvKeys(Ns.outboxIndex)) {
    final value = (await store.get(Ns.outboxIndex, key))!;
    final index = int.parse(utf8.decode(value));
    referenced.add(index);
    final header = jsonDecode(utf8.decode(records[index]!)) as Map;
    Object? decoded = header;
    if (header['outboxParts'] == 1) {
      final first = header['first'] as int, count = header['count'] as int;
      if (count < 1 || count > 1024) {
        throw StateError('invalid probe payload span');
      }
      final joined = BytesBuilder(copy: false);
      for (var i = 0; i < count; i++) {
        referenced.add(first + i);
        joined.add(records[first + i]!);
      }
      final bytes = joined.takeBytes();
      if (bytes.length != header['length'] ||
          crypto.sha256.convert(bytes).toString() != header['sha256']) {
        throw StateError('invalid probe payload digest');
      }
      decoded = jsonDecode(utf8.decode(bytes));
    }
    final row = decoded as Map;
    final id = row['id'] as String;
    if (base64Encode(key) !=
        base64Encode(crypto.sha256.convert(utf8.encode(id)).bytes)) {
      throw StateError('invalid probe index binding');
    }
    frames.add(
      OutboxFrame(
        frameId: id,
        peerHex: row['p'] as String,
        wire: base64Decode(row['w'] as String),
        enqueuedAtMs: row['t'] as int?,
      ),
    );
  }
  inspectFrames?.call(List.unmodifiable(frames));
  return {
    ...queuedSnapshotStats(frames, gid, ids, keepKey: keepKey),
    'rawPayloadRows': records.length,
    'referencedPayloadRows': referenced.length,
    'cleanupPending':
        await store.get(
              Ns.settings,
              Uint8List.fromList(
                utf8.encode('outbox.replacement_scrub_pending'),
              ),
            ) ==
            null
        ? 0
        : 1,
    'orphanPayloadRows': records.entries
        .where((e) => !referenced.contains(e.key) && e.value.isNotEmpty)
        .length,
  };
}
