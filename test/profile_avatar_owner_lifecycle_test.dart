import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:image/image.dart' as image;
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/async_tasks.dart';
import 'package:xveil/core/log.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/profile_avatar.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

final _peer = NodeId(Uint8List(32)..fillRange(0, 32, 2));

Uint8List _picture(int color) {
  final pixels = image.Image(width: 32, height: 32);
  image.fill(pixels, color: image.ColorRgb8(color, 90, 255 - color));
  return encodeAvatarPixels(image.encodePng(pixels))!;
}

final _first = ProfileAvatar(10, _picture(30)).encode();
final _second = ProfileAvatar(20, _picture(210)).encode();
final _replacementBytes = _picture(120);
final _replacement = ProfileAvatar(30, _replacementBytes).encode();

class _HeldStorage extends HiddenVolumeStorage {
  _HeldStorage(super.open);
  _HeldStorage.async(super.open) : super.async();

  int profileReads = 0, selfReads = 0, profileWrites = 0;
  int? holdSelfRead;
  String? holdPeerRead;
  bool holdWrittenReply = false;
  final entered = Completer<void>(), release = Completer<void>();

  Future<void> _wait() async {
    entered.complete();
    await release.future;
  }

  @override
  Future<String?> getSetting(String key) async {
    if (key.startsWith('profile.avatar:')) profileReads++;
    final value = await super.getSetting(key);
    if (key == kSelfAvatarSetting) {
      selfReads++;
      if (selfReads == holdSelfRead) {
        holdSelfRead = null;
        await _wait();
      }
    } else if (key == holdPeerRead) {
      holdPeerRead = null;
      await _wait();
    }
    return value;
  }

  @override
  Future<void> putSetting(String key, String value) async {
    if (key.startsWith('profile.avatar:')) profileWrites++;
    await super.putSetting(key, value);
    // The real write has completed. Only its reply to the caller is held.
    if (key == kSelfAvatarSetting && holdWrittenReply) {
      holdWrittenReply = false;
      await _wait();
    }
  }
}

class _Fixture {
  _Fixture(this.storage, this.messaging, this.wire, this.directory);
  final _HeldStorage storage;
  final MessagingService messaging;
  final LoopbackTransport wire;
  final Directory directory;

  Future<void> switchAfterDispose() async {
    await messaging.dispose();
    await storage.close();
    expect(await storage.open(password: 'second-fixture'), isTrue);
  }

  Future<void> verifyBoth(String first) async {
    await storage.close();
    expect(await storage.open(password: 'first-fixture'), isTrue);
    expect(await storage.getSetting(kSelfAvatarSetting), first);
    await storage.close();
    expect(await storage.open(password: 'second-fixture'), isTrue);
    expect(await storage.getSetting(kSelfAvatarSetting), _second);
  }

  Future<void> close() async {
    if (!storage.release.isCompleted) storage.release.complete();
    await messaging.dispose();
    await wire.dispose();
    await storage.close();
    devLogDirectoryOverride = null;
    await directory.delete(recursive: true);
  }
}

Future<_Fixture> _fixture(bool native) async {
  final directory = await Directory.systemTemp.createTemp(
    'xveil-avatar-owner-',
  );
  devLogDirectoryOverride = directory.path;
  late _HeldStorage storage;
  if (native) {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    final path = '${directory.path}/store.hv';
    HvKvLogStore(
      hv.HvSpace.create(
        path: path,
        password: Uint8List.fromList(utf8.encode('first-fixture')),
        argon: hv.ArgonPreset.min,
      ),
    ).close();
    storage = _HeldStorage.async(workerSpaceOpener(path));
  } else {
    final backing = FakeHvContainer();
    storage = _HeldStorage(backing.passwordOpener);
  }
  final wire = LoopbackTransport();
  final result = _Fixture(
    storage,
    MessagingService(wire, storage),
    wire,
    directory,
  );
  addTearDown(result.close);
  for (final entry in {
    'first-fixture': _first,
    'second-fixture': _second,
  }.entries) {
    expect(
      await storage.open(password: entry.key, createIfMissing: true),
      isTrue,
    );
    await storage.putSetting(kSelfAvatarSetting, entry.value);
    await storage.putSetting(peerAvatarSetting(_peer.hex), entry.value);
    await storage.close();
  }
  expect(await storage.open(password: 'first-fixture'), isTrue);
  storage.selfReads = 0;
  return result;
}

Future<Object?> _observe<T>(Future<T> operation) async {
  try {
    await operation;
    return null;
  } catch (error) {
    return error;
  }
}

Future<Object?> _readResult(Future<String?> operation) =>
    operation.then<Object?>((value) => value, onError: (Object error) => error);

void main() {
  for (final native in [
    false,
    if (Platform.environment['XVEIL_AVATAR_NATIVE'] == '1') true,
  ]) {
    group(native ? 'native worker' : 'controlled store', () {
      for (final edit in [
        'apply',
        'same',
        'set-first-read',
        'set-second-read',
      ]) {
        test('a paused $edit cannot adopt the replacement space', () async {
          final f = await _fixture(native);
          f.storage.holdSelfRead = edit == 'set-second-read' ? 2 : 1;
          final pending = _observe(
            edit.startsWith('set-')
                ? f.messaging.setSelfAvatar(_replacementBytes)
                : f.messaging.applySelfAvatar(
                    edit == 'same' ? _first : _replacement,
                  ),
          );
          await f.storage.entered.future;
          await f.switchAfterDispose();
          f.storage.release.complete();
          final error = await pending;
          expect(await f.storage.getSetting(kSelfAvatarSetting), _second);
          expect(error, isA<StateError>());
          await f.verifyBoth(_first);
        });
      }

      for (final peer in [false, true]) {
        test('a paused load releases no data after close peer=$peer', () async {
          final f = await _fixture(native);
          if (peer) {
            f.storage.holdPeerRead = peerAvatarSetting(_peer.hex);
          } else {
            f.storage.holdSelfRead = 1;
          }
          final pending = _readResult(
            f.messaging.loadAvatar(peer: peer ? _peer : null),
          );
          await f.storage.entered.future;
          await f.switchAfterDispose();
          f.storage.release.complete();
          expect(await pending, isNull);
          await f.verifyBoth(_first);
        });
      }

      for (final operation in ['load-self', 'load-peer', 'apply', 'set']) {
        test(
          'a closed $operation never accesses the replacement space',
          () async {
            final f = await _fixture(native);
            await f.switchAfterDispose();
            final reads = f.storage.profileReads,
                writes = f.storage.profileWrites;
            final reading = operation.startsWith('load-');
            final outcome = reading
                ? await _readResult(
                    f.messaging.loadAvatar(
                      peer: operation == 'load-peer' ? _peer : null,
                    ),
                  )
                : await _observe(
                    operation == 'apply'
                        ? f.messaging.applySelfAvatar(_replacement)
                        : f.messaging.setSelfAvatar(_replacementBytes),
                  );
            expect(f.storage.profileReads, reads);
            expect(f.storage.profileWrites, writes);
            expect(await f.storage.getSetting(kSelfAvatarSetting), _second);
            expect(outcome, reading ? isNull : isA<StateError>());
            await f.verifyBoth(_first);
          },
        );
      }

      test(
        'an owned background read does not fail ordinary shutdown',
        () async {
          final f = await _fixture(native);
          final tasks = AsyncTasks();
          final closingScope = Completer<void>();
          f.messaging.registerShutdownTask(() {
            closingScope.complete();
            return tasks.close();
          });
          final values = <String>[];
          f.storage.holdSelfRead = 1;
          final reading = _observe(
            tasks.run(() async {
              final raw = await f.messaging.loadAvatar();
              if (raw != null) values.add(raw);
            }),
          );
          await f.storage.entered.future;
          final closing = _observe(f.messaging.dispose());
          await closingScope.future;
          f.storage.release.complete();
          expect(await reading, isNull);
          expect(await closing, isNull);
          expect(values, isEmpty);
          await f.switchAfterDispose();
          await f.verifyBoth(_first);
        },
      );

      test(
        'a completed write stays in its original space across a late reply',
        () async {
          final f = await _fixture(native);
          f.storage.holdWrittenReply = true;
          final pending = _observe(f.messaging.applySelfAvatar(_replacement));
          await f.storage.entered.future;
          expect(await f.storage.getSetting(kSelfAvatarSetting), _replacement);
          await f.switchAfterDispose();
          f.storage.release.complete();
          expect(await pending, isNull);
          await f.verifyBoth(_replacement);
        },
      );
    });
  }
}
