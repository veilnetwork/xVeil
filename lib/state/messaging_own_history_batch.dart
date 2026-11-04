part of 'messaging_core.dart';

/// One ordinary mirror applier, suspended only at a durable write boundary. Its
/// future never reports success before the cohort's durable publication.
class _PreparedHistoryRow {
  final ready = Completer<void>();
  final publication = Completer<Object>();
  late final Future<void> settled;
  Message? message;
  MessageOrderingAdoption? ordering;
  bool get pending => message != null || ordering != null;
  Object? error;
  StackTrace? stack;

  void start(
    Future<void> Function(PreparedMessageWrites) apply, {
    required bool prepareOrdering,
  }) {
    void stage() {
      if (pending) throw StateError('mirror requested two prepared writes');
      if (!ready.isCompleted) ready.complete();
    }

    final writes = PreparedMessageWrites(
      append: (value) {
        stage();
        message = value.copyWith(
          customEmoji: List.unmodifiable(value.customEmoji),
        );
        return publication.future.then(
          (value) => value as PreparedMessageWrite,
        );
      },
      adoptOrdering: prepareOrdering
          ? (request) {
              stage();
              ordering = request;
              return publication.future.then((value) => value as bool);
            }
          : null,
    );
    settled = Future<void>.sync(() => apply(writes)).then<void>(
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
/// which have reached their write boundary wait together for publication.
class _HistoryWriteCohort {
  _HistoryWriteCohort(this.store, this.checkAdmission);
  final Storage store;
  final Future<void> Function(List<DeviceSyncEvent>) checkAdmission;
  final _pending = <({DeviceSyncEvent event, _PreparedHistoryRow row})>[];
  final _all = <_PreparedHistoryRow>[];

  Future<void> apply(
    DeviceSyncEvent event,
    Future<void> Function(PreparedMessageWrites) action,
  ) async {
    final row = _PreparedHistoryRow();
    _all.add(row);
    row.start(action, prepareOrdering: store is PreparedOrderingBatchStore);
    await row.ready.future;
    row.check();
    if (row.pending) {
      // Preserve sequential merge semantics across different write families.
      // In particular an earlier insert is durable before a later correction.
      if (_pending.isNotEmpty &&
          (_pending.first.row.ordering != null) != (row.ordering != null)) {
        await flush();
      }
      _pending.add((event: event, row: row));
      if (_pending.length == 16) await flush();
    }
  }

  Future<void> flush() async {
    if (_pending.isEmpty) return;
    final rows = List.of(_pending);
    final events = [for (final item in rows) item.event];
    await checkAdmission(events);
    final ordering = rows.first.row.ordering != null;
    final List<Object>? results = ordering
        ? await (store as PreparedOrderingBatchStore).adoptMessageOrderingBatch(
            [for (final item in rows) item.row.ordering!],
            beforeCommit: () => checkAdmission(events),
          )
        : await (store as PreparedMessageBatchStore).appendMissingMessageBatch([
            for (final item in rows) item.row.message!,
          ], beforeCommit: () => checkAdmission(events));
    if (results == null) {
      // Unsupported writes resume the original per-message path, one at a
      // time; no promise of an unperformed publication is manufactured.
      for (final item in rows) {
        await checkAdmission([item.event]);
        if (ordering) {
          final request = item.row.ordering!;
          final changed = await store.adoptMessageOrdering(
            request.conversationId,
            request.messageId,
            provisionalAuthor: request.provisionalAuthor,
            provisionalSeq: request.provisionalSeq,
            author: request.author,
            seq: request.seq,
          );
          item.row.publication.complete(changed);
        } else {
          item.row.publication.complete(PreparedMessageWrite.existing);
        }
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
      if (row.pending && !row.publication.isCompleted) {
        row.publication.completeError(error, stack);
      }
    }
    await Future.wait([for (final row in _all) row.settled]);
  }
}
