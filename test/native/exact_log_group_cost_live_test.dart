import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;

import 'package:xveil/data/storage/hv_native.dart';

// Optional persistent synthetic fixture allows separate library processes to
// measure A/B/A on the very same container. Timings are evidence, not assertions.
void main() {
  test(
    'bounded native log groups return exact bytes on a reusable fixture',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final supplied = Platform.environment['LOG_GROUP_COST_FIXTURE'];
      final dir = supplied == null
          ? await Directory.systemTemp.createTemp('xv-index-cost-')
          : await Directory(supplied).create(recursive: true);
      if (supplied == null) addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/synthetic.hv';
      final password = Uint8List.fromList(utf8.encode('synthetic-index-cost'));
      final fresh = !await File(path).exists();
      final space = fresh
          ? hv.HvSpace.create(
              path: path,
              password: password,
              argon: hv.ArgonPreset.light,
            )
          : hv.HvSpace.open(path: path, password: password);
      addTearDown(space.close);
      final samples = <String, Object>{};
      for (final dense in [true, false]) {
        final random = Random(42);
        final ns = dense ? 3 : 4;
        final records = [
          for (var i = 0; i < 32; i++)
            Uint8List.fromList(
              List.generate(
                2048,
                (j) => dense ? (j + i) % 251 : random.nextInt(256),
              ),
            ),
        ];
        if (fresh) {
          space.commit([
            for (var i = 0; i < records.length; i++)
              hv.HvWriteOpAppendLog(
                namespace: ns,
                logId: i + 1,
                payload: records[i],
              ),
          ]);
        }
        final groups = [
          for (var start = 1; start <= 32; start += 4)
            hv.HvLogReadGroup(
              logIds: [for (var i = start; i < start + 4; i++) i],
              maxBytes: 8192,
            ),
        ];
        final expected = [
          for (var start = 0; start < 32; start += 4)
            Uint8List.fromList([
              for (var i = start; i < start + 4; i++) ...records[i],
            ]),
        ];
        for (var warm = 0; warm < 5; warm++) {
          expect(space.readLogGroups(ns, groups), expected);
        }
        var us = 0;
        for (var pass = 0; pass < 100; pass++) {
          final watch = Stopwatch()..start();
          final actual = space.readLogGroups(ns, groups);
          us += watch.elapsedMicroseconds;
          expect(actual, expected);
        }
        samples[dense ? 'dense' : 'random'] = {'passes': 100, 'us': us};
        expect(
          space.readLogGroups(ns, [
            hv.HvLogReadGroup(logIds: [32, 1, 32], maxBytes: 6144),
          ]),
          [
            Uint8List.fromList([...records[31], ...records[0], ...records[31]]),
          ],
        );
        expect(
          space.readLogGroups(ns, [
            hv.HvLogReadGroup(logIds: [999, 1], maxBytes: 4096),
          ]),
          isNull,
        );
        expect(
          space.readLogGroups(ns, [
            hv.HvLogReadGroup(logIds: [1], maxBytes: 2047),
          ]),
          isNull,
        );
      }
      final evidence = Platform.environment['LOG_GROUP_COST_EVIDENCE'];
      if (evidence != null) {
        await File(evidence).writeAsString(
          jsonEncode({
            'schema': 'xveil-native-group-cost/1',
            'samples': samples,
          }),
        );
      }
    },
    skip: (Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false)
        ? false
        : 'set XVEIL_HV_DYLIB',
  );
}
