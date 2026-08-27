import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/toml_string.dart';

/// A Windows path in the node's config.
///
/// The app amends veil's rendered config line by line, and those lines used to
/// be built by interpolation — `identity_dir = "$dir"`. A TOML basic string is
/// not a place for a value verbatim: a backslash inside one BEGINS AN ESCAPE.
///
/// Measured on Windows 11 with 0.13.0. The runtime directory
/// `C:\Users\User\AppData\Local\Temp\xveil-rt-18156\rt-514f8567` reached the
/// node as `\U` — the start of an eight-digit unicode escape — and the node
/// refused its own config:
///
///   TOML parse error at line 4, column 21
///   too few unicode value digits, expected unicode hexadecimal value
///
/// The node never started, so the app showed "deniable node did not connect"
/// on every launch. Every Windows account is under `C:\Users`, so this was not
/// an edge case there: it was the only case.
///
/// The check here reads the rendered value BACK, with a decoder written to
/// TOML's rules rather than to the encoder's — an unknown escape and a short
/// `\u`/`\U` both throw, exactly as the node's parser rejected them.
void main() {
  const windowsRuntimeDir =
      r'C:\Users\User\AppData\Local\Temp\xveil-rt-18156\rt-514f8567';

  group('a rendered value survives the trip back', () {
    for (final value in <String>[
      windowsRuntimeDir,
      r'C:\Users\User\AppData\Roaming\xveil\obfs4_psk.b64',
      // Not hypothetical: Windows account names carry both.
      r"C:\Users\O'Brien\AppData\Local\Temp\rt-1",
      r'C:\Users\Пользователь\AppData\Local\Temp\rt-2',
      // The escapes a naive encoder gets wrong in the other direction.
      r'C:\temp\new\table\form"quoted"',
      '/run/xveil/rt-abc',
      'tcp://127.0.0.1:9000',
    ]) {
      test('round trip: $value', () {
        expect(_decodeTomlBasicString(tomlBasicString(value)), value);
      });
    }
  });

  test('the identity directory reaches the node as itself', () {
    final out = EmbeddedNode.withIdentityDir(
      '[global]\nlog_level = "info"\n',
      windowsRuntimeDir,
    );

    expect(_valueOf(out, 'identity_dir'), windowsRuntimeDir);
  });

  test('and so does the obfs4 key file', () {
    final out = EmbeddedNode.withObfs4PskFile(
      '[transport]\n',
      r'C:\Users\User\AppData\Roaming\xveil\obfs4_psk.b64',
    );

    expect(
      _valueOf(out, 'obfs4_psk_file'),
      r'C:\Users\User\AppData\Roaming\xveil\obfs4_psk.b64',
    );
  });

  test('a bootstrap peer with nothing to escape renders as it always did', () {
    // The escaping must be invisible for ordinary values, or every config in
    // the field changes shape for a Windows-only defect.
    final out = EmbeddedNode.withBootstrapPeers('', [
      BootstrapPeerCfg(
        transport: 'tcp://203.0.113.1:5556',
        publicKey: 'ab' * 32,
        nonce: '01' * 8,
        algo: 'x25519',
      ),
    ]);

    expect(out, contains('transport = "tcp://203.0.113.1:5556"'));
    expect(out, contains('algo = "x25519"'));
  });
}

/// The value of [key] in [toml], decoded — or a throw, the way the node's
/// parser answers a malformed escape.
String _valueOf(String toml, String key) {
  final line = toml
      .split('\n')
      .firstWhere(
        (l) => l.trimLeft().startsWith('$key '),
        orElse: () => throw StateError('no $key in:\n$toml'),
      );
  return _decodeTomlBasicString(line.substring(line.indexOf('=') + 1).trim());
}

/// A TOML basic string, decoded to the value it denotes.
///
/// Written to the specification rather than to [tomlBasicString], so it cannot
/// agree with the encoder by sharing its mistakes: an unrecognised escape and
/// a short `\u`/`\U` are errors here for the same reason they are errors in
/// the node.
String _decodeTomlBasicString(String raw) {
  if (raw.length < 2 || !raw.startsWith('"') || !raw.endsWith('"')) {
    throw FormatException('not a basic string: $raw');
  }
  final body = raw.substring(1, raw.length - 1);
  final out = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (c != r'\') {
      if (c.codeUnitAt(0) < 0x20 || c.codeUnitAt(0) == 0x7F) {
        throw FormatException('raw control character in a basic string: $raw');
      }
      out.write(c);
      continue;
    }
    if (++i >= body.length) throw FormatException('trailing backslash: $raw');
    switch (body[i]) {
      case 'b':
        out.writeCharCode(0x08);
      case 't':
        out.writeCharCode(0x09);
      case 'n':
        out.writeCharCode(0x0A);
      case 'f':
        out.writeCharCode(0x0C);
      case 'r':
        out.writeCharCode(0x0D);
      case '"':
        out.write('"');
      case r'\':
        out.write(r'\');
      case 'u':
        out.writeCharCode(_hex(body, i + 1, 4, raw));
        i += 4;
      case 'U':
        out.writeCharCode(_hex(body, i + 1, 8, raw));
        i += 8;
      default:
        throw FormatException('invalid escape \\${body[i]} in: $raw');
    }
  }
  return out.toString();
}

int _hex(String body, int at, int digits, String raw) {
  if (at + digits > body.length) {
    // The node's own words for this: "too few unicode value digits".
    throw FormatException('too few unicode value digits in: $raw');
  }
  final text = body.substring(at, at + digits);
  final value = int.tryParse(text, radix: 16);
  if (value == null) {
    throw FormatException('expected unicode hexadecimal value in: $raw');
  }
  return value;
}
