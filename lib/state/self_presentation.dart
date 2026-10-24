import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller.dart';
import 'nickname_controller.dart';

/// A claimed name lives in the claim controller, not the onboarding profile.
/// Never substitute a name whose network refresh positively found a new owner.
final selfPresentationProvider =
    Provider<({String label, String? nickname, String? nodeId})>((ref) {
      final app = ref.watch(appControllerProvider);
      final claim = ref.watch(nicknameControllerProvider);
      final identity = app.identity;
      final nickname = claim.ownedTakenOver ? null : claim.ownedName;
      final fallback = identity?.displayName?.trim();
      return (
        label: nickname != null
            ? '@$nickname'
            : fallback != null && fallback.isNotEmpty
            ? fallback
            : app.activeIdentity ?? identity?.nodeId.short ?? 'xVeil',
        nickname: nickname,
        nodeId: identity?.nodeId.hex,
      );
    });
