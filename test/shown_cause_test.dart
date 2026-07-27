import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/features/common/shown_cause.dart';

void main() {
  setUp(errorJournal.clear);

  test('the cause survives — a notice without one is useless', () {
    // "Couldn't save the SSH credentials" with no reason leaves nowhere to go.
    for (final (raw, keep) in [
      ('Permission denied (publickey)', 'Permission denied'),
      ('Connection refused', 'Connection refused'),
      ('No such file or directory', 'No such file'),
    ]) {
      expect(shownCause(StateError(raw)), contains(keep), reason: raw);
    }
  });

  test('a key path and a home directory do not', () {
    final shown = shownCause(
      StateError('cannot read /Users/someone/.ssh/id_ed25519: denied'),
    );
    expect(shown, isNot(contains('/Users/')));
    expect(shown, isNot(contains('someone')));
    expect(shown, contains('denied'), reason: 'the reason still shows');
  });

  test('a node id does not', () {
    final shown = shownCause(
      StateError(
        'peer 7084a345b55ef17031b793b96a9edca2cb1836151490c3a67d1ceab906f2a8a2 gone',
      ),
    );
    expect(shown, isNot(contains('7084a345')));
    expect(shown, contains('gone'));
  });

  test('the full text still reaches the report', () {
    // Redacting for the screen must not mean losing it: the person can still
    // hand the detail over deliberately.
    shownCause(StateError('Connection refused'), kind: 'ssh');
    expect(errorJournal.entries, hasLength(1));
    expect(errorJournal.entries.single.kind, 'ssh');
    expect(errorJournal.entries.single.message, contains('Connection refused'));
  });

  test('a long error is capped — a snackbar is not a log viewer', () {
    expect(
      shownCause(StateError(List.filled(200, 'why').join(' '))).length,
      lessThan(200),
    );
  });
}
