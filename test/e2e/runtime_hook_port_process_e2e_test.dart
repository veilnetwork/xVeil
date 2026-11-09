@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'device_process_fixture.dart';
import 'e2e_env.dart';

// Run this explicit native gate alone: the cache witness assumes no other
// Flutter invocation is compiling tests in this checkout at the same time.
void main() {
  final gate = E2eGate.read();
  test(
    'workers share a kernel cache across distinct runtime hook ports',
    () async {
      Set<String> kernels() {
        final root = Directory('build/test_cache/build');
        expect(
          root.existsSync(),
          isTrue,
          reason: 'observe the actual default test cache',
        );
        return root
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.dill'))
            .map((f) => f.path)
            .toSet();
      }

      final before = kernels();
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      final devices = [fleet.a, fleet.b, fleet.c];
      expect(devices.map((d) => d.port).toSet(), hasLength(3));
      for (final device in devices) {
        expect((await device.checked('/health'))['realStack'], isTrue);
        final client = HttpClient();
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${device.port}/health'),
          );
          final response = await request.close();
          expect(response.statusCode, HttpStatus.unauthorized);
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }
      }
      if (Platform.environment['XVEIL_E2E_NATIVE_MAPPING_GATE'] == '1') {
        expect(evidence, isNotNull);
        await waitUntil(
          () => File('$evidence/native-mappings-ready').exists(),
          what:
              'external observer maps the selected native libraries in three workers',
          timeout: const Duration(seconds: 30),
        );
      }
      final first = kernels();
      expect(
        first.difference(before).length,
        lessThanOrEqualTo(1),
        reason: 'ports must not create three compiler configurations',
      );
      final oldPort = fleet.a.port;
      await fleet.a.stop();
      final reserved = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        oldPort,
      );
      try {
        await fleet.a.start();
        expect(fleet.a.port, isNot(oldPort));
        expect((await fleet.a.checked('/health'))['realStack'], isTrue);
      } finally {
        await reserved.close();
      }
      final after = kernels();
      expect(
        after.difference(first),
        isEmpty,
        reason: 'a newly selected port uses the same cache key',
      );
      if (evidence != null) {
        await File('$evidence/cache-port-result.json').writeAsString(
          jsonEncode({
            'passed': true,
            'independentWorkers': 3,
            'workerRestarts': 1,
            'unauthenticatedRejected': 3,
            'runtimePortsDistinct': true,
            'restartPortChanged': true,
            'newWorkerKernelEntries': first.difference(before).length,
            'newKernelEntriesAfterRestart': after.difference(first).length,
          }),
        );
      }
    },
    skip: gate.skip,
  );
}
