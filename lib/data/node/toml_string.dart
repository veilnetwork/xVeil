/// Rendering a value into the node's TOML config.
///
/// The config is composed by veil and then amended here, line by line, because
/// a few keys are decided by the app after the node has serialised its own.
/// Those amendments were built by string interpolation — `key = "$value"` —
/// and a TOML basic string is not a place to put a value verbatim: inside one,
/// a backslash BEGINS AN ESCAPE.
///
/// On Windows every path is full of them. The runtime directory is handed to
/// the node as `identity_dir`, and
/// `C:\Users\User\AppData\Local\Temp\xveil-rt-18156` was read as `\U` — the
/// start of an eight-digit unicode escape — so the node refused its own
/// config with `too few unicode value digits` and never started. Measured on
/// Windows 11 with 0.13.0; the same shape reaches `obfs4_psk_file`.
library;

/// [value] as a TOML basic string, quotes included.
///
/// Basic rather than literal (`'…'`) on purpose: a literal string cannot
/// contain a single quote or a newline at all, and a Windows account named
/// `O'Brien` is a real directory. Escaping covers everything, and a value with
/// nothing to escape renders exactly as it did before — which is why this can
/// be applied to every amended key rather than only to the paths.
String tomlBasicString(String value) {
  final out = StringBuffer('"');
  for (final unit in value.runes) {
    switch (unit) {
      case 0x08:
        out.write(r'\b');
      case 0x09:
        out.write(r'\t');
      case 0x0A:
        out.write(r'\n');
      case 0x0C:
        out.write(r'\f');
      case 0x0D:
        out.write(r'\r');
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      default:
        // The rest of the C0 range and DEL have no short form and are not
        // allowed raw. Everything else — including every non-ASCII letter —
        // is written as itself: TOML is UTF-8, and escaping it would only
        // make the config unreadable.
        if (unit < 0x20 || unit == 0x7F) {
          out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.writeCharCode(unit);
        }
    }
  }
  out.write('"');
  return out.toString();
}
