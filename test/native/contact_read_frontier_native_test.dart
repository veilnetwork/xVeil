@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';
import 'package:xveil/domain/chat.dart';

import '../support/timed_native_store.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));
Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

class _Probe extends TimedNativeStore {
  _Probe(super.inner, super.clock, super.observe, this.sharing);
  final bool sharing;
  @override
  int? get requestFrontier => sharing ? super.requestFrontier : null;
}

Future<Uint8List> _seed(String path, String password, String name) async {
  final storage = HiddenVolumeStorage(
    hvSpaceOpener(path, argon: hv.ArgonPreset.min),
  );
  await storage.open(password: password, createIfMissing: true);
  try {
    for (var i = 1; i <= 16; i++) {
      await storage.upsertContact(Contact(nodeId: _id(i), name: '$name-$i'));
    }
    return await storage.exportSpaceKeys();
  } finally {
    await storage.close();
  }
}

void main() {
  final nativePath = Platform.environment['XVEIL_HV_DYLIB'];
  final skip = nativePath == null || nativePath.isEmpty;
  setUp(() {
    expect(ensureHiddenVolumeLoaded(dylibPath: nativePath), isTrue);
  });

  test(
    'single-space frontier advances synchronously at every queued command',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'xv-contact-frontier-',
      );
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/store.hv';
      await _seed(path, 'fixture', 'original');
      final worker = (await workerSpaceOpener(path)(
        password: _bytes('fixture'),
        create: false,
      ))!;
      expect(worker, isA<WorkerKvLogStore>());
      final store = worker as WorkerKvLogStore;
      var frontier = store.requestFrontier;
      Future<void> command(Future<dynamic> Function() run) async {
        final result = run();
        expect(store.requestFrontier, ++frontier);
        await result;
      }

      try {
        await command(() => store.get(Ns.contacts, _id(1).bytes));
        await command(() => store.getBatch(Ns.contacts, [_id(1).bytes]));
        await command(
          () => store.commit([
            PutOp(Ns.settings, _bytes('probe'), _bytes('value')),
          ]),
        );
        await command(() => store.count(Ns.contacts));
        await command(() => store.exportKeys());
        await store.getBatch(Ns.contacts, []);
        expect(
          store.requestFrontier,
          frontier,
          reason: 'empty batch sends no command',
        );
      } finally {
        final closed = store.close();
        expect(store.requestFrontier, frontier + 1);
        await closed;
      }
    },
    skip: skip,
  );

  test(
    'shared worker frontier covers commands in every identity view',
    () async {
      final root = await Directory.systemTemp.createTemp('xv-contact-spaces-');
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/store.hv';
      final first = await _seed(path, 'first fixture', 'first');
      final second = await _seed(path, 'second fixture', 'second');
      final backing = WorkerMultiSpaceBacking(path);
      try {
        final a = AsyncMultiSpaceKvLogStore(
          backing,
          await backing.openSpace(first),
        );
        final b = AsyncMultiSpaceKvLogStore(
          backing,
          await backing.openSpace(second),
        );
        final sa = HiddenVolumeStorage.fromAsyncStore(a);
        final sb = HiddenVolumeStorage.fromAsyncStore(b);
        final old = backing.requestFrontier;
        final readA = sa.getContact(_id(1));
        expect(backing.requestFrontier, old + 1);
        final readB = sb.getContact(_id(1));
        expect(backing.requestFrontier, old + 2);
        expect((await readA)?.name, 'first-1');
        expect((await readB)?.name, 'second-1');
        final before = backing.requestFrontier;
        final get = a.get(Ns.contacts, _id(1).bytes);
        expect(backing.requestFrontier, before + 1);
        final write = b.commit([
          PutOp(Ns.settings, _bytes('probe'), _bytes('value')),
        ]);
        expect(a.requestFrontier, before + 2);
        expect(b.requestFrontier, before + 2);
        await Future.wait([get, write]);
      } finally {
        final before = backing.requestFrontier;
        final closed = backing.close();
        expect(backing.requestFrontier, before + 1);
        await closed;
      }
    },
    skip: skip,
  );

  test(
    'native A/B/A uses identical contact bytes with fewer parallel RPCs',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'xv-contact-read-aba-',
      );
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/store.hv';
      await _seed(path, 'fixture', 'contact');
      final digest = sha256.convert(await File(path).readAsBytes()).toString();
      final results = <String, Object>{};
      for (final phase in ['A1', 'B', 'A2']) {
        final worker = (await workerSpaceOpener(path)(
          password: _bytes('fixture'),
          create: false,
        ))!;
        expect(worker, isA<WorkerKvLogStore>());
        var recording = false, reads = 0;
        final probe = _Probe(worker, Stopwatch()..start(), (event) {
          if (recording && event['operation'] == 'kv.get') reads++;
        }, phase == 'B');
        final storage = HiddenVolumeStorage.fromAsyncStore(probe);
        try {
          final groups = <String, Object>{};
          for (final distinct in [false, true]) {
            final elapsed = <int>[];
            reads = 0;
            for (var wave = 0; wave < 66; wave++) {
              recording = wave >= 2;
              final watch = Stopwatch()..start();
              final values = await Future.wait([
                for (var i = 0; i < 16; i++)
                  storage.getContact(_id(distinct ? i + 1 : 1)),
              ]);
              watch.stop();
              for (var i = 0; i < values.length; i++) {
                expect(values[i]?.name, 'contact-${distinct ? i + 1 : 1}');
              }
              if (recording) elapsed.add(watch.elapsedMicroseconds);
            }
            recording = false;
            final expected = phase == 'B' && !distinct ? 64 : 1024;
            expect(reads, expected);
            elapsed.sort();
            groups[distinct ? 'differentContacts' : 'sameContact'] = {
              'waves': 64,
              'readersPerWave': 16,
              'rpc': reads,
              'medianUs': elapsed[elapsed.length ~/ 2],
              'totalUs': elapsed.fold<int>(0, (a, b) => a + b),
            };
          }
          results[phase] = groups;
        } finally {
          await storage.close();
        }
        expect(
          sha256.convert(await File(path).readAsBytes()).toString(),
          digest,
        );
      }
      final output = Platform.environment['XVEIL_CONTACT_READ_FRONTIER_RESULT'];
      if (output != null) await File(output).writeAsString(jsonEncode(results));
    },
    skip: skip,
  );
}
