// Every group-layer callback installed on the messaging service is detached
// when the group service that installed it goes away.
//
// In all-online the messaging service belongs to one identity and lives for the
// whole session, while `groupServiceProvider` is built for the ACTIVE identity
// and disposed on every switch. Its callbacks used to stay attached, so the
// next frame arriving on the old identity's pipeline was handed to a DISPOSED
// group service: it could still write storage and then throw on a closed
// controller, with durable frames already acknowledged and deduplicated by
// then (report9 X-19).
//
// A source check rather than a behavioural one, deliberately. The failure this
// guards is a NEW binding added without its detach, and that is a fact about
// the file: exercising it would need a booted messaging service, a signer and a
// transport, and would still only cover whichever callback the test happened to
// pick. Here nothing can be added without being noticed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'lib/state/group_service_providers.dart',
  ).readAsStringSync();

  // `messaging.foo =` — an assignment, not a call. `(?!=)` keeps `==` out.
  final assigned = RegExp(
    r'\bmessaging\.(\w+)\s*=(?!=)',
  ).allMatches(source).map((match) => match.group(1)!).toSet();
  final detached = RegExp(
    r'\bmessaging\.(\w+)\s*=\s*null\s*;',
  ).allMatches(source).map((match) => match.group(1)!).toSet();

  test('the file still binds what this check is about', () {
    // Non-vacuity: if a refactor moves the bindings elsewhere, an empty set
    // would make every assertion below pass while guarding nothing.
    expect(
      assigned.length,
      greaterThanOrEqualTo(20),
      reason:
          'found only ${assigned.length} bindings — the bindings moved and '
          'this gate is now watching an empty file',
    );
    expect(assigned, contains('onGroupEntry'));
    expect(assigned, contains('groupBindingsOwner'));
  });

  test('every binding installed here is also cleared here', () {
    expect(
      assigned.difference(detached),
      isEmpty,
      reason:
          'these are attached to a messaging service that outlives the group '
          'service, and never detached — the next frame for that identity is '
          'delivered to a disposed service:\n'
          '  ${assigned.difference(detached).join("\n  ")}\n'
          'Add the matching line to _detachGroupBindings.',
    );
  });

  test('nothing is cleared that was never installed', () {
    expect(
      detached.difference(assigned),
      isEmpty,
      reason:
          'cleared but never set here — either the binding moved and the '
          'detach is stale, or the name is wrong:\n'
          '  ${detached.difference(assigned).join("\n  ")}',
    );
  });

  test('the detach only fires for the build that owns the bindings', () {
    // Dispose order between the outgoing build and the incoming one is not
    // something to bet on. Without the guard, an outgoing build could clear the
    // callbacks a newer one had already installed on the same service — which
    // silences the identity that just became active, a worse failure than the
    // one being fixed.
    expect(
      source,
      contains(
        'if (!identical(messaging.groupBindingsOwner, service)) return;',
      ),
      reason: 'the detach is unguarded and can clear a newer build’s bindings',
    );
  });
}
