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
  Object? _aborted;
  StackTrace? _abortStack;

  void start(
    Future<void> Function(PreparedMessageWrites) apply, {
    required bool prepareOrdering,
  }) {
    void stage() {
      final aborted = _aborted;
      if (aborted != null) Error.throwWithStackTrace(aborted, _abortStack!);
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

  void abort(Object error, StackTrace stack) {
    _aborted = error;
    _abortStack = stack;
    if (pending && !publication.isCompleted) {
      publication.completeError(error, stack);
    }
  }
}

/// Bounded preparation of distinct, already validated message IDs. Results
/// enter publication in input order, independently of preparation completion.
class _HistoryWriteCohort {
  _HistoryWriteCohort(this.store, this.checkAdmission);
  final Storage store;
  final Future<void> Function(List<DeviceSyncEvent>) checkAdmission;
  final _pending = <({DeviceSyncEvent event, _PreparedHistoryRow row})>[];
  final _all = <_PreparedHistoryRow>[];
  static const _publicationRows = preparedMessageBatchMaxRows;

  Future<void> applyAll(
    List<DeviceSyncEvent> events,
    Future<void> Function(DeviceSyncEvent, PreparedMessageWrites) action,
  ) async {
    for (var start = 0; start < events.length;) {
      final wave = <({DeviceSyncEvent event, _PreparedHistoryRow row})>[];
      // Prepare the rest of one publication together. A family change can
      // leave a short staged cohort; those rows still occupy this budget.
      final available = _publicationRows - _pending.length;
      for (final event in events.skip(start).take(available)) {
        final row = _PreparedHistoryRow();
        _all.add(row);
        wave.add((event: event, row: row));
        row.start(
          (writes) => action(event, writes),
          prepareOrdering: store is PreparedOrderingBatchStore,
        );
      }
      for (final item in wave) {
        final row = item.row;
        await row.ready.future;
        row.check();
        if (row.pending) {
          // Preserve ordered publication across write families, even when a
          // later preparation reached its boundary before an earlier one.
          if (_pending.isNotEmpty &&
              (_pending.first.row.ordering != null) != (row.ordering != null)) {
            await flush();
          }
          _pending.add(item);
          if (_pending.length == _publicationRows) await flush();
        }
      }
      start += wave.length;
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
      // Some wave members may still be reading when an earlier row fails.
      // They must reject a late stage, rather than wait forever on a promise
      // which this abort could not see yet. Join every started continuation.
      row.abort(error, stack);
    }
    await Future.wait([for (final row in _all) row.settled]);
  }
}
