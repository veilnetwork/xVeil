import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/state/cloud_capability_service.dart';
import 'package:xveil/state/cloud_service.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/device_sync.dart';

class _ReadGate extends HiddenVolumeStorage {
  _ReadGate()
    : super(({required password, required create}) => FakeKvLogStore());
  final entered = Completer<void>(), release = Completer<void>();
  int reads = 0;
  Future<void> _gate() async {
    reads++;
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
  }

  @override
  Future<String?> getSetting(String key) async {
    await _gate();
    return super.getSetting(key);
  }

  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) async {
    await _gate();
    return super.loadFile(fileId, maxBytes: maxBytes);
  }
}

class _Sync extends Fake implements CloudSyncPort {
  int closes = 0;
  @override
  Future<void> close() async => closes++;
}

class _WriteGate extends HiddenVolumeStorage {
  _WriteGate()
    : super(({required password, required create}) => FakeKvLogStore());
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> putSetting(String key, String value) async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.putSetting(key, value);
  }
}

class _LocalSync extends _Sync {
  @override
  NodeId get selfId => NodeId(Uint8List(32)..fillRange(0, 32, 1));
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<List<DeviceSyncRecord>> records() async => [];
  @override
  Future<List<NodeId>> members() async => [];
  @override
  void vouchForContent(Future<Set<String>> Function() ids) {}
}

class _Network extends Fake implements CloudCapabilityNetworkPort {}

void main() {
  test(
    'cloud close joins initial reconciliation writes after local load',
    () async {
      final storage = _WriteGate();
      await storage.open(password: 'synthetic', createIfMissing: true);
      final sync = _LocalSync();
      final cloud = CloudService(
        storage,
        sync,
        contentReceived: const Stream.empty(),
        integrityChecks: false,
      );
      final starting = cloud.start();
      await storage.entered.future;
      final closing = cloud.close();
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      try {
        await Future<void>.delayed(Duration.zero);
        expect(
          closed,
          isFalse,
          reason: 'initial view publication still owns storage',
        );
        expect(sync.closes, 0);
      } finally {
        storage.release.complete();
        await starting;
        await closing;
        await storage.close();
      }
    },
  );

  for (final capability in [false, true]) {
    test(
      '${capability ? 'capability' : 'cloud'} close joins accepted startup reads',
      () async {
        final storage = _ReadGate();
        await storage.open(password: 'synthetic', createIfMissing: true);
        final sync = _Sync();
        final received = StreamController<String>.broadcast();
        final cloud = capability
            ? null
            : CloudService(
                storage,
                sync,
                contentReceived: received.stream,
                integrityChecks: false,
              );
        final caps = capability
            ? CloudCapabilityService(storage, _Network())
            : null;
        Future<void> start() => cloud?.start() ?? caps!.start();
        Future<void> close() => cloud?.close() ?? caps!.close();
        addTearDown(() async {
          if (!storage.release.isCompleted) storage.release.complete();
          await close();
          await received.close();
          await storage.close();
        });
        final starting = start();
        await storage.entered.future;
        final closing = close();
        var settled = false;
        unawaited(closing.then((_) => settled = true));
        try {
          expect(
            close(),
            same(closing),
            reason: 'a second closer must join, not report early success',
          );
          // Drain these adapters' microtasks; there is no millisecond bound.
          await Future<void>.delayed(Duration.zero);
          expect(settled, isFalse);
          if (!capability) expect(sync.closes, 0);
        } finally {
          storage.release.complete();
        }
        await starting;
        await closing;
        expect(settled, isTrue);
        final reads = storage.reads;
        await storage.close();
        await expectLater(
          start(),
          capability ? throwsStateError : throwsA(isA<CloudServiceClosed>()),
        );
        expect(
          storage.reads,
          reads,
          reason: 'a closed service cannot start another read',
        );
        await received.close();
      },
    );
  }
}
