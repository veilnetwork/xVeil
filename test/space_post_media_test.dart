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
}
