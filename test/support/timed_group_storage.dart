import 'dart:async';
import 'dart:typed_data';

import 'timed_native_store.dart';
import 'timed_veil_transport.dart';

/// Test-only attribution of real group-file calls and their nested worker RPCs.
/// No file names, IDs, bytes or paths enter the timing events.
class TimedGroupFileStorage extends TimedOutboxStorage {
  TimedGroupFileStorage(
    super.opener, {
    required super.observe,
    required this.clock,
    required this.observeFiles,
  });
  final Stopwatch clock;
  final NativeTiming observeFiles;
  int _nextOperation = 0;

  Future<T> _time<T>(
    String operation,
    String file,
    Future<T> Function() body,
  ) async {
    if (!file.startsWith('group:')) return body();
    final start = clock.elapsedMicroseconds;
    final frame = Zone.current[groupTimingFrameKey];
    final id = ++_nextOperation;
    var success = false;
    try {
      final value = await runZoned(
        body,
        zoneValues: {groupFileTimingOpKey: id},
      );
      success = true;
      return value;
    } finally {
      observeFiles({
        'operation':
            'group_file.$operation.${file.contains(':s:') ? 'segment' : 'header'}',
        'start_us': start,
        'duration_us': clock.elapsedMicroseconds - start,
        'file_operation': id,
        if (frame is int) 'group_frame': frame,
        'success': success,
      });
    }
  }

  @override
  Future<void> storeFile(
    String fileId,
    Uint8List bytes, {
    String? name,
    List<String> retireHints = const [],
  }) => _time(
    'store',
    fileId,
    () => super.storeFile(fileId, bytes, name: name, retireHints: retireHints),
  );
  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) =>
      _time('load', fileId, () => super.loadFile(fileId, maxBytes: maxBytes));
  @override
  Future<List<Uint8List>?> loadFiles(
    List<String> ids, {
    required int maxBytesPerFile,
  }) => _time(
    'loadBatch',
    ids.isEmpty ? '' : ids.first,
    () => super.loadFiles(ids, maxBytesPerFile: maxBytesPerFile),
  );
  @override
  Future<bool> hasFile(String fileId) =>
      _time('has', fileId, () => super.hasFile(fileId));
  @override
  Future<void> deleteStoredFile(String fileId) =>
      _time('delete', fileId, () => super.deleteStoredFile(fileId));
}
