import 'managed_reclaim_budget.dart';

/// Optional maintenance of ONE independently owned identity. It preserves its
/// outer keys and never enumerates hidden spaces or rewrites sibling stores.
abstract interface class OwnedStorageReclamation {
  bool get supportsOwnedReclamation;
  Future<ManagedReclaimReport> reclaimOwnedStorage({bool force = false});
}
