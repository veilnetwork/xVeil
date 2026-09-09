// Where a device-sync event goes to be applied, whoever brought it.
//
// Three parts of the app turn these events into local state: the device-sync
// bridge (contacts, settings, the call journal, read marks, identity
// documents), the group-service bridge (message mirrors) and the cloud service
// (cloud items). Each subscribes to the SAME stream of events arriving from
// the device group, and each carries its own idempotence — a
// [DeviceSyncApplyGate] with newest-wins per (kind, key), or a service-level
// upsert keyed by id.
//
// An offline archive is the same events by another road. Rather than teach the
// importer to write contacts and messages itself — a second answer to "which
// of these two devices is right", and the one thing this design set out not to
// have — it hands each event to the appliers that already exist. What arrives
// from a file is indistinguishable from what arrives from a sibling device,
// which is what makes "merge two devices offline" mean the same thing as
// "let two devices see each other".
//
// The registry is deliberately dumb: registration order is not significant,
// every applier sees every event, and each decides for itself what it handles.
// That is already true of the live path — the same event reaches all three
// listeners — so this adds a door, not a rule.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/device_sync.dart';

/// A function that applies (or ignores) one event.
///
/// May return a future. The live stream ignores it — nobody is waiting there —
/// while an import awaits it, because a person is being told the merge is
/// done.
typedef DeviceSyncApply = FutureOr<void> Function(DeviceSyncEvent event);

/// An applier's promise that the work it QUEUED has finished.
///
/// Separate from the apply itself because the appliers that matter here queue:
/// [DeviceSyncApplyGate.offer] decides immediately and writes behind a
/// per-slot chain. Waiting for `apply` to return would wait for the decision,
/// which is not the thing the word "merged" claims.
typedef DeviceSyncSettle = Future<void> Function();

class DeviceSyncAppliers {
  final List<DeviceSyncApply> _handlers = [];
  final Map<DeviceSyncApply, DeviceSyncSettle> _settles = {};

  /// Register [apply]; the returned callback removes it again.
  ///
  /// [settle], when given, is awaited by [settleAll] — that is how an applier
  /// says "and my queued writes are done too". An applier without one is
  /// counted in [unconfirmed], so a caller can say so rather than imply a
  /// completeness nobody promised.
  ///
  /// Returning the remover rather than exposing an `unregister(fn)` keeps a
  /// provider's teardown honest: `ref.onDispose(appliers.register(...))` cannot
  /// be written in a way that removes somebody else's handler.
  void Function() register(DeviceSyncApply apply, {DeviceSyncSettle? settle}) {
    _handlers.add(apply);
    if (settle != null) _settles[apply] = settle;
    return () {
      _handlers.remove(apply);
      _settles.remove(apply);
    };
  }

  /// Appliers that cannot report when their queued work is finished.
  int get unconfirmed => _handlers.length - _settles.length;

  /// Wait for every applier that can say so.
  Future<void> settleAll() async {
    for (final settle in List<DeviceSyncSettle>.of(_settles.values)) {
      await settle();
    }
  }

  /// How many appliers are listening.
  ///
  /// The importer reads this to say something true when nothing is: an import
  /// run before the bridges are wired would apply none of the merge and report
  /// success, which is the failure mode this exists to make visible.
  int get count => _handlers.length;

  /// Hand [event] to everyone, and wait for whatever they return.
  ///
  /// Iterates a copy: an applier that registers or removes one while handling
  /// an event would otherwise mutate the list being walked. Awaiting the
  /// returned futures is what keeps an import from racing ahead of the writes
  /// it is asking for — [settleAll] then covers the work that was queued
  /// rather than returned.
  Future<void> deliver(DeviceSyncEvent event) async {
    for (final apply in List<DeviceSyncApply>.of(_handlers)) {
      await apply(event);
    }
  }
}

/// One registry per app, so an importer can reach the appliers a bridge wired.
final deviceSyncAppliersProvider = Provider<DeviceSyncAppliers>(
  (ref) => DeviceSyncAppliers(),
);
