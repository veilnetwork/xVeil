// Settings-sync hub (multi-device epic, brick 4). App-level preferences live
// in per-controller Riverpod notifiers (SharedPreferences-backed), so there is
// no single write chokepoint to tap — instead each ALLOWLISTED controller
// notifies this hub on a local set, and the device-sync bridge both forwards
// those to the device group and applies incoming ones back through the same
// controllers (state + persistence + UI update in one move).
//
// The allowlist is REGISTRATION: only keys the bridge registers an applier for
// sync at all. Platform-local preferences (tray, close-to-tray, background
// node, per-device P2P policy, API server, page sizes) must never register.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sync keys — the DeviceSyncEvent key namespace for `settingSet` events.
/// Values match the controllers' SharedPreferences keys for greppability.
const String kSyncShowReactions = 'show_reactions';
const String kSyncLocale = 'locale';
const String kSyncSignaturePolicy = 'signature_policy';

typedef DeviceSettingApply = Future<void> Function(String value);

class DeviceSettingsSyncHub {
  /// Wired by the device-sync bridge: a LOCAL user set of an allowlisted
  /// setting, to be posted to the device group. Never fires while an incoming
  /// value is being applied — that is what breaks the mirror loop.
  void Function(String key, String value)? onLocalSet;

  final Map<String, DeviceSettingApply> _appliers = {};
  bool _applying = false;

  /// Register the applier for [key] — this IS the allowlist entry.
  void register(String key, DeviceSettingApply apply) =>
      _appliers[key] = apply;

  /// Called by an allowlisted controller after a LOCAL set. Swallowed while
  /// applying an incoming value (the controller's set() runs inside
  /// [applyIncoming] — re-emitting it would ping-pong between devices with
  /// ever-newer timestamps).
  void notifyLocalSet(String key, String value) {
    if (_applying) return;
    onLocalSet?.call(key, value);
  }

  /// Apply a synced value through the registered controller. False for a key
  /// that is not allowlisted (unknown or platform-local — skipped silently,
  /// same posture as unknown DeviceSyncKinds).
  Future<bool> applyIncoming(String key, String value) async {
    final apply = _appliers[key];
    if (apply == null) return false;
    _applying = true;
    try {
      await apply(value);
    } finally {
      _applying = false;
    }
    return true;
  }
}

final deviceSettingsSyncHubProvider =
    Provider<DeviceSettingsSyncHub>((ref) => DeviceSettingsSyncHub());
