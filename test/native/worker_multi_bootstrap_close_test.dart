@Timeout(Duration(seconds: 30))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';

void main() {
  test(
    'an explicit native bootstrap refusal has no backing to retire',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final fixture = Directory.systemTemp.createTempSync(
        'xveil-multi-open-refusal-',
      );
      final file = File('${fixture.path}/absent.hv');
      final backing = WorkerMultiSpaceBacking(file.path);
      try {
        await expectLater(
          backing.openSpace(Uint8List(64)),
          throwsA(isA<hv.HvException>()),
        );
        await backing.close();
        await backing.close();
        expect(file.existsSync(), isFalse);
        expect(fixture.listSync(), isEmpty);
      } finally {
        await backing.close();
        fixture.deleteSync(recursive: true);
      }
    },
  );
}
