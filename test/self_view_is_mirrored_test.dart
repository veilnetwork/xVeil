// A person looking at themselves expects a mirror. Android mirrored a front
// lens and the desktop path did not, so one call showed the phone's owner the
// right way round and the laptop's owner reversed — reported from a laptop as
// "the self thumbnail is inverted".
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/calls/video_frame_view.dart';

void main() {
  group('the decision', () {
    test('a camera self-view is mirrored', () {
      expect(selfViewMirrored(screenSharing: false), isTrue);
    });

    test('a shared screen is NOT', () {
      // Text on a mirrored screen share is unreadable, and a desktop is not a
      // face: nobody expects a mirror of it.
      expect(selfViewMirrored(screenSharing: true), isFalse);
    });
  });

  // Both self-views have to ASK. A widget that mirrors unconditionally flips a
  // shared screen; one that never asks is the defect this came from. Read out
  // of the source because both need a live call to render.
  group('both self views ask', () {
    for (final path in const [
      'lib/features/calls/call_overlay.dart',
      'lib/features/calls/group_call_overlay.dart',
    ]) {
      test('$path applies the decision rather than a constant', () {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains('selfViewMirrored(screenSharing:'),
          reason: '$path mirrors (or does not) without asking, so a screen '
              'share is flipped or a face is not',
        );
      });
    }

    test('a remote tile is never mirrored', () {
      // Flipping somebody else's face is not a mirror, it is a lie about how
      // they look — and the group grid renders self and remote through one
      // widget, so the flag has to be gated on `isSelf`.
      final source =
          File('lib/features/calls/group_call_overlay.dart').readAsStringSync();
      final at = source.indexOf('mirrored:');
      expect(at, isNot(-1), reason: 'the group tile no longer takes the flag');
      final value = source.substring(at, source.indexOf(',', at + 10));
      expect(
        value,
        contains('isSelf'),
        reason: 'the group grid hands `$value` to every tile, so remote faces '
            'are flipped too',
      );
    });
  });
}
