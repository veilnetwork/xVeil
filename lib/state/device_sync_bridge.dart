// Multi-device bridge, brick 4 (doc/MULTIDEVICE-DESIGN.md): contacts, app
// settings and the call journal ride the device group the same way brick 3
// mirrors 1:1 messages. EMIT taps fire only on LOCAL changes (each apply path
// writes below its tap), so nothing a device applies ever echoes back; APPLY
// consumes the same [GroupService.deviceIncoming] stream as the msgMirror
// bridge (which lives with the service itself in group_service.dart).
//
// Events can arrive in any order (catch-up snapshots, re-drives), so applies
// are gated by a newest-wins timestamp per (kind, key) — the in-RAM twin of
// foldDeviceSync's LWW rule; storage-level idempotence backstops a restart.

import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../domain/call_log.dart';
import '../domain/chat.dart' show SignaturePolicy;
import '../domain/device_sync.dart';
import 'call_log.dart';
import 'device_settings_sync.dart';
import 'group_service.dart';
import 'locale_controller.dart';
import 'messaging.dart';
import 'reactions_visibility_controller.dart';
import 'signature_policy_controller.dart';

/// Wires the brick-4 sync kinds. Eagerly watched from the app scope (next to
/// [groupServiceProvider]); rebuilds with the service on identity switch.
final deviceSyncBridgeProvider = Provider<void>((ref) {
  final svc = ref.watch(groupServiceProvider);
  if (svc == null) return;
  final messaging = ref.read(messagingServiceProvider);
  final hub = ref.read(deviceSettingsSyncHubProvider);
  final callLog = ref.read(callLogStoreProvider);

  // The settings allowlist: registering an applier is what admits a key.
  hub.register(
    kSyncShowReactions,
    (v) => ref.read(showReactionsProvider.notifier).set(v == '1'),
  );
  hub.register(
    kSyncLocale,
    (v) => ref
        .read(localeProvider.notifier)
        .setLocale(v.isEmpty ? null : Locale(v)),
  );
  hub.register(kSyncSignaturePolicy, (v) async {
    SignaturePolicy? policy;
    for (final p in SignaturePolicy.values) {
      if (p.name == v) policy = p;
    }
    if (policy == null) return; // newer vocabulary — skip, don't guess
    await ref.read(signaturePolicyProvider.notifier).set(policy);
  });

  // ── EMIT: local change → device-group event ───────────────────────────────
  // Monotonic emit stamps: two edits inside the same wall-clock millisecond
  // (e.g. a hook or a settings screen flipping two fields back-to-back) must
  // still be ordered, or the LWW fold ranks them by payload instead of by
  // which came last. Caught live in the brick-4 device verify.
  var lastEmitMs = 0;
  int nextTs() {
    final now = DateTime.now().millisecondsSinceEpoch;
    lastEmitMs = now > lastEmitMs ? now : lastEmitMs + 1;
    return lastEmitMs;
  }

  messaging.onContactPrefsChanged = (c) {
    unawaited(svc.postDeviceEvent(DeviceSyncEvent(
      kind: DeviceSyncKind.contactUp,
      key: c.nodeId.hex,
      tsMs: nextTs(),
      payload: {
        'name': c.name,
        'mutedMs': c.mutedUntil?.millisecondsSinceEpoch,
        'pin': c.pinned,
        'arc': c.archived,
        'ret': c.retentionDays,
        'apd': c.allowPeerDelete,
      },
    )));
  };
  hub.onLocalSet = (key, value) {
    unawaited(svc.postDeviceEvent(DeviceSyncEvent(
      kind: DeviceSyncKind.settingSet,
      key: key,
      tsMs: nextTs(),
      payload: {'v': value},
    )));
  };
  callLog.onAdded = (e) {
    unawaited(svc.postDeviceEvent(DeviceSyncEvent(
      kind: DeviceSyncKind.callLog,
      key: e.id,
      tsMs: e.atMs,
      payload: e.toJson(),
    )));
  };

  // Read marks (brick 4c): reading here clears the badge on my other devices.
  // The event's tsMs IS the watermark (not a monotonic emit stamp) — two
  // devices reading independently converge on the newest read time, which is
  // exactly the LWW the fold gives per key. Keys: '<peerHex>' for a 1:1
  // conversation, 'g:<gidHex>' for a group. The device-pair conversation is
  // excluded — each side names it by the other device's id, so the key would
  // not be portable.
  final lastReadEmitted = <String, int>{};
  messaging.onConversationRead = (convId, ts) {
    if ((lastReadEmitted[convId] ?? 0) >= ts) return;
    lastReadEmitted[convId] = ts;
    unawaited(() async {
      try {
        if (await svc.isMyDevice(NodeId.fromHex(convId))) return;
      } catch (_) {
        return; // not a node-id-shaped conversation — never sync it
      }
      await svc.postDeviceEvent(DeviceSyncEvent(
        kind: DeviceSyncKind.readMark,
        key: convId,
        tsMs: ts,
        payload: const {},
      ));
    }());
  };
  svc.onGroupSeen = (gidHex, ts) {
    final key = 'g:$gidHex';
    if ((lastReadEmitted[key] ?? 0) >= ts) return;
    lastReadEmitted[key] = ts;
    unawaited(() async {
      // Never for the device group itself (it is hidden from every list, but
      // hooks could still reach it) — its seen mark is meaningless to sync.
      if (gidHex == await svc.deviceGroupIdHex()) return;
      await svc.postDeviceEvent(DeviceSyncEvent(
        kind: DeviceSyncKind.readMark,
        key: key,
        tsMs: ts,
        payload: const {},
      ));
    }());
  };

  // Lazy attachments (brick 4b): when the user downloads a cid that is a
  // mirrored attachment of my device group, also request it from my other
  // devices over the membership-authorized content path. The in-flight set
  // breaks the recursion (fetchGroupContent's pull re-enters downloadContent,
  // which fires this hook again) and de-bounces retry taps.
  final pulling = <String>{};
  messaging.deviceContentPull = (cid) async {
    if (!pulling.add(cid)) return;
    try {
      final gidHex = await svc.deviceGroupIdHex();
      if (gidHex == null) return;
      final gid = NodeId.fromHex(gidHex);
      if (!(await svc.referencedContentIds(gid)).contains(cid)) return;
      final st = await svc.stateOf(gid);
      if (st == null) return;
      for (final m in st.members.values) {
        if (m.nodeId == svc.selfId) continue;
        await svc.fetchGroupContent(gid, cid, m.nodeId);
      }
    } finally {
      // Free the slot on the next tick — enough to cover the synchronous
      // re-entry from our own pull, while a later user retry still works.
      Timer(const Duration(seconds: 15), () => pulling.remove(cid));
    }
  };

  // ── APPLY: device-group event → local state, newest-wins per (kind, key),
  // ranked exactly like foldDeviceSync (same-millisecond edits tie-break on
  // payload — a bare timestamp compare would drop the fold's winner).
  final lastApplied = <String, DeviceSyncEvent>{};
  bool newest(DeviceSyncEvent e) {
    final k = '${e.kind.name}|${e.key}';
    final prev = lastApplied[k];
    if (prev != null && !isNewerDeviceSync(e, prev)) return false;
    lastApplied[k] = e;
    return true;
  }

  final sub = svc.deviceIncoming.listen((gm) {
    final e = DeviceSyncEvent.fromBody(gm.body);
    if (e == null || !newest(e)) return;
    switch (e.kind) {
      case DeviceSyncKind.contactUp:
        final NodeId peer;
        try {
          peer = NodeId.fromHex(e.key);
        } catch (_) {
          return; // malformed key from a newer/buggy device — skip silently
        }
        final name = e.payload['name'], muted = e.payload['mutedMs'];
        final ret = e.payload['ret'];
        unawaited(messaging.applyMirroredContact(
          peer: peer,
          name: name is String && name.isNotEmpty ? name : null,
          mutedUntilMs: muted is int ? muted : null,
          pinned: e.payload['pin'] == true,
          archived: e.payload['arc'] == true,
          retentionDays: ret is int ? ret : null,
          allowPeerDelete: e.payload['apd'] != false,
        ));
      case DeviceSyncKind.settingSet:
        final v = e.payload['v'];
        if (v is String) unawaited(hub.applyIncoming(e.key, v));
      case DeviceSyncKind.callLog:
        final entry = CallLogEntry.fromJson(e.payload);
        if (entry != null && entry.id == e.key) {
          unawaited(callLog.addMirrored(entry));
        }
      case DeviceSyncKind.readMark:
        // Remember the applied mark as "already emitted" so a later local
        // open of the same conversation does not re-post an identical event.
        if ((lastReadEmitted[e.key] ?? 0) < e.tsMs) {
          lastReadEmitted[e.key] = e.tsMs;
        }
        if (e.key.startsWith('g:')) {
          unawaited(svc.applyMirroredGroupSeen(e.key.substring(2), e.tsMs));
        } else if (e.key != svc.selfId.hex) {
          unawaited(messaging.applyMirroredReadMark(e.key, e.tsMs));
        }
      case DeviceSyncKind.msgMirror:
        break; // applied by the group_service bridge (brick 3)
    }
  });
  ref.onDispose(sub.cancel);
});
