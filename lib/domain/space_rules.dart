import '../core/ids.dart';

/// One immutable, signed revision of the rules shown to Space members.
///
/// The object is carried inside a signed control-log entry. Author and publish
/// time are repeated here deliberately and must match the enclosing entry, so
/// API/UI projections never have to reconstruct security-relevant metadata
/// from an unrelated local record.
class SpaceRulesVersion {
  const SpaceRulesVersion({
    required this.version,
    required this.fullText,
    required this.summary,
    required this.author,
    required this.publishedAtMs,
    required this.effectiveAtMs,
    required this.previousVersion,
  });

  static const int maxFullTextLength = 64 * 1024;
  static const int maxSummaryLength = 4096;

  final int version;
  final String fullText;
  final String summary;
  final NodeId author;
  final int publishedAtMs;
  final int effectiveAtMs;
  final int? previousVersion;

  bool get isStructurallyValid {
    final normalizedText = fullText.trim();
    final normalizedSummary = summary.trim();
    return version >= 1 &&
        normalizedText.isNotEmpty &&
        normalizedText == fullText &&
        fullText.length <= maxFullTextLength &&
        normalizedSummary == summary &&
        summary.length <= maxSummaryLength &&
        publishedAtMs >= 0 &&
        effectiveAtMs >= publishedAtMs &&
        (version == 1
            ? previousVersion == null
            : previousVersion == version - 1);
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'fullText': fullText,
    'summary': summary,
    'author': author.hex,
    'publishedAt': publishedAtMs,
    'effectiveAt': effectiveAtMs,
    if (previousVersion != null) 'previousVersion': previousVersion,
  };

  static SpaceRulesVersion? fromJson(Object? value) {
    if (value is! Map ||
        value['version'] is! int ||
        value['fullText'] is! String ||
        value['summary'] is! String ||
        value['author'] is! String ||
        value['publishedAt'] is! int ||
        value['effectiveAt'] is! int) {
      return null;
    }
    try {
      final rules = SpaceRulesVersion(
        version: value['version'] as int,
        fullText: value['fullText'] as String,
        summary: value['summary'] as String,
        author: NodeId.fromHex(value['author'] as String),
        publishedAtMs: value['publishedAt'] as int,
        effectiveAtMs: value['effectiveAt'] as int,
        previousVersion: value['previousVersion'] as int?,
      );
      return rules.isStructurallyValid ? rules : null;
    } catch (_) {
      return null;
    }
  }
}

/// The latest rules revision acknowledged by one member.
class SpaceRulesAcceptance {
  const SpaceRulesAcceptance({
    required this.rulesVersion,
    required this.acceptedAtMs,
  });

  final int rulesVersion;
  final int acceptedAtMs;

  bool get isStructurallyValid => rulesVersion >= 1 && acceptedAtMs >= 0;

  Map<String, dynamic> toJson() => {
    'rulesVersion': rulesVersion,
    'acceptedAt': acceptedAtMs,
  };

  static SpaceRulesAcceptance? fromJson(Object? value) {
    if (value is! Map ||
        value['rulesVersion'] is! int ||
        value['acceptedAt'] is! int) {
      return null;
    }
    final acceptance = SpaceRulesAcceptance(
      rulesVersion: value['rulesVersion'] as int,
      acceptedAtMs: value['acceptedAt'] as int,
    );
    return acceptance.isStructurallyValid ? acceptance : null;
  }
}
