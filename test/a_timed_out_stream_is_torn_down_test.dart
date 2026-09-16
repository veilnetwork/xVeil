import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  /// A timeout tears the stream down; it does not part with it politely.
  ///
  /// `onTimeout` gives the waiting side an answer. It does not stop the read
  /// it was waiting on, which is outstanding down in the native stream — so
  /// returning through a graceful close left that read, and the shared serve
  /// gate behind it, with nothing to end them. How long that lasts is not this
  /// side's to decide (report27 X38).
  ///
  /// Checked at the source. The loopback the stream tests use models `abort`
  /// as a local flag and does not propagate it to the far end, so a test
  /// written against it would assert the harness rather than the code — and a
  /// probe that cannot tell the two apart is worse than none.
  group('a timeout aborts rather than closes', () {
    test('the serve marks itself failed when the request never comes', () {
      final src = File(
        'lib/state/messaging_content_server.dart',
      ).readAsStringSync();
      final at = src.indexOf('stream-serve EOF/timeout before request');
      expect(at, greaterThan(0), reason: 'the timeout branch moved');
      // Its own branch, as far as the return.
      final branch = src.substring(at, src.indexOf('return;', at));
      expect(
        branch,
        contains('failed = true;'),
        reason:
            'the serve returns through the graceful close, leaving the read '
            'it had already started with nothing to end it',
      );
      // And the finally really does distinguish the two.
      expect(
        src,
        contains('await stream.abort();'),
        reason: 'the teardown no longer has an abort to reach',
      );
    });

    test('the manifest probe does not close gracefully after a timeout', () {
      final src = File(
        'lib/state/messaging_content_pull.dart',
      ).readAsStringSync();
      final at = src.indexOf('final probe = await MessagingService._readExactly(stream, 1)');
      expect(
        at,
        greaterThan(0),
        reason:
            'the probe result is discarded again — a timeout then falls '
            'through to `gracefulClose = true`',
      );
      final after = src.substring(at, src.indexOf('gracefulClose = true;', at));
      expect(
        after,
        contains('if (probe == null)'),
        reason: 'nothing between the probe and the graceful close reads it',
      );
      expect(
        after,
        contains('return m;'),
        reason:
            'the timed-out probe does not leave before the graceful close, so '
            'it still parts politely with a read that is still running',
      );
    });
  });
}
