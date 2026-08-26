import 'package:flutter_test/flutter_test.dart';

/// Assert that [first] appears in [haystack], and appears before [then].
///
/// Exists because the obvious spelling is quietly vacuous:
///
/// ```dart
/// expect(script.indexOf('umask 077'), lessThan(script.indexOf('mktemp -d')));
/// ```
///
/// `indexOf` answers -1 for a string that is not there, and -1 is less than
/// every real index. So that assertion passes most convincingly in exactly the
/// case it exists to catch — when the step it is ordering has been deleted
/// outright. Five such assertions were found in this suite, each guarding
/// something worth guarding (a umask before the first file is written, a
/// certificate issued before the listener that uses it, a screenshot guard
/// around a token QR), and each stayed green when the thing it named was
/// replaced with a string that appears nowhere.
///
/// Both ends are asserted present first, so a missing step fails as a missing
/// step rather than as a satisfied comparison.
void expectBefore(
  String haystack,
  String first,
  String then, {
  String? reason,
}) {
  expect(haystack, contains(first), reason: reason ?? 'missing: $first');
  expect(haystack, contains(then), reason: reason ?? 'missing: $then');
  expect(
    haystack.indexOf(first),
    lessThan(haystack.indexOf(then)),
    reason: reason ?? '"$first" must come before "$then"',
  );
}

/// The same, for a recorded sequence of events rather than a string.
void expectBeforeIn<T>(List<T> events, T first, T then, {String? reason}) {
  expect(events, contains(first), reason: reason ?? 'never happened: $first');
  expect(events, contains(then), reason: reason ?? 'never happened: $then');
  expect(
    events.indexOf(first),
    lessThan(events.indexOf(then)),
    reason: reason ?? '$first must come before $then',
  );
}
