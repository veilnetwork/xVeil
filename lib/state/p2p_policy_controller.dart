import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../domain/chat.dart';
import '../domain/p2p_policy.dart';
import 'app_controller.dart';
import 'group_service_providers.dart';
import 'providers.dart';

class P2PPolicyController extends Notifier<P2PGlobalPolicy> {
  bool _userSet = false;

  @override
  P2PGlobalPolicy build() {
    final storage = ref.watch(storageProvider);
    _load();
    ref.onDispose(() {
      // Touching [storage] above intentionally makes this provider rebuild when
      // all-online switches the active identity's deniable space.
      storage.isOpen;
    });
    return kDefaultP2PGlobalPolicy;
  }

  Future<void> _load() async {
    try {
      final raw = await ref
          .read(storageProvider)
          .getSetting(kP2PGlobalPolicySettingKey);
      if (_userSet) return;
      state = p2pGlobalPolicyFromName(raw);
    } catch (_) {
      // Storage may be closed in tests/lock screen; keep the default.
    }
  }

  Future<void> set(P2PGlobalPolicy value) async {
    _userSet = true;
    state = value;
    try {
      await ref
          .read(storageProvider)
          .putSetting(kP2PGlobalPolicySettingKey, value.name);
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
      devLog(() => 'xVeil[p2p]: messaging policy check failed for '
          '${peer.short}: $e');
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
