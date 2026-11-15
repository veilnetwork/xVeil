import 'dart:convert';
import 'dart:io';

/// Profile-local hidden source binding, never an arbitrary recovery pathname.
/// The leaf may be kept inside an authenticated private intent; it is not an
/// entry in the public catalog and ordinary opens do not probe its existence.
abstract final class LegacyCompactionSource {
  static const defaultName = 'xveil.store';

  static String validateName(String value) {
    if (value.isEmpty ||
        value.length > 1024 ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains(r'\') ||
        value.contains(':') ||
        value.endsWith('.') ||
        value.endsWith(' ') ||
        value.codeUnits.any((c) => c < 32 || c == 127)) {
      throw const FormatException('invalid legacy source binding');
    }
    final encoded = utf8.encode(value);
    if (encoded.length > 1024 || utf8.decode(encoded) != value) {
      throw const FormatException('invalid legacy source binding');
    }
    return value;
  }

  static String path(String profileDirectory, String sourceName) {
    validateName(sourceName);
    final directory = Directory(profileDirectory).absolute.parent;
    // Resolve an encoded single segment: #, %, ? and Unicode are literal file
    // names, not a fragment, an escape sequence or a different URI authority.
    return File.fromUri(
      directory.uri.resolveUri(Uri(pathSegments: [sourceName])),
    ).path;
  }

  static String nameForPath(String profileDirectory, String legacyPath) {
    if (legacyPath.isEmpty ||
        legacyPath.contains('\x00') ||
        !File(legacyPath).isAbsolute) {
      throw const FormatException('invalid legacy source binding');
    }
    final file = File.fromUri(File(legacyPath).absolute.uri.normalizePath());
    final parent = Directory(
      profileDirectory,
    ).absolute.parent.uri.normalizePath();
    if (file.parent.absolute.uri.normalizePath() != parent) {
      throw const FormatException('invalid legacy source binding');
    }
    final name = validateName(file.uri.pathSegments.last);
    if (File(path(profileDirectory, name)).absolute.uri.normalizePath() !=
        file.uri.normalizePath()) {
      throw const FormatException('invalid legacy source binding');
    }
    return name;
  }
}
