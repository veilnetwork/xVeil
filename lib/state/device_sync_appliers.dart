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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/device_sync.dart';

/// A function that applies (or ignores) one event.
typedef DeviceSyncApply = void Function(DeviceSyncEvent event);

class DeviceSyncAppliers {
  final List<DeviceSyncApply> _handlers = [];

  /// Register [apply]; the returned callback removes it again.
  ///
  /// Returning the remover rather than exposing an `unregister(fn)` keeps a
  /// provider's teardown honest: `ref.onDispose(appliers.register(...))` cannot
  /// be written in a way that removes somebody else's handler.
  void Function() register(DeviceSyncApply apply) {
    _handlers.add(apply);
    return () => _handlers.remove(apply);
  }

  /// How many appliers are listening.
  ///
  /// The importer reads this to say something true when nothing is: an import
  /// run before the bridges are wired would apply none of the merge and report
  /// success, which is the failure mode this exists to make visible.
  int get count => _handlers.length;

  /// Hand [event] to everyone.
  ///
  /// Iterates a copy: an applier that registers or removes one while handling
  /// an event would otherwise mutate the list being walked.
  void deliver(DeviceSyncEvent event) {
    for (final apply in List<DeviceSyncApply>.of(_handlers)) {
      apply(event);
    }
  }
}

/// One registry per app, so an importer can reach the appliers a bridge wired.
final deviceSyncAppliersProvider = Provider<DeviceSyncAppliers>(
  (ref) => DeviceSyncAppliers(),
);
