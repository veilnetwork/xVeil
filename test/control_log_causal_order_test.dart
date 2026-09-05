import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The control log is ordered by what happened, not by what a clock says.
///
/// Concurrent heads used to be ranked by `createdAtMs` — a number each entry's
/// own author picks, which nothing in this network issues and no signature
/// makes honest. Dating a row forward made it the standing last word over every
/// concurrent honest row until that date arrived: a name, a description, a
/// channel, a retention window or a role change that an equal-rank author could
/// not override (report5-plan §5.3, R5b-EXTRA-3).
///
/// What replaced it is not a different arbitrary key. It is the happens-before
/// edge the log never carried: each row names the newest row its author had
/// already applied, and the fold honours that. Only rows with no edge between
/// them fall back to an arbitrary — but unchooseable — order.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('the merge does not rank concurrent heads by a clock', () {
    final policy = read('lib/domain/group_policy.dart');
    final start = policy.indexOf('int compareHeads(');
    expect(start, isNot(-1), reason: 'compareHeads was renamed');
    final body = policy.substring(start, policy.indexOf('\n  }', start));
    expect(
      body,
      isNot(contains('createdAtMs')),
      reason:
          'the ordering key is a number the row author picks; dating forward '
          'buys the last word again',
    );
    expect(
      body,
      contains('controlSlotKey'),
      reason:
          'genuinely concurrent heads need an order nobody can choose, and the '
          'slot digest is one',
    );
  });

  test('the edge is carried, stamped and honoured', () {
    // Three places, and it is worth nothing unless all three are there: the
    // field on the wire, the author stamping it, and the fold waiting on it.
    expect(
      read('lib/domain/group.dart'),
      contains('final String? seen;'),
      reason: 'ControlEntry no longer carries the happens-before edge',
    );
    expect(
      read('lib/state/group_service.dart'),
      contains('seen: link.seen'),
      reason: 'rows are authored without naming what their author had seen',
    );
    final policy = read('lib/domain/group_policy.dart');
    expect(
      policy,
      contains('settled.contains(seen)'),
      reason: 'the fold ignores the edge it is given',
    );
  });

  test('the edge is additive, so rows signed before it still verify', () {
    // `seen` is absent from the canonical bytes when null. Were it always
    // present, every row ever signed would stop verifying at once.
    final group = read('lib/domain/group.dart');
    expect(group, contains("if (seen != null) 'seen': seen,"));
    // ...and nowhere unconditionally: a bare `'seen': seen` in either encoder
    // would put a null into the bytes of every row that has no edge.
    expect(
      RegExp(r"(?<!\!= null\) )'seen': seen,").allMatches(group),
      isEmpty,
      reason: 'the field is written unconditionally somewhere',
    );
  });

  test('the second copy of the signed layout carries it too', () {
    // SpacePublicAuthorityLink.transferCanonicalBytes rebuilds a control
    // entry's signed bytes BY HAND so the public wire can carry the original
    // signature without the rest of the log. That makes every additive field
    // on ControlEntry a silent break here — the row is signed over bytes that
    // include it and the reconstruction omits it, so the signature stops
    // verifying and the authority chain fails closed. It is exactly what
    // happened when `seen` landed, and the failure was a null publication with
    // nothing saying why.
    final discovery = read('lib/domain/space_discovery.dart');
    final start = discovery.indexOf('Uint8List transferCanonicalBytes(');
    expect(start, isNot(-1));
    final body = discovery.substring(start, discovery.indexOf('\n  );', start));
    expect(
      body,
      contains("if (seen != null) 'seen': seen,"),
      reason:
          'the hand-written copy of the signed layout has drifted from '
          'ControlEntry.canonicalBytes again',
    );
  });
}
