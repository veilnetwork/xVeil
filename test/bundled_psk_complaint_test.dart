// A missing deployment key is two different situations, and they used to be
// one answer.
//
// The obfs4 pre-shared key is a gitignored asset: absent in a clean clone,
// present in anything shipped. Without it the transport refuses every obfs4
// bootstrap peer BEFORE any handshake — the app starts, reports itself ready,
// and connects to nothing. So "no key" is ordinary in one build and fatal in
// another, and the loader answered `null` to both.
//
// The one line that mentioned it went through `devLog`, which a release build
// compiles out: on precisely the builds where this is fatal, nothing was said
// anywhere. It now goes to the error journal, which a shipped build can still
// show.

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/main.dart';

void main() {
  group('bundledObfs4PskComplaint', () {
    // The clean clone. Every developer build takes this path and it is correct;
    // complaining here would train everyone to ignore the complaint.
    test('a clone with no asset says nothing', () {
      expect(
        bundledObfs4PskComplaint(assetMissing: true, raw: null),
        isNull,
      );
    });

    test('a key that loaded says nothing', () {
      expect(
        bundledObfs4PskComplaint(assetMissing: false, raw: 'a-real-key'),
        isNull,
      );
    });

    // THE CASE THIS EXISTS FOR: shipped, bundled, and unreadable.
    test('a bundled key that could not be read complains', () {
      final complaint = bundledObfs4PskComplaint(
        assetMissing: false,
        raw: null,
      );
      expect(complaint, isNotNull);
      expect(complaint, contains('could not be read'));
      // The consequence belongs in the message. "No key" means nothing to
      // whoever reads the report; "every bootstrap peer is refused" is the
      // sentence that explains an app which connects to nobody.
      expect(complaint, contains('bootstrap peer'));
    });

    test('a bundled key that is empty complains too', () {
      final complaint = bundledObfs4PskComplaint(
        assetMissing: false,
        raw: '   ',
      );
      expect(complaint, isNotNull);
      expect(complaint, contains('empty'));
    });

    // An empty file and a failed read are different faults with the same
    // effect, and the report should let them be told apart.
    test('the two failures do not share a message', () {
      expect(
        bundledObfs4PskComplaint(assetMissing: false, raw: null),
        isNot(bundledObfs4PskComplaint(assetMissing: false, raw: '')),
      );
    });

    // assetMissing wins whatever else is true: a clone cannot have an
    // unreadable asset, and reporting one would be noise on every dev machine.
    test('a missing asset is quiet even with no content', () {
      expect(bundledObfs4PskComplaint(assetMissing: true, raw: ''), isNull);
    });
  });
}
