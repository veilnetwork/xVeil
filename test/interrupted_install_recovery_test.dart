// A power loss between the two renames of a model replace must not cost the
// model.
//
// `installBundle` moves the old pair out to `.replacing-<id>` and the new one
// in. Interrupted in between, the old pair is complete and working under a
// name nothing looks for: `refresh` lists only `xx-yy` directories, so the
// pair reads as uninstalled — and the next install deleted that directory
// before trying, so a second failure left the person with neither version.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/translation_model_store.dart' show kPairFiles;
import 'package:xveil/data/veil_bundle.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('xveil-models'));
  tearDown(() => root.deleteSync(recursive: true));

  Directory pair(String name) {
    final d = Directory('${root.path}/$name')..createSync(recursive: true);
    for (final f in kPairFiles) {
      File('${d.path}/$f').writeAsStringSync('x');
    }
    return d;
  }

  test('an install interrupted between its renames is put back', () {
    // Exactly what a crash leaves: the old pair aside, no destination.
    final aside = pair('.replacing-en-ru');

    final restored = recoverInterruptedInstalls(root);

    expect(restored, ['en-ru']);
    expect(Directory('${root.path}/en-ru').existsSync(), isTrue);
    expect(aside.existsSync(), isFalse);
    for (final f in kPairFiles) {
      expect(
        File('${root.path}/en-ru/$f').existsSync(),
        isTrue,
        reason: 'the model has to come back whole, not as a name',
      );
    }
  });

  test('debris from a FINISHED replace is left for the next install', () {
    // Destination present: the replace completed and the leftover is rubbish.
    // Moving it back here would overwrite the newer model with the older one.
    pair('en-ru');
    pair('.replacing-en-ru');

    expect(recoverInterruptedInstalls(root), isEmpty);
    expect(
      Directory('${root.path}/.replacing-en-ru').existsSync(),
      isTrue,
      reason: 'not deleted here either — that is the next install\'s job, and '
          'this runs on a read path',
    );
  });

  test('nothing else in the models root is touched', () {
    pair('fr-de');
    Directory('${root.path}/.incoming-en-ru').createSync();

    expect(recoverInterruptedInstalls(root), isEmpty);
    expect(Directory('${root.path}/fr-de').existsSync(), isTrue);
    expect(Directory('${root.path}/.incoming-en-ru').existsSync(), isTrue);
  });
}
