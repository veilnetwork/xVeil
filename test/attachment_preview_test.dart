// Unified attachment previews: voice/video notes and stickers travel under
// opaque `<uuid>.<ext>` container names — the derived preview (chat list,
// notifications, reply quotes) must show a human kind label, never the uuid.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/features/chat/attachment_preview.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/vnote_message.dart';
import 'package:xveil/state/voice_message.dart';

const String _uuid = '3f2b8a54-9c1d-4e7f-8a2b-6d5c4e3f2a1b';

Message _msg({
  String body = '',
  String? fileName,
  String? thumb,
  String? fileId = 'cid',
}) => Message(
  id: 'm1',
  conversationId: 'conv',
  direction: MessageDirection.incoming,
  body: body,
  timestamp: DateTime.fromMillisecondsSinceEpoch(0),
  fileId: fileId,
  fileName: fileName,
  thumb: thumb,
);

GroupMessage _groupMsg({String body = '', MediaObject? attachment}) =>
    GroupMessage(
      groupId: NodeId(Uint8List.fromList(List.filled(32, 1))),
      author: NodeId(Uint8List.fromList(List.filled(32, 2))),
      seq: 1,
      prevHash: '',
      body: body,
      policyVersion: 1,
      createdAtMs: 1000,
      signature: Uint8List(64),
      attachment: attachment,
    );

void main() {
  final en = lookupAppL10n(const Locale('en'));
  final ru = lookupAppL10n(const Locale('ru'));

  group('isOpaqueAttachmentName', () {
    test('uuid stems and hex blobs are opaque, human names are not', () {
      expect(isOpaqueAttachmentName('$_uuid.opus'), isTrue);
      expect(isOpaqueAttachmentName('$_uuid.vnote'), isTrue);
      expect(isOpaqueAttachmentName(_uuid), isTrue);
      expect(isOpaqueAttachmentName('a' * 64), isTrue); // bare content hash
      expect(isOpaqueAttachmentName(null), isTrue);
      expect(isOpaqueAttachmentName(''), isTrue);
      expect(isOpaqueAttachmentName('report.pdf'), isFalse);
      expect(isOpaqueAttachmentName('Отчёт за июль.docx'), isFalse);
    });
  });

  group('attachmentPreviewText (1:1 Message)', () {
    test('voice note → kind label + duration, never the uuid', () {
      final preview = messagePreviewText(
        en,
        _msg(
          body: '📎 $_uuid.opus',
          fileName: '$_uuid.opus',
          thumb: encodeVoiceSidecar(7000, List.filled(48, 0.5), lang: 'en'),
        ),
      );
      expect(preview, '🎤 ${en.chatVoiceTooltip} (0:07)');
      expect(preview.contains(_uuid), isFalse);
    });

    test('video note → kind label + duration, never the uuid', () {
      final preview = messagePreviewText(
        en,
        _msg(
          body: '📎 $_uuid.vnote',
          fileName: '$_uuid.vnote',
          thumb: encodeVnoteSidecar(65000, null),
        ),
      );
      expect(preview, '📹 ${en.chatVnoteTooltip} (1:05)');
      expect(preview.contains(_uuid), isFalse);
    });

    test('voice note without a sidecar still hides the uuid', () {
      expect(
        messagePreviewText(en, _msg(fileName: '$_uuid.opus')),
        '🎤 ${en.chatVoiceTooltip}',
      );
    });

    test('sticker → sticker label, never the uuid', () {
      final preview = messagePreviewText(en, _msg(fileName: '$_uuid.stkr'));
      expect(preview, '😊 ${en.attachmentPreviewSticker}');
      expect(preview.contains(_uuid), isFalse);
    });

    test('image / video → kind labels', () {
      expect(
        messagePreviewText(en, _msg(fileName: 'cat.jpg')),
        '📷 ${en.attachmentPreviewPhoto}',
      );
      expect(
        messagePreviewText(en, _msg(fileName: 'movie.mp4')),
        '🎬 ${en.attachmentPreviewVideo}',
      );
    });

    test('file with a human name keeps it: 📎 name', () {
      expect(messagePreviewText(en, _msg(fileName: 'report.pdf')), '📎 report.pdf');
    });

    test('file with an opaque name falls back to the generic file label', () {
      expect(
        messagePreviewText(en, _msg(fileName: '$_uuid.bin')),
        '📎 ${en.chatFileLabel}',
      );
      expect(
        messagePreviewText(en, _msg(fileName: null)),
        '📎 ${en.chatFileLabel}',
      );
    });

    test('offered-not-downloaded file (contentId only) also previews', () {
      final m = Message(
        id: 'm2',
        conversationId: 'conv',
        direction: MessageDirection.incoming,
        body: '📎 $_uuid.opus',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        fileContentId: 'c' * 64,
        fileName: '$_uuid.opus',
      );
      expect(messagePreviewText(en, m), '🎤 ${en.chatVoiceTooltip}');
    });

    test('plain text message keeps its body', () {
      expect(
        messagePreviewText(en, _msg(body: 'привет', fileId: null)),
        'привет',
      );
    });

    test('russian labels come from the ru arb', () {
      expect(
        messagePreviewText(ru, _msg(fileName: '$_uuid.opus')),
        '🎤 Голосовое сообщение',
      );
      expect(
        messagePreviewText(ru, _msg(fileName: '$_uuid.vnote')),
        '📹 Видео-сообщение',
      );
      expect(
        messagePreviewText(ru, _msg(fileName: 'cat.jpg')),
        '📷 Фото',
      );
    });
  });

  group('groupMessagePreviewText (GroupMessage)', () {
    test('body wins when present', () {
      expect(groupMessagePreviewText(en, _groupMsg(body: 'hello')), 'hello');
    });

    test('voice attachment → label + duration from durationMs', () {
      final preview = groupMessagePreviewText(
        en,
        _groupMsg(
          attachment: MediaObject(
            kind: 'voice',
            contentId: 'a' * 64,
            name: 'voice.vop1',
            durationMs: 7000,
          ),
        ),
      );
      expect(preview, '🎤 ${en.chatVoiceTooltip} (0:07)');
    });

    test('legacy voice attachment parks the duration in width', () {
      final preview = groupMessagePreviewText(
        en,
        _groupMsg(
          attachment: MediaObject(
            kind: 'voice',
            contentId: 'a' * 64,
            width: 8000,
            height: 1,
          ),
        ),
      );
      expect(preview, '🎤 ${en.chatVoiceTooltip} (0:08)');
    });

    test('vnote attachment → kind label, never the container name', () {
      final preview = groupMessagePreviewText(
        en,
        _groupMsg(
          attachment: MediaObject(
            kind: 'vnote',
            contentId: 'a' * 64,
            name: 'vnote.vn01',
            durationMs: 5000,
          ),
        ),
      );
      expect(preview, '📹 ${en.chatVnoteTooltip} (0:05)');
      expect(preview.contains('vn01'), isFalse);
    });

    test('image attachment ignores pixel width as a duration', () {
      expect(
        groupMessagePreviewText(
          en,
          _groupMsg(
            attachment: MediaObject(
              kind: 'image',
              contentId: 'a' * 64,
              width: 1280,
              height: 720,
            ),
          ),
        ),
        '📷 ${en.attachmentPreviewPhoto}',
      );
    });

    test('file attachment keeps a human name, hides an opaque one', () {
      expect(
        groupMessagePreviewText(
          en,
          _groupMsg(
            attachment: MediaObject(
              kind: 'file',
              contentId: 'a' * 64,
              name: 'report.pdf',
            ),
          ),
        ),
        '📎 report.pdf',
      );
      expect(
        groupMessagePreviewText(
          en,
          _groupMsg(
            attachment: MediaObject(kind: 'file', contentId: 'a' * 64),
          ),
        ),
        '📎 ${en.chatFileLabel}',
      );
    });

    test('no body, no attachment → historical ellipsis', () {
      expect(groupMessagePreviewText(en, _groupMsg()), '…');
    });
  });
}
