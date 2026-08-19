// The deployment keys must not be readable in the source of a public
// repository.
//
// This exists because they were. The production obfs4 pre-shared key was
// generated on 2026-06-18 and pasted into test/node_provisioner_test.dart on
// 2026-06-19 as a fixture, where it stayed for two months of public commits.
// It shipped in every release binary too — a PSK bundled with the app was
// never a secret against anyone who downloads the app — but a value sitting in
// plain text in the repository is available to someone who never bothered to,
// and it is the difference between "the transport is unrecognisable to a
// passive observer" and "it is not".
//
// The check runs against the asset rather than against a hardcoded string,
// deliberately: a test that spelled out the value it forbids would publish it
// again, in the file whose whole purpose is to stop that.
//
// The assets are gitignored, so they are absent in a clean clone and present
// on a developer machine and in the release job that writes them from a
// secret. Absence is not treated as a pass in silence — see the second group.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Directories whose contents are published as source. `build/`, `.dart_tool/`
/// and the submodules are excluded: they hold generated or vendored trees, and
/// walking them would make this test slow enough to be turned off.
const _searchedDirs = <String>[
  'lib',
  'test',
  'scripts',
  'tool',
  '.github',
  'android',
  'ios',
  'macos',
  'linux',
  'windows',
  'doc',
];

/// Files that are the key itself, and the one place allowed to name it.
bool _isTheAssetItself(String path) =>
    path.endsWith('assets/prod/obfs4_psk.b64') ||
    path.endsWith('assets/testnet/obfs4_psk.b64');

Iterable<File> _sourceFiles() sync* {
  for (final name in _searchedDirs) {
    final dir = Directory(name);
    if (!dir.existsSync()) continue;
    for (final entry in dir.listSync(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      final path = entry.path;
      if (path.contains('/build/') ||
          path.contains('/.dart_tool/') ||
          path.contains('/ephemeral/') ||
          path.contains('/Pods/')) {
        continue;
      }
      if (_isTheAssetItself(path)) continue;
      yield entry;
    }
  }
}

/// Reads a file as text, or returns null when it is not text. A binary that
/// carries a key is a real leak, but that is the artifact scanner's job
/// (scripts/scan-artifacts.py) and it runs on what is built, not on what is
/// committed; nothing binary is committed here.
String? _asText(File f) {
  try {
    final bytes = f.readAsBytesSync();
    if (bytes.contains(0)) return null;
    return utf8.decode(bytes, allowMalformed: true);
  } on FileSystemException {
    return null;
  }
}

void main() {
  final psks = <String, String>{};
  for (final entry in <String, String>{
    'production': 'assets/prod/obfs4_psk.b64',
    'testnet': 'assets/testnet/obfs4_psk.b64',
  }.entries) {
    final f = File(entry.value);
    if (!f.existsSync()) continue;
    final value = f.readAsStringSync().trim();
    if (value.isNotEmpty) psks[entry.key] = value;
  }

  group('no deployment key is readable in the source', () {
    for (final network in const ['production', 'testnet']) {
      test('the $network obfs4 PSK appears in no source file', () {
        final psk = psks[network];
        if (psk == null) {
          // A clean clone cannot run this check — it does not hold the value
          // to look for. Saying so out loud rather than passing quietly: a
          // green that knows nothing is how the original paste survived two
          // months of a full suite.
          markTestSkipped(
            'assets/${network == 'production' ? 'prod' : 'testnet'}/'
            'obfs4_psk.b64 is absent, so this clone cannot check for it. '
            'It IS checked wherever the key exists: a developer machine and '
            'the release job.',
          );
          return;
        }
        final offenders = <String>[];
        for (final file in _sourceFiles()) {
          final text = _asText(file);
          if (text == null) continue;
          if (text.contains(psk)) offenders.add(file.path);
        }
        expect(
          offenders,
          isEmpty,
          reason:
              'these files carry the $network obfs4 pre-shared key in plain '
              'text, and this repository is public. Replace the value with a '
              'fixture — any valid base64 works — and rotate the key, because '
              'anything already pushed is already out.',
        );
      });
    }
  });

  group('the provisioner fixtures say what they are', () {
    // The half that works in a clean clone. It does not know the real key, so
    // it asserts the opposite property: that the value standing in the
    // provisioner tests decodes to text that announces itself as a fixture.
    // Replacing it with a real key would take the marker away.
    const marker = 'test-fixture-psk-not-real-value!';

    for (final path in const [
      'test/node_provisioner_test.dart',
      'test/provision_script_hardening_test.dart',
    ]) {
      test('$path uses the self-describing fixture PSK', () {
        final text = File(path).readAsStringSync();
        final encoded = base64.encode(utf8.encode(marker));
        expect(
          text,
          contains(encoded),
          reason:
              'the obfs4 PSK fixture in this file is no longer the '
              'self-describing one. If it was replaced with a deployment key, '
              'that key is now public.',
        );
      });
    }
  });
}
