part of 'messaging_core.dart';

/// One ordinary mirror applier, suspended only at its insert boundary. Its
/// future never reports success before the cohort's durable publication.
class _PreparedHistoryRow {
  final ready = Completer<void>();
  final publication = Completer<PreparedMessageWrite>();
  late final Future<void> settled;
  Message? message;
  Object? error;
  StackTrace? stack;

  void start(Future<void> Function(PreparedMessageAppender) apply) {
    settled =
        Future<void>.sync(
          () => apply((value) {
            if (message != null) {
              throw StateError('mirror requested two appends');
            }
            message = value.copyWith(
              customEmoji: List.unmodifiable(value.customEmoji),
            );
            if (!ready.isCompleted) ready.complete();
            return publication.future;
          }),
        ).then<void>(
          (_) {
            if (!ready.isCompleted) ready.complete();
          },
          onError: (Object e, StackTrace trace) {
            error = e;
            stack = trace;
            if (!ready.isCompleted) ready.complete();
          },
        );
  }

  void check() {
    if (error != null) Error.throwWithStackTrace(error!, stack!);
  }
}

/// Bounded prepared continuations. Preparation is sequential; only futures
/// which have reached their insert boundary wait together for publication.
class _HistoryAppendCohort {
  _HistoryAppendCohort(this.store, this.checkAdmission);
  final PreparedMessageBatchStore store;
  final Future<void> Function(List<DeviceSyncEvent>) checkAdmission;
  final _pending = <({DeviceSyncEvent event, _PreparedHistoryRow row})>[];
  final _all = <_PreparedHistoryRow>[];

  Future<void> apply(
    DeviceSyncEvent event,
    Future<void> Function(PreparedMessageAppender) action,
  ) async {
    final row = _PreparedHistoryRow();
    _all.add(row);
    row.start(action);
    await row.ready.future;
    row.check();
    if (row.message != null) {
      _pending.add((event: event, row: row));
      if (_pending.length == 16) await flush();
    }
  }

  Future<void> flush() async {
    if (_pending.isEmpty) return;
    final rows = List.of(_pending);
    final events = [for (final item in rows) item.event];
    await checkAdmission(events);
    final results = await store.appendMissingMessageBatch([
      for (final item in rows) item.row.message!,
    ], beforeCommit: () => checkAdmission(events));
    if (results == null) {
      // Unsupported payloads resume the original single-message merge, one
      // at a time; no promise of an unperformed insert is manufactured.
      for (final item in rows) {
        await checkAdmission([item.event]);
        item.row.publication.complete(PreparedMessageWrite.existing);
        await item.row.settled;
        item.row.check();
      }
    } else {
      if (results.length != rows.length) {
        throw StateError('prepared result count mismatch');
      }
      await checkAdmission(events);
      for (var i = 0; i < rows.length; i++) {
        rows[i].row.publication.complete(results[i]);
      }
      await Future.wait([for (final item in rows) item.row.settled]);
      for (final item in rows) {
        item.row.check();
      }
    }
    _pending.clear();
  }

  Future<void> abort(Object error, StackTrace stack) async {
    for (final row in _all) {
      if (row.message != null && !row.publication.isCompleted) {
        row.publication.completeError(error, stack);
      }
    }
    await Future.wait([for (final row in _all) row.settled]);
  }
}
