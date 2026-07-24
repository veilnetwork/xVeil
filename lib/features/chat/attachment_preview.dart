// Unified one-line attachment previews (chat list, notifications, reply
// quotes, pinned bars) — the SINGLE place a message's attachment turns into
// human-readable text.
//
// Voice notes, video notes and stickers travel the content path under OPAQUE
// generated container names (`<uuid>.opus` / `<uuid>.vnote` / `<uuid>.stkr`,
// see messaging_content_publish.dart), so every surface that echoed the file
// name (or the stored `📎 <name>` body) leaked a technical uuid instead of a
// kind label. DISPLAY-ONLY: the stored message body and the wire format keep
// the raw name — only derived previews go through here.

import '../../domain/chat.dart';
import '../../domain/group_message.dart';
import '../../domain/media_file_name.dart';
import '../../l10n/app_localizations.dart';
import '../../state/sticker_message.dart';
import '../../state/vnote_message.dart';
import '../../state/voice_message.dart';

/// What an attachment previews as. Derived from an explicit media [kind]
/// (group/space attachments) or from the file name's extension (1:1 file
/// messages, which carry no kind on the wire).
enum AttachmentPreviewKind { voice, vnote, sticker, image, video, file }

final RegExp _uuidStem = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final RegExp _hexBlob = RegExp(r'^[0-9a-fA-F]{32,64}$');

/// True when [name] reads as an opaque generated container name — a uuid v4
/// stem or a bare content-hash, with or without an extension — rather than a
/// user-meaningful file name. Such a name must never surface in a preview.
bool isOpaqueAttachmentName(String? name) {
  final n = name?.trim();
  if (n == null || n.isEmpty) return true;
  final dot = n.lastIndexOf('.');
  final stem = dot > 0 ? n.substring(0, dot) : n;
  return _uuidStem.hasMatch(stem) || _hexBlob.hasMatch(stem);
}

/// Resolve the preview kind: an explicit media [kind] wins (group/space
/// attachments), otherwise the [name]'s extension decides (1:1 messages).
AttachmentPreviewKind attachmentPreviewKind({String? kind, String? name}) {
  switch (kind) {
    case 'voice':
      return AttachmentPreviewKind.voice;
    case 'vnote':
      return AttachmentPreviewKind.vnote;
    case 'sticker':
      return AttachmentPreviewKind.sticker;
    case 'image':
      return AttachmentPreviewKind.image;
    case 'video':
      return AttachmentPreviewKind.video;
  }
  if (isVoiceFileName(name)) return AttachmentPreviewKind.voice;
  if (isVnoteFileName(name)) return AttachmentPreviewKind.vnote;
  if (isStickerFileName(name)) return AttachmentPreviewKind.sticker;
  if (isImageFileName(name)) return AttachmentPreviewKind.image;
  if (isVideoFileName(name)) return AttachmentPreviewKind.video;
  return AttachmentPreviewKind.file;
}

/// The localized one-line preview for one attachment. Voice/video notes show
/// their kind label (never the container name) plus the clip length when it is
/// already at hand; photos/videos/stickers show their kind label; a plain file
/// keeps its human name — unless the name is opaque ([isOpaqueAttachmentName]),
/// then the generic file label renders instead of a uuid.
String attachmentPreviewText(
  AppL10n l, {
  String? kind,
  String? name,
  Duration? duration,
}) {
  final clip = (duration != null && duration > Duration.zero)
      ? ' (${formatVoiceDuration(duration)})'
      : '';
  switch (attachmentPreviewKind(kind: kind, name: name)) {
    case AttachmentPreviewKind.voice:
      return '🎤 ${l.chatVoiceTooltip}$clip';
    case AttachmentPreviewKind.vnote:
      return '📹 ${l.chatVnoteTooltip}$clip';
    case AttachmentPreviewKind.sticker:
      return '😊 ${l.attachmentPreviewSticker}';
    case AttachmentPreviewKind.image:
      return '📷 ${l.attachmentPreviewPhoto}';
    case AttachmentPreviewKind.video:
      return '🎬 ${l.attachmentPreviewVideo}';
    case AttachmentPreviewKind.file:
      final n = name?.trim();
      return (n == null || n.isEmpty || isOpaqueAttachmentName(n))
          ? '📎 ${l.chatFileLabel}'
          : '📎 $n';
  }
}

/// Clip length carried by a 1:1 `thumb` sidecar (`vw1:` voice / `vn1:` vnote),
/// or null for image thumbs / absent sidecars. Cheap: string parse only.
Duration? sidecarDuration(String? thumb) =>
    decodeVoiceSidecar(thumb)?.duration ?? decodeVnoteSidecar(thumb)?.duration;

/// Preview of a 1:1 [Message]: text keeps its body; a file message (offered or
/// downloaded) renders through [attachmentPreviewText] so an opaque container
/// name never surfaces. The `thumb` sidecar supplies voice/vnote durations.
String messagePreviewText(AppL10n l, Message m) {
  if (!m.isFile) return m.body;
  return attachmentPreviewText(
    l,
    name: m.fileName,
    duration: sidecarDuration(m.thumb),
  );
}

Duration? _mediaDuration(MediaObject a) {
  final ms =
      a.durationMs ??
      // Legacy group voice/vnote rows parked the clip length in `width`
      // (with height == 1) before MediaObject grew `durationMs`.
      ((a.kind == 'voice' || a.kind == 'vnote') && (a.height ?? 0) <= 1
          ? a.width
          : null);
  return (ms != null && ms > 0) ? Duration(milliseconds: ms) : null;
}

/// Preview of a group/space [GroupMessage]: a non-empty body wins, an
/// attachment renders through [attachmentPreviewText], and a message with
/// neither keeps the historical ellipsis placeholder.
String groupMessagePreviewText(AppL10n l, GroupMessage m) {
  if (m.body.isNotEmpty) return m.body;
  final a = m.attachment;
  if (a == null) return '…';
  return attachmentPreviewText(
    l,
    kind: a.kind,
    name: a.name,
    duration: _mediaDuration(a),
  );
}
