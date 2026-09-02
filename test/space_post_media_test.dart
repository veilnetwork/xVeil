import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/spaces/space_post_media.dart';

void main() {
  test(
    'Space publication media classification is stable and case-insensitive',
    () {
      expect(spacePostMediaKind('PHOTO.JPEG'), 'image');
      expect(spacePostMediaKind('clip.MOV'), 'video');
      expect(spacePostMediaKind('voice.OPUS'), 'audio');
      expect(spacePostMediaKind('archive.zip'), 'file');

      expect(spacePostMediaMimeType('PHOTO.JPEG'), 'image/jpeg');
      expect(spacePostMediaMimeType('clip.MOV'), 'video/quicktime');
      expect(spacePostMediaMimeType('voice.OPUS'), 'audio/opus');
      expect(spacePostMediaMimeType('archive.zip'), isNull);
    },
  );

  test('a picker that outlived its identity registers nothing', () {
    // report21 X21-M1. Both helpers awaited a file picker — which hands
    // control to the platform for as long as the user wants it — and only
    // THEN read `messagingServiceProvider`. In all-online mode the user can
    // switch identity while that dialog is up: every node stays running, so
    // the caller's own GroupService keeps working, and the blob was
    // registered against whoever was active by the time the picker closed.
    // The signed Space row then named a content id only the other identity
    // could read.
    //
    // A real file dialog cannot be driven from a test, so what is asserted is
    // the order: the lease and the service are taken BEFORE the await, and the
    // lease is checked after it.
    for (final path in [
      'lib/features/spaces/space_post_media.dart',
      'lib/features/spaces/space_avatar.dart',
    ]) {
      final src = File(path).readAsStringSync();
      final lease = src.indexOf('final lease = app.leaseIdentity();');
      final service = src.indexOf('final messaging = ref.read(messagingServiceProvider);');
      final picker = src.indexOf('await FilePicker.pickFiles(');
      final check = src.indexOf('app.holdsIdentity(lease)');

      expect(lease, greaterThan(-1), reason: '$path takes no identity lease');
      expect(picker, greaterThan(-1), reason: '$path no longer picks files');
      expect(
        lease,
        lessThan(picker),
        reason: '$path takes its lease AFTER the picker, which is after the '
            'switch it exists to notice',
      );
      expect(
        service,
        lessThan(picker),
        reason: '$path reads the messaging service after the picker, so the '
            'blob goes to whoever is active by then rather than to the '
            'identity the caller is signing for',
      );
      expect(
        check,
        greaterThan(picker),
        reason: '$path never checks its lease once the picker returns',
      );
    }
  });
}
