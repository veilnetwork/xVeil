/// The most a whole IMAGE may be read into RAM to be shown inline.
///
/// Inline rendering decodes the file entire, and the decoded bitmap costs
/// several times the file on top of it — so this is the number that decides
/// whether a picture someone else sent can push the app out of memory. Above
/// it the thumb and the download affordance stand in, which is what they are
/// for.
///
/// It belongs to the DOMAIN rather than to one screen because both screens that
/// render a stored image need the same answer, and one of them had no ceiling
/// at all while the other's was defeated by an omitted size (audit report8).
const int kInlineImageMaxBytes = 24 * 1024 * 1024;

/// One domain description for user-visible media carried by messages,
/// publications and the content store.
///
/// The bytes are still owned by the existing content path. [contentId] points
/// at those bytes; [inlinePreviewB64] is only the legacy inline payload or a
/// bounded preview. Two explicit codecs below preserve the two existing wire
/// contracts without keeping two competing domain models.
class MediaObject {
  const MediaObject({
    required this.kind,
    String? contentId,
    String? cid,
    this.name,
    this.mimeType,
    this.size,
    int? width,
    int? height,
    this.durationMs,
    String? inlinePreviewB64,
    String? dataB64,
    int? w,
    int? h,
  }) : assert(contentId == null || cid == null || contentId == cid),
       contentId = contentId ?? cid,
       width = width ?? w,
       height = height ?? h,
       inlinePreviewB64 = inlinePreviewB64 ?? dataB64;

  final String kind;
  final String? contentId;
  final String? name;
  final String? mimeType;
  final int? size;
  final int? width;
  final int? height;
  final int? durationMs;
  final String? inlinePreviewB64;

  /// Compatibility accessors for the signed legacy group-message shape.
  String? get cid => contentId;
  String get dataB64 => inlinePreviewB64 ?? '';
  int get w => width ?? 0;
  int get h => height ?? 0;

  /// Strict shape used by Space posts and every new content-path reference.
  bool get isReferenceStructurallyValid =>
      contentId != null &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(contentId!) &&
      kind.isNotEmpty &&
      kind.length <= 32 &&
      (name == null || name!.length <= 255) &&
      (mimeType == null || mimeType!.length <= 128) &&
      (size == null || size! > 0) &&
      (width == null || width! > 0) &&
      (height == null || height! > 0) &&
      (durationMs == null || durationMs! >= 0);

  /// Compatibility spelling used by existing Space-post validation.
  bool get isStructurallyValid => isReferenceStructurallyValid;

  /// Historical group rows may contain the whole bounded payload and may
  /// predate SHA-256 content ids. Keep their validator byte-compatible; new
  /// producers should use a real [contentId] whenever full bytes are external.
  bool get isLegacyAttachmentStructurallyValid =>
      kind.isNotEmpty &&
      dataB64.isNotEmpty &&
      w > 0 &&
      h > 0 &&
      (contentId == null || contentId!.isNotEmpty) &&
      (name == null || name!.isNotEmpty);

  Map<String, dynamic> toReferenceJson() => {
    'cid': contentId,
    'kind': kind,
    if (name != null) 'name': name,
    if (mimeType != null) 'mime': mimeType,
    if (size != null) 'size': size,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (durationMs != null) 'duration': durationMs,
  };

  /// Compatibility JSON dispatcher. New signing code always calls the
  /// explicit codec; this method keeps old `GroupAttachment.toJson()` callers
  /// on the legacy shape and old `MediaObject.toJson()` callers on the
  /// reference shape.
  Map<String, dynamic> toJson() => inlinePreviewB64 == null
      ? toReferenceJson()
      : toLegacyAttachmentCanonical();

  Map<String, dynamic> toLegacyAttachmentCanonical() => {
    'k': kind,
    'd': dataB64,
    'w': w,
    'h': h,
    if (contentId != null) 'cid': contentId,
    if (name != null) 'n': name,
  };

  /// Historical `GroupAttachment` spelling.
  Map<String, dynamic> toCanonical() => toLegacyAttachmentCanonical();

  static MediaObject? fromReferenceJson(Object? value) {
    if (value is! Map || value['cid'] is! String || value['kind'] is! String) {
      return null;
    }
    final media = MediaObject(
      contentId: value['cid'] as String,
      kind: value['kind'] as String,
      name: value['name'] is String ? value['name'] as String : null,
      mimeType: value['mime'] is String ? value['mime'] as String : null,
      size: value['size'] is int ? value['size'] as int : null,
      width: value['width'] is int ? value['width'] as int : null,
      height: value['height'] is int ? value['height'] as int : null,
      durationMs: value['duration'] is int ? value['duration'] as int : null,
    );
    return media.isReferenceStructurallyValid ? media : null;
  }

  /// Compatibility parser for both historical aliases. Explicit consumers use
  /// one of the two shape-specific methods above/below.
  static MediaObject? fromJson(Object? value) =>
      value is Map &&
          (value.containsKey('k') ||
              value.containsKey('d') ||
              value.containsKey('w') ||
              value.containsKey('h'))
      ? fromLegacyAttachmentJson(value)
      : fromReferenceJson(value);

  static MediaObject? fromLegacyAttachmentJson(Object? value) {
    if (value is! Map) return null;
    final kind = value['k'];
    final data = value['d'];
    final width = value['w'];
    final height = value['h'];
    if (kind is! String || data is! String || width is! int || height is! int) {
      return null;
    }
    final cid = value['cid'];
    final name = value['n'];
    final media = MediaObject(
      kind: kind,
      dataB64: data,
      w: width,
      h: height,
      cid: cid is String && cid.isNotEmpty ? cid : null,
      name: name is String && name.isNotEmpty ? name : null,
    );
    return media.isLegacyAttachmentStructurallyValid ? media : null;
  }
}

/// Source-compatible names while downstream code migrates to [MediaObject].
/// They are aliases, not additional runtime/domain entities.
typedef GroupAttachment = MediaObject;

