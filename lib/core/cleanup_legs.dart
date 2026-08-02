import 'dart:async';

import 'log.dart';

/// Run every teardown step, in order, with no step able to skip the ones after
/// it.
///
/// Teardown is usually written as a straight `await` chain, which reads well
/// and fails badly: one throwing step — an FFI stop on an already-freed
/// handle, a socket that will not close — abandons every step after it. In a
/// headless daemon that left the node holding its ports and the container
/// holding its exclusive lock, with a `_closed` flag already set so a retry
/// returned immediately and nothing ever came back for them (audit XV-16).
///
/// Sequential on purpose: order matters during teardown, and running the steps
/// concurrently would tear down a service while something above it still calls
/// into it. What changes is only that a failure no longer cancels the
/// remainder.
///
/// Returns the FIRST error, or null if every step succeeded. The caller
/// decides whether an unclean teardown is worth surfacing — it usually is,
/// but never at the cost of the teardown itself.
Future<({Object error, StackTrace stack})?> runCleanupLegs(
  String owner,
  List<(String, Future<void> Function())> legs,
) async {
  Object? firstError;
  StackTrace? firstStack;
  for (final (name, run) in legs) {
    try {
      await run();
    } catch (e, st) {
      devLog(() => 'xVeil[$owner]: teardown leg "$name" failed: $e');
      firstError ??= e;
      firstStack ??= st;
    }
  }
  if (firstError == null) return null;
  return (error: firstError, stack: firstStack ?? StackTrace.current);
}
