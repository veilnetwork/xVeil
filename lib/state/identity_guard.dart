import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller.dart';

/// Asking a question of one identity and applying the answer to another.
///
/// In "all identities online" mode a switch does not unmount `/home` and does
/// not close a modal, so `mounted` stays true and `ref.read(...)` starts
/// returning the NEW identity's services. A dialog opened under A therefore
/// hands its answer to B: B's history gets cleared, B's network posture is
/// rewritten, B's file policy is replaced wholesale, or a frame addressed to
/// A's peer is queued in B's outbox.
///
/// [IdentityLease] already existed and a handful of screens used it; these two
/// calls exist so a helper that is about to await does not have to reach for
/// `appControllerProvider.notifier` twice and get the shape subtly wrong. The
/// rule is one line long:
///
/// ```dart
/// final lease = ref.leaseIdentity();     // BEFORE the first await
/// final answer = await showDialog(...);  // the user may switch here
/// if (!ref.holdsIdentity(lease)) return; // BEFORE any side effect
/// ```
///
/// `mounted` is a different question and does not answer this one: the widget
/// is still mounted, which is exactly why the continuation runs at all.
extension IdentityGuard on WidgetRef {
  /// The identity active right now, to be re-checked after each await.
  IdentityLease leaseIdentity() =>
      read(appControllerProvider.notifier).leaseIdentity();

  /// Whether [lease] is still the active identity.
  ///
  /// False after a switch, including a switch away and back: the label is
  /// equal again but every service behind it has been rebuilt, and the epoch
  /// is what separates those.
  bool holdsIdentity(IdentityLease lease) =>
      read(appControllerProvider.notifier).holdsIdentity(lease);
}
