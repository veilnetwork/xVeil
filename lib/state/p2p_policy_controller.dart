import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../domain/chat.dart';
import '../data/storage/storage.dart';
import '../domain/p2p_policy.dart';
import 'app_controller.dart';
import 'group_service_providers.dart';
import 'providers.dart';

class P2PPolicyController extends Notifier<P2PGlobalPolicy> {
  /// Whether the person on THIS identity has chosen a policy.
  ///
  /// The notifier survives a rebuild, so this had to be reset with it: left
  /// standing, A's choice made B's load return early and B ran under A's
  /// policy. What that decides is whether a conversation may take the direct
  /// ladder — so "allow" carried into an identity whose owner had said "never"
  /// hands that identity's peer its real address (report17 XV17-M3).
  bool _userSet = false;

  /// The storage THIS build belongs to.
  late Storage _storage;

  @override
  P2PGlobalPolicy build() {
    // WATCHED: an all-online switch rebuilds this notifier.
    _storage = ref.watch(storageProvider);
    // Both reset with it. The choice belongs to an identity, and so does the
    // knowledge that one was made.
    _userSet = false;
    _load(_storage);
    return kDefaultP2PGlobalPolicy;
  }

  Future<void> _load(Storage storage) async {
    try {
      final raw = await storage.getSetting(kP2PGlobalPolicySettingKey);
      // The identity moved while this read was in flight. A policy read out of
      // A's storage must not become B's — and the direction that matters is
      // the permissive one.
      if (!identical(_storage, storage) || _userSet) return;
      state = p2pGlobalPolicyFromName(raw);
    } catch (_) {
      // Storage may be closed in tests/lock screen; keep the default.
    }
  }

  Future<void> set(P2PGlobalPolicy value) async {
    final storage = _storage;
    _userSet = true;
    state = value;
    try {
      // Into the storage this choice was made under. Equivalent to reading the
      // provider today — nothing awaits between the decision and this line, so
      // the two resolve to the same handle — and it stays correct if anything
      // ever does await in between, which is exactly how the load above came
      // to land on the wrong identity.
      await storage.putSetting(kP2PGlobalPolicySettingKey, value.name);
    } catch (_) {
      // Persist best-effort.
    }
  }

  bool get localAnonymous {
    final app = ref.read(appControllerProvider);
    final ctrl = ref.read(appControllerProvider.notifier);
    if (app.isMaster) {
      final active = app.activeIdentity;
      return active != null && ctrl.isIdentityAnonymous(active);
    }
    return ctrl.singleIdentityAnonymous;
  }

  /// The MESSAGING gate: may a conversation with [peer] run the direct ladder?
  /// Opt-in per contact — see [p2pMessagingAllows] for why this does not follow
  /// the global policy the way calls do. A denial is normal and costs latency
  /// only, so it is logged at the same level as the call-path denial but must
  /// never surface as an error.
  Future<bool> allowsMessagingPeer(NodeId peer) async {
    try {
      // MY OWN DEVICE first, and not as a courtesy. The opt-in below is a
      // question about CONTACTS — how much a conversation partner may learn
      // about our network position — and a sibling is the same person: there
      // is nothing to protect from it, and everything to gain, because
      // without the ladder two leaf devices behind relays never form the
      // direct session their content streams need (measured: every
      // sibling→master stream open failing NO_SESSION while both sat on one
      // machine).
      final group = ref.read(groupServiceProvider);
      if (group != null && await group.isMyDevice(peer)) return true;
      final contact = await ref.read(storageProvider).getContact(peer);
      final override = contact?.p2pOverride ?? kDefaultContactP2POverride;
      final allowed = p2pMessagingAllows(
        override: override,
        contactKnown: contact != null,
        contactBlocked: contact?.status == ContactStatus.blocked,
        localAnonymous: localAnonymous,
      );
      if (!allowed) {
        devLog(
          () =>
              'xVeil[p2p]: messaging ladder not allowed for ${peer.short} '
              '(override=${override.name} known=${contact != null} '
              'anonymous=$localAnonymous) — mailbox path unaffected',
        );
      }
      return allowed;
    } catch (e) {
      devLog(
        () =>
            'xVeil[p2p]: messaging policy check failed for '
            '${peer.short}: $e',
      );
      return false;
    }
  }

  Future<bool> allowsPeer(NodeId peer) async {
    try {
      // MY OWN DEVICE, same reasoning as [allowsMessagingPeer]. This gate
      // fronts BOTH ends of the endpoint exchange (maybeShare and _onFrame)
      // and rung 0 of ensureReady, so a sibling that passed the messaging
      // opt-in still died right here: the warm ran, shared nothing, dropped
      // the sibling's own share on the floor, and the session never formed.
      final group = ref.read(groupServiceProvider);
      if (group != null && await group.isMyDevice(peer)) return true;
      final contact = await ref.read(storageProvider).getContact(peer);
      final override = contact?.p2pOverride ?? kDefaultContactP2POverride;
      final accepted = contact?.status == ContactStatus.accepted;
      final blocked = contact?.status == ContactStatus.blocked;
      final anonymous = localAnonymous;
      final allowed = p2pPolicyAllows(
        global: state,
        override: override,
        contactKnown: contact != null,
        contactAccepted: accepted,
        contactBlocked: blocked,
        localAnonymous: anonymous,
      );
      if (!allowed) {
        // Name the exact deny input: a silent false here once cost a live
        // session to a phantom "transient endpoint-frame drop" (2026-07-24).
        devLog(
          () =>
              'xVeil[p2p]: policy denies ${peer.short} (global=${state.name} '
              'override=${override.name} known=${contact != null} '
              'accepted=$accepted blocked=$blocked anonymous=$anonymous)',
        );
      }
      return allowed;
    } catch (e) {
      devLog(() => 'xVeil[p2p]: policy check failed for ${peer.short}: $e');
      return false;
    }
  }
}

final p2pPolicyProvider =
    NotifierProvider<P2PPolicyController, P2PGlobalPolicy>(
      P2PPolicyController.new,
    );
