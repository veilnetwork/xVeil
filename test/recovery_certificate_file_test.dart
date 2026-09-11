// The certificate may be written to a file. The code that unlocks it may not.
//
// Together they ARE the identity: the certificate holds the master material
// (including the Falcon half, which the 24 words cannot reproduce) and the
// code decrypts it. That is precisely why the certificate is allowed to leave
// the device at all — it is useless alone. A backup file that carried both
// would be a backup of the whole capability, and would be the one artifact an
// attacker needs.
//
// The saving code lives inside a widget's State, so this is a source guard
// rather than an execution one: what it watches is that the writer never
// reaches for the code.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the certificate writer never puts the code in the file', () {
    final src = File('lib/features/settings/devices_screen.dart')
        .readAsStringSync();
    final start = src.indexOf('Future<void> _saveCertificateToFile() async {');
    expect(start, isNot(-1), reason: 'the writer was renamed or removed');
    // To the end of that method, by matching braces. Cutting at "the next
    // member" is what a first version did, and it silently swept the whole
    // rest of the file into the body — the guard then failed on code it was
    // never meant to read.
    final open = src.indexOf('{', start);
    var depth = 0;
    var end = src.length;
    for (var i = open; i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') {
        depth--;
        if (depth == 0) {
          end = i + 1;
          break;
        }
      }
    }
    final body = src.substring(start, end);

    final offenders = body
        .split('\n')
        .map((l) => l.trim())
        .where((l) => !l.startsWith('//'))
        .where((l) => l.contains('_code'))
        .toList();
    expect(
      offenders,
      isEmpty,
      reason:
          'the certificate file must not contain the unlock code — the two '
          'are a pair kept apart, and a file holding both is the identity:\n'
          '${offenders.join('\n')}',
    );

    // And it must still actually write the certificate, or the guard above is
    // watching an empty method.
    expect(
      body.contains('writeAsString(certificate'),
      isTrue,
      reason: 'the writer no longer writes the certificate',
    );
  });
}
