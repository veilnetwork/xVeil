@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));
const _secret = 'PRIVATE_ADMISSION_BODY';
const _clean = '{"g":[],"keep":"SAFE_ADMISSION_STATE"}';

class _Store extends HiddenVolumeStorage {
  _Store(super.opener);
  _Store.async(super.opener) : super.async();
  bool hold = false;
  final entered = Completer<void>(), release = Completer<void>();
  Future<void> _gate() async {
    if (!hold) return;
    hold = false;
    entered.complete();
    await release.future;
  }

  @override
  Future<void> enqueueOutboxFrame(
    String id,
    String peer,
    Uint8List wire,
  ) async {
    await super.enqueueOutboxFrame(id, peer, wire);
    await _gate();
  }

  @override
  Future<void> enqueueOutboxTransfer(List<OutboxFrame> frames) async {
    await super.enqueueOutboxTransfer(frames);
    await _gate();
  }
}

class _Link extends LoopbackTransport {
  _Link() : super(localNodeId: _id(1));
  bool leaked = false;
  final arrived = Completer<void>();
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final e = WireEnvelope.decode(payload);
    if (e.kind != WireKind.groupEntry && e.kind != WireKind.groupEntryChunk) {
      return;
    }
    final body = e.kind == WireKind.groupEntry
        ? e.body
        : utf8.decode(parseGroupEntryChunk(e.body).data, allowMalformed: true);
    leaked |= body.contains(_secret);
    if (!arrived.isCompleted) arrived.complete();
  }
}

void main() {
  for (final native in [false, true]) {
    for (final initial in [false, true]) {
      for (final chunked in [false, true]) {
        for (final mode in [
          'normal',
          if (!initial && chunked) ...['retry-failure', 'close', 'concurrent'],
        ]) {
          test(
            'device snapshot expiry after admission native=$native initial=$initial chunked=$chunked mode=$mode',
            () async {
              late _Store store;
              if (native) {
                expect(
                  ensureHiddenVolumeLoaded(
                    dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
                  ),
                  isTrue,
                );
                final dir = await Directory.systemTemp.createTemp(
                  'xveil-snapshot-admit-',
                );
                addTearDown(() => dir.delete(recursive: true));
                final path = '${dir.path}/store.hv';
                HvKvLogStore(
                  hv.HvSpace.create(
                    path: path,
                    password: Uint8List.fromList(utf8.encode('fixture')),
                    argon: hv.ArgonPreset.light,
                  ),
                ).close();
                store = _Store.async(workerSpaceOpener(path));
              } else {
                store = _Store(FakeHvContainer().passwordOpener);
              }
              expect(
                await store.open(password: 'fixture', createIfMissing: true),
                isTrue,
              );
              final link = _Link();
              var now = DateTime.now();
              final expires = now.add(const Duration(seconds: 30));
              final service = MessagingService(link, store, now: () => now);
              final validationEntered = Completer<void>(),
                  validationRelease = Completer<void>();
              var fail = mode == 'retry-failure';
              errorJournal.clear();
              addTearDown(() async {
                if (!store.release.isCompleted) store.release.complete();
                if (!validationRelease.isCompleted) {
                  validationRelease.complete();
                }
                await service.dispose();
                await link.dispose();
                await store.close();
              });
              await store.upsertContact(
                Contact(nodeId: _id(2), status: ContactStatus.accepted),
              );
              service.groupBindingsOwner = Object();
              service.deviceSnapshotExpiryGroup = () async => 'ab' * 32;
              service.onDeviceSnapshotExpiry = (_, body) async {
                final verdict = now.isBefore(expires) ? null : _clean;
                if (mode == 'concurrent' && !validationEntered.isCompleted) {
                  validationEntered.complete();
                  await validationRelease.future;
                }
                if (now.isBefore(expires)) return verdict;
                if (fail || mode == 'close') {
                  if (!validationEntered.isCompleted) {
                    validationEntered.complete();
                  }
                  if (fail) {
                    throw const FormatException(
                      'private filter failure',
                      _secret,
                    );
                  }
                  await validationRelease.future;
                }
                return verdict;
              };
              await service.sweepAllDisappearing();
              await pumpEventQueue();
              final body = jsonEncode({
                'g': [],
                'private': _secret * (chunked ? 500 : 1),
                'keep': 'SAFE_ADMISSION_STATE',
              });
              store.hold = true;
              final sending = service.sendGroupSnapshot(
                _id(2),
                'ab' * 32,
                body,
                awaitInitialSend: initial,
              );
              await store.entered.future.timeout(const Duration(seconds: 10));
              expect(
                await store.pendingOutboxFrames(),
                chunked ? hasLength(greaterThan(1)) : hasLength(1),
              );
              if (mode != 'concurrent') now = expires;
              await service.debugFlushOutboxFrames();
              final leakedWhileAdmissionHeld = link.leaked;
              store.release.complete();
              await sending;
              if (mode == 'concurrent') {
                await validationEntered.future.timeout(
                  const Duration(seconds: 10),
                );
                await service.sendGroupSnapshot(
                  _id(2),
                  'ab' * 32,
                  body,
                  awaitInitialSend: initial,
                );
                now = expires;
                validationRelease.complete();
              }
              if (mode == 'retry-failure' || mode == 'close') {
                await validationEntered.future.timeout(
                  const Duration(seconds: 10),
                );
                if (mode == 'close') {
                  var closed = false;
                  final closing = service.dispose().then((_) => closed = true);
                  await Future<void>(() {});
                  final closedBeforeValidation = closed;
                  validationRelease.complete();
                  await closing;
                  expect(closedBeforeValidation, isFalse);
                  expect(link.arrived.isCompleted, isFalse);
                  return;
                }
                await pumpEventQueue();
                await service.debugFlushOutboxFrames();
                expect(
                  link.arrived.isCompleted,
                  isFalse,
                  reason:
                      'failed validation must retain bytes without transport',
                );
                final failure = errorJournal.entries.singleWhere(
                  (e) => e.kind == 'device-snapshot-expiry',
                );
                expect(failure.type, 'FormatException');
                expect(failure.message, isNot(contains(_secret)));
                expect(
                  failure.toJson(includeTimestamps: false).toString(),
                  isNot(contains(_secret)),
                );
                fail = false;
                await service.sweepAllDisappearing();
              }
              if (!leakedWhileAdmissionHeld) {
                await link.arrived.future.timeout(const Duration(seconds: 10));
              }
              expect(
                link.leaked,
                isFalse,
                reason:
                    'an expired admitted copy must not enter either retry or initial transport',
              );
              final frames = await store.pendingOutboxFrames();
              expect(frames, hasLength(1));
              expect(WireEnvelope.decode(frames.single.wire).body, _clean);
              await service.dispose();
              await store.close();
              expect(await store.open(password: 'fixture'), isTrue);
              expect(
                WireEnvelope.decode(
                  (await store.pendingOutboxFrames()).single.wire,
                ).body,
                _clean,
              );
            },
            skip:
                native &&
                (Platform.environment['XVEIL_HV_DYLIB'] ?? '').isEmpty,
          );
        }
      }
    }
  }
}
