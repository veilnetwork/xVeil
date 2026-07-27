import '../../core/error_journal.dart';

/// The part of a caught error that may be shown to the person.
///
/// Some failures have to name their cause or the notice is useless — "couldn't
/// save the SSH credentials" without a reason leaves nowhere to go. But the
/// raw text is an exception, and exceptions here quote key paths, hostnames,
/// store paths and node ids. A snackbar is visible to whoever is nearby and is
/// the thing people photograph when they ask for help.
///
/// So the cause is kept and the identifying parts are replaced, while the full
/// text goes to [errorJournal] for the report — the same information reaches
/// whoever can act on it, by a route the person chose.
///
/// Use this anywhere a caught error is interpolated into user-visible text.
String shownCause(Object error, {String kind = 'ui'}) {
  errorJournal.record(
    kind: kind,
    error: error,
    atMs: DateTime.now().millisecondsSinceEpoch,
  );
  return ErrorJournal.redact(error.toString(), maxLength: 160);
}
