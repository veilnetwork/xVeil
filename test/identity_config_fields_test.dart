// What an invite is made of, read out of a config.
//
// A restored device runs on a node key of its own and collects mail under the
// IDENTITY's address. The address a contact writes down is the hash of the key
// in the invite — so an invite carrying the device's key has contacts
// addressing somewhere nobody listens, and nothing ever arrives. The invite is
// therefore built from the phrase-derived config kept beside the running one,
// and this is the reader.
//
// Null beats a partial answer everywhere below: an invite missing its nonce is
// not a weaker invite, it is one the other side refuses, and the caller has a
// correct fallback that a half-built one would silently replace.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/identity_config_fields.dart';

String _config({
  String section = 'Identity',
  String? pk = 'GVz6btatwlarmJiJRb5ZbMNPUbqXm11aJGi5aq277cc=',
  String? nonce = 'AGubDg==',
  String? algo = 'ed25519',
}) {
  final b = StringBuffer('[global]\nlog_level = "info"\n\n[$section]\n');
  if (algo != null) b.writeln('algo = "$algo"');
  if (pk != null) b.writeln('public_key = "$pk"');
  b.writeln('private_key = "5v3cIjcufmHescw5orQF9RXl4NNJLlt5Z6JvOJ3lxHg="');
  if (nonce != null) b.writeln('nonce = "$nonce"');
  b.writeln('\n[mobile]\nlow_battery_multiplier = 0');
  return b.toString();
}

void main() {
  test('reads the key, the nonce and the algorithm', () {
    final f = identityConfigFields(_config())!;
    expect(f.algo, 'ed25519');
    expect(
      base64.encode(f.publicKey),
      'GVz6btatwlarmJiJRb5ZbMNPUbqXm11aJGi5aq277cc=',
    );
    expect(base64.encode(f.nonce), 'AGubDg==');
    expect(f.publicKey, hasLength(32));
  });

  // veil composes `[Identity]`; a hand-written config says `[identity]`. To a
  // TOML reader they are the same section, so they are the same section here.
  test('either spelling of the section header', () {
    expect(identityConfigFields(_config(section: 'identity')), isNotNull);
    expect(identityConfigFields(_config(section: 'Identity')), isNotNull);
  });

  test('a config with no identity section has nothing to give', () {
    expect(identityConfigFields('[global]\nlog_level = "info"\n'), isNull);
  });

  test('a missing field is not a partial answer', () {
    expect(identityConfigFields(_config(nonce: null)), isNull);
    expect(identityConfigFields(_config(pk: null)), isNull);
    expect(identityConfigFields(_config(algo: null)), isNull);
  });

  test('an empty field is treated as missing', () {
    expect(identityConfigFields(_config(nonce: '')), isNull);
    expect(identityConfigFields(_config(pk: '')), isNull);
  });

  test('a value that is not base64 is refused', () {
    expect(identityConfigFields(_config(pk: '!!not base64!!')), isNull);
  });

  // THE ONE THAT MATTERS FOR CORRECTNESS. A key belonging to another table must
  // never be read as the identity's — that would hand out an invite naming
  // something else entirely.
  test('a public_key in another section is not read as the identity\'s', () {
    const toml = '''
[global]
log_level = "info"

[Identity]
algo = "ed25519"
private_key = "5v3cIjcufmHescw5orQF9RXl4NNJLlt5Z6JvOJ3lxHg="

[some_other_table]
public_key = "GVz6btatwlarmJiJRb5ZbMNPUbqXm11aJGi5aq277cc="
nonce = "AGubDg=="
''';
    expect(identityConfigFields(toml), isNull);
  });

  test('the identity section may be the last table in the file', () {
    const toml = '''
[global]
log_level = "info"

[Identity]
algo = "ed25519"
public_key = "GVz6btatwlarmJiJRb5ZbMNPUbqXm11aJGi5aq277cc="
nonce = "AGubDg=="
''';
    final f = identityConfigFields(toml);
    expect(f, isNotNull);
    expect(f!.nonce, isA<Uint8List>());
  });
}
