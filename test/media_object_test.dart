import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/media_object.dart';

void main() {
  test('message and publication names resolve to one domain object', () {
    final GroupAttachment legacy = GroupAttachment(
      kind: 'image',
      dataB64: 'dGh1bWI=',
      w: 16,
      h: 9,
      cid: 'a' * 64,
      name: 'cover.webp',
    );
    final MediaObject reference = MediaObject(
      kind: 'image',
      contentId: 'a' * 64,
      width: 16,
      height: 9,
      name: 'cover.webp',
    );

    expect(legacy, isA<MediaObject>());
    expect(reference, isA<MediaObject>());
    expect(legacy.contentId, reference.contentId);
    expect(legacy.width, reference.width);
  });

  test('explicit codecs preserve legacy wire and strict reference JSON', () {
    final media = MediaObject(
      kind: 'image',
      contentId: 'b' * 64,
      inlinePreviewB64: 'cHJldmlldw==',
      name: 'photo.webp',
      mimeType: 'image/webp',
      size: 77,
      width: 4,
      height: 3,
    );

    expect(media.toLegacyAttachmentCanonical(), {
      'k': 'image',
      'd': 'cHJldmlldw==',
      'w': 4,
      'h': 3,
      'cid': 'b' * 64,
      'n': 'photo.webp',
    });
    expect(media.toReferenceJson(), {
      'cid': 'b' * 64,
      'kind': 'image',
      'name': 'photo.webp',
      'mime': 'image/webp',
      'size': 77,
      'width': 4,
      'height': 3,
    });
    expect(
      MediaObject.fromLegacyAttachmentJson(
        media.toLegacyAttachmentCanonical(),
      )?.dataB64,
      'cHJldmlldw==',
    );
    expect(
      MediaObject.fromReferenceJson(media.toReferenceJson())?.contentId,
      'b' * 64,
    );
    expect(
      GroupAttachment.fromJson(media.toLegacyAttachmentCanonical())?.dataB64,
      'cHJldmlldw==',
    );
    expect(
      MediaObject.fromJson(media.toReferenceJson())?.contentId,
      'b' * 64,
    );
  });

  test('legacy compatibility never weakens new reference validation', () {
    expect(
      MediaObject.fromLegacyAttachmentJson({
        'k': 'image',
        'd': 'QQ==',
        'w': 1,
        'h': 1,
        'cid': 'legacy-non-hash',
      }),
      isNotNull,
    );
    expect(
      MediaObject.fromReferenceJson({
        'kind': 'image',
        'cid': 'legacy-non-hash',
      }),
      isNull,
    );
    expect(
      MediaObject.fromReferenceJson({
        'kind': 'image',
        'cid': 'c' * 64,
        'size': 0,
      }),
      isNull,
    );
  });
}
