// Multi-device bridge, brick 4 (doc/MULTIDEVICE-DESIGN.md): contacts, app
// settings and the call journal ride the device group the same way brick 3
// mirrors 1:1 messages. EMIT taps fire only on LOCAL changes (each apply path
// writes below its tap), so nothing a device applies ever echoes back; APPLY
// consumes the same [GroupService.deviceIncoming] stream as the msgMirror
// bridge (which lives with the service itself in group_service_providers.dart).
//
// Events can arrive in any order (catch-up snapshots, re-drives), so applies
// are gated by a newest-wins timestamp per (kind, key) — the in-RAM twin of
// foldDeviceSync's LWW rule; storage-level idempotence backstops a restart.

import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/log.dart';
import '../core/ids.dart';
import '../data/node/sovereign_identity_material.dart';
import '../data/veil_stack.dart';
import '../domain/call_log.dart';
import '../domain/chat.dart'
    show Contact, ContactStatus, NotificationMuteMode, SignaturePolicy;
import '../domain/device_sync.dart';
import '../domain/disappearing_messages.dart' show DisappearingSetting;
import 'call_log.dart';
import 'device_settings_sync.dart';
import 'providers.dart' show realStackProvider;
import 'group_service_providers.dart';
import 'locale_controller.dart';
import 'messaging.dart';
import 'reactions_visibility_controller.dart';
import 'signature_policy_controller.dart';

/// Wires the brick-4 sync kinds. Eagerly watched from the app scope (next to
/// [groupServiceProvider]); rebuilds with the service on identity switch.
/// The preference fields a contact record puts on the device-sync wire.
///
/// Named rather than inline so both halves of the round trip can be checked in
/// one place: a field added to `Contact` and forgotten here does not sync, and
/// nothing about the running app says so. That is how the retention policy came
/// to be missing from it — four fields the interface makes a promise about,
/// travelling nowhere.
///
/// Relationship status and the per-device P2P override are deliberately absent:
/// they ride their own key namespace, or are local by design.
Map<String, Object?> contactPrefsPayload(Contact c) => {
  'name': c.name,
  'mutedMs': c.mutedUntil?.millisecondsSinceEpoch,
  'muteMode': c.notificationMuteMode.name,
  'pin': c.pinned,
  'arc': c.archived,
  'ret': c.retentionDays,
  'apd': c.allowPeerDelete,
  // The retention policy travels WITH the preferences, carrying its own stamp
  // and setter so the sibling can run the same last-writer-wins rule a peer's
  // announcement goes through.
  'dtl': c.disappearingTtlSeconds,
  'dsa': c.disappearingSetAtMs,
  'dsb': c.disappearingSetBy,
  'har': c.hideAfterReadSeconds,
};

/// The retention policy carried by [contactPrefsPayload], or null when the
/// event came from a build that did not carry one.
///
/// Absent, not null: treating silence as "the window is off" would let an old
/// build's alias edit switch off a window a new one had set. The presence of
/// the stamp is what makes it an answer.
DisappearingSetting? disappearingFromPayload(Map<String, Object?> payload) {
  final setAt = payload['dsa'];
  if (setAt is! int) return null;
  final ttl = payload['dtl'], hide = payload['har'], by = payload['dsb'];
  return DisappearingSetting(
    ttlSeconds: ttl is int ? ttl : null,
    setAtMs: setAt,
    setBy: by is String ? by : '',
    hideAfterReadSeconds: hide is int ? hide : null,
  );
}

final deviceSyncBridgeProvider = Provider<void>((ref) {
  final svc = ref.watch(groupServiceProvider);
  if (svc == null) return;
  final messaging = ref.read(messagingServiceProvider);
  final hub = ref.read(deviceSettingsSyncHubProvider);
  final callLog = ref.read(callLogStoreProvider);

  // Boot catch-up (brick 4e): ship the full device-group snapshot to my other
  // devices once per bridge build. Deltas posted during a total entry-node
  // outage never redrive into the GROUP log (unlike 1:1 durable frames), so
  // without this a sibling that missed them stays diverged until re-link.
  unawaited(svc.nudgeDeviceSync());

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

  // ── The identity document ────────────────────────────────────────────────
  //
  // Announcing it is what turns several devices into ONE identity instead of
  // several nodes wearing the same name. Devices set up from the same master
  // phrase all derive the same node_id — it is BLAKE3 of that master key — and
  // each starts holding a document that names only itself. All of them publish
  // under that id, the last publisher displaces the rest, and the displaced
  // devices stay online believing they are reachable.
  //
  // Announced on every bridge build rather than once at linking: a device that
  // was off when another joined has no other moment to learn of it, and the
  // exchange is idempotent — a document that changes nothing is not answered.
  // The announcer's DEVICE id, for keying the announcement and skipping its
  // echo. NOT selfId: on a phrase-restored device selfId IS the identity
  // address, which its master shares — keyed by selfId, the master's and the
  // restored device's announcements were MUTUALLY invisible ("my own echo"),
  // and a document amendment made on one never reached the other. The
  // nineteenth face of the device/identity class, measured live 2026-08-17:
  // a revocation tombstone announced by the master sat unapplied on the
  // sibling forever.
  NodeId? announceDevice;

  Future<void> announceIdentityDocument() async {
    final raw = await svc.storage.getSetting(kSovereignIdentitySetting);
    if (raw == null) return; // mined identity, or nothing provisioned
    final files = decodeSovereignIdentity(raw);
    final doc = files?[kIdentityDocumentFile];
    if (doc == null || doc.isEmpty) return;
    announceDevice ??= await svc.resolveMyDevice();
    await svc.postDeviceEvent(
      DeviceSyncEvent(
        kind: DeviceSyncKind.identityDoc,
        key: (announceDevice ?? svc.selfId).hex,
        tsMs: nextTs(),
        payload: {'d': base64.encode(doc)},
      ),
    );
  }

  unawaited(announceIdentityDocument());

  // Contact records of my OWN devices never sync: each side keys the pair
  // relationship by the OTHER device's id, so the record is not portable (on
  // the sibling it would describe itself). Same rule as the msgMirror
  // exclusion (brick 4c).
  messaging.onContactPrefsChanged = (c) {
    unawaited(() async {
      if (c.nodeId == svc.selfId || await svc.isMyDevice(c.nodeId)) return;
      await svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.contactUp,
          key: c.nodeId.hex,
          tsMs: nextTs(),
          payload: contactPrefsPayload(c),
        ),
      );
    }());
  };
  // Relationship transitions ride a SEPARATE key namespace ('s:<peer>'), so
  // a preference edit and a status change LWW independently — an alias edit
  // carrying a stale embedded status could otherwise un-block a peer that my
  // other device just blocked.
  messaging.onContactStatusChanged = (peer, status) {
    svc.notifyContactAccessChanged(peer);
    unawaited(() async {
      if (peer == svc.selfId || await svc.isMyDevice(peer)) return;
      // ONLY DECISIONS TRAVEL. A pending status is the doorbell, and every
      // device hears the doorbell itself — the request wire is addressed to
      // the identity. Mirroring it gave the SECOND device's "pendingIncoming"
      // a fresher timestamp than the first device's "accepted", and the LWW
      // fold then regressed the accept on every device that folded both.
      // Measured live: C's request accepted on the master, and the sibling's
      // own doorbell event beat the accept by four minutes of wall clock.
      if (status == ContactStatus.pendingIncoming ||
          status == ContactStatus.pendingOutgoing) {
        return;
      }
      await svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.contactUp,
          key: 's:${peer.hex}',
          tsMs: nextTs(),
          payload: {'status': status.name},
        ),
      );
    }());
  };
  hub.onLocalSet = (key, value) {
    unawaited(
      svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.settingSet,
          key: key,
          tsMs: nextTs(),
          payload: {'v': value},
        ),
      ),
    );
  };
  callLog.onAdded = (e) {
    unawaited(
      svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.callLog,
          key: e.id,
          tsMs: e.atMs,
          payload: e.toJson(),
        ),
      ),
    );
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
      await svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.readMark,
          key: convId,
          tsMs: ts,
          payload: const {},
        ),
      );
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
      await svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.readMark,
          key: key,
          tsMs: ts,
          payload: const {},
        ),
      );
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
      final referenced = await svc.referencedContentIds(gid);
      if (!referenced.contains(cid)) {
        // The guard doing its job must say so: a pull that ends here looks
        // identical to one that never started, and "why doesn't the sibling
        // fetch the bytes" spent a session on exactly that silence.
        devLog(
          () =>
              'xVeil[devices]: content pull refused — '
              '${cid.substring(0, 12)} is not an attachment of the device '
              'group (${referenced.length} referenced)',
        );
        return;
      }
      final st = await svc.stateOf(gid);
      if (st == null) return;
      // Who NOT to ask, and both exclusions name a device, not the identity.
      //
      // The sovereign OWNER is a signing key, not a node — pulling from it
      // spent the whole retry budget on an address nobody answers (measured:
      // six attempts against d3b1d6f2 while the master sat online untouched).
      // And "myself" must be MY TRANSPORT ID: selfId is the identity, which
      // on a sibling equals the MASTER's device id — the one member that
      // actually holds the bytes was the one member skipped.
      final bundle = await svc.load(gid);
      final owner = bundle?.manifest.isSovereignDevice == true
          ? bundle!.manifest.owner
          : null;
      await svc.resolveMyDevice();
      final me = svc.myDevice;
      for (final m in st.members.values) {
        if (owner != null && m.nodeId == owner) continue;
        if (me != null && m.nodeId == me) continue;
        if (me == null && m.nodeId == svc.selfId) continue;
        await svc.fetchGroupContent(gid, cid, m.nodeId);
      }
    } finally {
      // Free the slot on the next tick — enough to cover the synchronous
      // re-entry from our own pull, while a later user retry still works.
      Timer(const Duration(seconds: 15), () => pulling.remove(cid));
    }
  };

  // ── APPLY: device-group event → local state. Ordering lives in the gate:
  // newest-wins per (kind, key) ranked exactly like foldDeviceSync, nothing
  // effective before its own timestamp, and — because [DeviceSyncApplyGate.offer]
  // is handed a PLAN rather than a decision — a slot that moves only for events
  // this bridge actually applied. Every `return null` below is an event we
  // refuse: it must leave no watermark, or the honest event ranked under it is
  // dropped without ever being looked at.
  final gate = DeviceSyncApplyGate();

  // Shared by the live pref apply and the post-materialization replay below.
  Future<bool> applyPrefs(NodeId peer, DeviceSyncEvent e) {
    final name = e.payload['name'], muted = e.payload['mutedMs'];
    final muteMode = NotificationMuteMode.values.firstWhere(
      (mode) => mode.name == e.payload['muteMode'],
      orElse: () => NotificationMuteMode.none,
    );
    final ret = e.payload['ret'];
    return messaging.applyMirroredContact(
      peer: peer,
      name: name is String && name.isNotEmpty ? name : null,
      mutedUntilMs: muted is int ? muted : null,
      notificationMuteMode: muteMode,
      pinned: e.payload['pin'] == true,
      archived: e.payload['arc'] == true,
      retentionDays: ret is int ? ret : null,
      allowPeerDelete: e.payload['apd'] != false,
      disappearing: disappearingFromPayload(e.payload),
    );
  }

  // One handler for both arrivals of an event: the live stream, and the
  // folded state replayed at start. They are the same events; only the
  // MOMENT differs, and the moment was load-bearing when it should not have
  // been.
  void handleEvent(DeviceSyncEvent e) {
    switch (e.kind) {
      case DeviceSyncKind.contactUp:
        gate.offer(e, () {
          final statusEvent = e.key.startsWith('s:');
          final NodeId peer;
          try {
            peer = NodeId.fromHex(statusEvent ? e.key.substring(2) : e.key);
          } catch (_) {
            return null; // malformed key from a newer/buggy device
          }
          if (peer.hex == svc.selfId.hex) return null; // never my own record
          if (!statusEvent) return () => applyPrefs(peer, e);
          final raw = e.payload['status'];
          ContactStatus? status;
          for (final s in ContactStatus.values) {
            if (s.name == raw) status = s;
          }
          if (status == null) return null; // newer vocabulary — don't guess
          final resolved = status;
          return () async {
            final changed = await messaging.applyMirroredContactStatus(
              peer,
              resolved,
            );
            if (changed) svc.notifyContactAccessChanged(peer);
            // A pref event that arrived while this peer was still unknown was
            // skipped (prefs never CREATE a record — they carry no status).
            // Now that the record exists, replay the newest folded pref for
            // it so the alias/flags chosen on the other device land too.
            final folded = await svc.deviceSyncState();
            final pref = folded[(DeviceSyncKind.contactUp, peer.hex)];
            if (pref != null) await applyPrefs(peer, pref);
          };
        });
      case DeviceSyncKind.settingSet:
        gate.offer(e, () {
          final v = e.payload['v'];
          if (v is! String) return null;
          return () => hub.applyIncoming(e.key, v);
        });
      case DeviceSyncKind.callLog:
        gate.offer(e, () {
          final entry = CallLogEntry.fromJson(e.payload);
          if (entry == null || entry.id != e.key) return null;
          return () => callLog.addMirrored(entry);
        });
      case DeviceSyncKind.readMark:
        gate.offer(e, () {
          final group = e.key.startsWith('g:');
          if (!group && e.key == svc.selfId.hex) return null;
          // Remember the applied mark as "already emitted" so a later local
          // open of the same conversation does not re-post an identical event.
          // Inside the plan, so a mark we end up refusing cannot silence the
          // emit tap for a conversation nothing ever applied.
          if ((lastReadEmitted[e.key] ?? 0) < e.tsMs) {
            lastReadEmitted[e.key] = e.tsMs;
          }
          return () => group
              ? svc.applyMirroredGroupSeen(e.key.substring(2), e.tsMs)
              : messaging.applyMirroredReadMark(e.key, e.tsMs);
        });
      // Deliberately not offered: this bridge applies none of these, so giving
      // them a slot would only park a row per mirrored message and per cloud
      // item in a map that is never read.
      case DeviceSyncKind.msgMirror:
        break; // applied by the group_service bridge (brick 3)
      case DeviceSyncKind.cloudEntry:
      case DeviceSyncKind.cloudReplica:
      case DeviceSyncKind.cloudFolder:
        break; // applied by CloudService
      case DeviceSyncKind.identityDoc:
        gate.offer(e, () {
          // My own announcement, echoed back by the group log — matched by
          // DEVICE id, never selfId (shared with the master; see
          // announceDevice above). An event keyed by a selfId we happen to
          // share is APPLIED, not skipped: adopting our own document is a
          // no-change no-op, while skipping a sibling's was a silent divorce.
          if (announceDevice != null && e.key == announceDevice!.hex) {
            return null;
          }
          final raw = e.payload['d'];
          if (raw is! String || raw.isEmpty) return null;
          final Uint8List doc;
          try {
            doc = base64.decode(raw);
          } on FormatException {
            return null; // malformed from a newer or broken device
          }
          return () async {
            // The merge is native and handles both directions: append this
            // device when the incoming document does not name it, adopt when
            // it does. It refuses a document of another identity outright.
            final changed = await RealVeilStack.adoptSovereignDocument(
              svc.storage,
              document: doc,
              // Brief, and removed by the call itself. The same material
              // already passes through the node's own working directory, and
              // veil stages the node config — which carries the master key —
              // in the platform temp directory on every deferred boot.
              stagingBase: Directory.systemTemp.path,
            );
            // Answer ONLY when something changed. The other device then holds
            // a document naming us both, receives ours, finds nothing new in
            // it, and the exchange stops — otherwise two devices would trade
            // identical documents for as long as they are both running.
            if (changed) {
              // The running node re-reads it, then we answer. Without the
              // re-read this device would announce a merge its own registry
              // does not reflect.
              final stack = ref.read(realStackProvider);
              if (stack != null) {
                await stack.refreshSovereignIdentity(svc.storage);
              }
              await announceIdentityDocument();
            }
          };
        });
      case DeviceSyncKind.cloudCapability:
        break; // applied by CloudCapabilityService (contains secret registry)
    }
  }

  final sub = svc.deviceIncoming.listen((gm) {
    final e = DeviceSyncEvent.fromBody(gm.body);
    if (e == null) return;
    handleEvent(e);
  });
  // REPLAY THE FOLD, once, at start. The live stream only carries what
  // arrives while this bridge is listening, and an event can land any other
  // way — in a snapshot chunk while the app was busy, in a mailbox drain
  // before the providers were built, on a device that was simply off. The
  // event then sits in the folded device-sync state, visible to any probe,
  // and is never APPLIED: measured live as a sibling whose fold held the
  // contactUp for a freshly accepted contact while its contact list stayed
  // empty for good. The gate's watermarks make this idempotent — an event
  // the live stream already applied moves nothing.
  unawaited(() async {
    final folded = await svc.deviceSyncState();
    for (final e in folded.values) {
      handleEvent(e);
    }
  }());
  ref.onDispose(sub.cancel);
});
