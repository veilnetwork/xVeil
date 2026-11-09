import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/stand_cpu_profile.dart';

void main() {
  test('private endpoint witness refuses an uninitialized profiler', () async {
    final dir = await Directory.systemTemp.createTemp('private-cpu-witness-');
    final file = File('${dir.path}/endpoint.json');
    final profiler = StandCpuProfile();
    try {
      await expectLater(profiler.writeEndpointWitness(file), throwsStateError);
      expect(await file.exists(), isFalse);
      expect(await File('${file.path}.new').exists(), isFalse);
    } finally {
      profiler.close();
      await dir.delete(recursive: true);
    }
  });

  test(
    'private endpoint witness binds to the live local VM and updates atomically',
    () async {
      final dir = await Directory.systemTemp.createTemp('private-cpu-witness-');
      final file = File('${dir.path}/endpoint.json');
      final profiler = StandCpuProfile();
      try {
        await profiler.reset();
        await profiler.writeEndpointWitness(file);
        final first = jsonDecode(await file.readAsString()) as Map;
        expect(first['schema'], 'xveil-private-cpu-endpoint/1');
        expect(first['pid'], pid);
        final uri = Uri.parse(first['uri'] as String);
        expect(uri.scheme, 'http');
        expect(uri.host, '127.0.0.1');
        expect(uri.port, greaterThan(0));
        expect((await profiler.request('getVM'))['pid'], first['pid']);
        await profiler.reset();
        await profiler.writeEndpointWitness(file);
        final second = jsonDecode(await file.readAsString()) as Map;
        expect(second['pid'], first['pid']);
        expect(second['uri'], first['uri']);
        expect(
          second['originMicros'] as int,
          greaterThanOrEqualTo(first['originMicros'] as int),
        );
        expect(await File('${file.path}.new').exists(), isFalse);
      } finally {
        profiler.close();
        await dir.delete(recursive: true);
      }
    },
    // Flutter's default test runner disables the VM service. Match the opt-in
    // native profiler check; run explicitly with --enable-vmservice as well.
    skip: Platform.environment['XVEIL_E2E_CPU_PROFILE'] != '1',
  );
}
