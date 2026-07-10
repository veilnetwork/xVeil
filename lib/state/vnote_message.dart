// Video-note (round message) domain helpers — the voice_message.dart twin.
//
// A video note travels the CONTENT path as a small `.vnote` file (the VNOTE1
// container, see veil_media). Its duration + a first-frame micro-thumb ride
// the SAME `thumb` sidecar images use, tagged `vn1:`, so nothing new crosses
// the wire and the receiver renders the round bubble BEFORE downloading.

/// File extension a video note is sent under (drives the bubble choice).
const String kVnoteFileExt = '.vnote';

/// Tag distinguishing a video-note sidecar from an image thumb / voice `vw1:`.
const String kVnoteSidecarPrefix = 'vn1:';

bool isVnoteFileName(String? name) {
  if (name == null) return false;
  return name.toLowerCase().endsWith(kVnoteFileExt);
}

/// Decoded `vn1:` sidecar: the clip duration and an optional base64 PNG
/// micro-thumb of the first frame (empty on a capture that produced none).
class VnoteSidecar {
  const VnoteSidecar({required this.durationMs, this.thumbB64});

  final int durationMs;
  final String? thumbB64;

  Duration get duration => Duration(milliseconds: durationMs);
}

/// `vn1:<durMs>:<b64 png>` (the thumb part may be empty).
String encodeVnoteSidecar(int durationMs, String? thumbB64) =>
    '$kVnoteSidecarPrefix${durationMs < 0 ? 0 : durationMs}:${thumbB64 ?? ''}';

/// Decode a sidecar written by [encodeVnoteSidecar]; null when [s] is not a
/// vnote sidecar or is malformed (never throws — the field is peer-supplied).
VnoteSidecar? decodeVnoteSidecar(String? s) {
  if (s == null || !s.startsWith(kVnoteSidecarPrefix)) return null;
  final rest = s.substring(kVnoteSidecarPrefix.length);
  final sep = rest.indexOf(':');
  if (sep < 0) return null;
  final dur = int.tryParse(rest.substring(0, sep));
  if (dur == null || dur < 0) return null;
  final thumb = rest.substring(sep + 1);
  return VnoteSidecar(durationMs: dur, thumbB64: thumb.isEmpty ? null : thumb);
}
