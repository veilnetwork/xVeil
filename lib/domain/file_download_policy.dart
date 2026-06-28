/// Per-identity policy for INCOMING files: which ones auto-download silently vs.
/// surface as an OFFER the user must accept before any bytes transfer (anti-spam
/// + disk control, Phase A1). Stored in the identity's OWN storage, so each
/// identity (and each decoy) carries an independent policy.
///
/// Defaults err toward safety: a 2 MiB auto cap and a block list of executable /
/// installer types that should never land on the device unbidden. A peer can
/// always SEND a file; this only decides whether it downloads automatically or
/// waits for the user's tap.
class FileDownloadPolicy {
  const FileDownloadPolicy({
    required this.autoMaxBytes,
    required this.blockedExts,
  });

  /// Files up to this size auto-download; anything larger is OFFERED. `0` ⇒ offer
  /// EVERYTHING (always ask) — the strictest anti-spam setting.
  final int autoMaxBytes;

  /// Lowercased extensions (no dot) NEVER auto-downloaded regardless of size —
  /// always offered, so a peer can't push an executable onto the device unbidden.
  final Set<String> blockedExts;

  static const int defaultAutoMaxBytes = 2 * 1024 * 1024;
  static const Set<String> defaultBlockedExts = {
    'apk', 'exe', 'dmg', 'msi', 'bat', 'cmd', 'com', 'sh', 'scr', 'jar', 'deb',
    'app', 'pkg', 'ps1',
  };

  /// The safe default applied to a fresh identity (and whenever the stored policy
  /// is missing or unparseable).
  static const FileDownloadPolicy defaults = FileDownloadPolicy(
    autoMaxBytes: defaultAutoMaxBytes,
    blockedExts: defaultBlockedExts,
  );

  /// True iff an incoming file of [size] bytes named [name] may auto-download
  /// under this policy — small enough AND not a blocked type. A null/over-cap
  /// size, or a blocked extension, returns false ⇒ the file is offered instead.
  bool allowsAuto(int? size, String? name) {
    if (size == null || size > autoMaxBytes) return false;
    final ext = extensionOf(name);
    return ext == null || !blockedExts.contains(ext);
  }

  /// The lowercased extension of [name] (no leading dot), or null if it has none.
  static String? extensionOf(String? name) {
    if (name == null) return null;
    final dot = name.lastIndexOf('.');
    return (dot >= 0 && dot < name.length - 1)
        ? name.substring(dot + 1).toLowerCase()
        : null;
  }

  /// Normalize a user-typed extension to the stored form (lowercase, no leading
  /// dot, trimmed). Returns null if it reduces to nothing.
  static String? normalizeExt(String raw) {
    var e = raw.trim().toLowerCase();
    while (e.startsWith('.')) {
      e = e.substring(1);
    }
    return e.isEmpty ? null : e;
  }

  FileDownloadPolicy copyWith({int? autoMaxBytes, Set<String>? blockedExts}) =>
      FileDownloadPolicy(
        autoMaxBytes: autoMaxBytes ?? this.autoMaxBytes,
        blockedExts: blockedExts ?? this.blockedExts,
      );

  Map<String, dynamic> toJson() => {
        'max': autoMaxBytes,
        'block': blockedExts.toList()..sort(),
      };

  /// Parse a stored policy, falling back to the defaults for any missing or
  /// wrong-typed field (never throws — a corrupt blob degrades to the safe
  /// default, not an open one). An explicit EMPTY block list is honored (the user
  /// cleared it); only a missing/non-list field reverts to the default list.
  factory FileDownloadPolicy.fromJson(Map<String, dynamic> j) {
    final max = j['max'];
    final block = j['block'];
    return FileDownloadPolicy(
      autoMaxBytes: max is num ? max.toInt() : defaultAutoMaxBytes,
      blockedExts: block is List
          ? block
              .map((e) => normalizeExt(e.toString()))
              .whereType<String>()
              .toSet()
          : defaultBlockedExts,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FileDownloadPolicy &&
      other.autoMaxBytes == autoMaxBytes &&
      other.blockedExts.length == blockedExts.length &&
      other.blockedExts.containsAll(blockedExts);

  @override
  int get hashCode => Object.hash(
      autoMaxBytes, Object.hashAllUnordered(blockedExts));
}
