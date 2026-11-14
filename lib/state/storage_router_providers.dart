import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../data/storage/profile_storage_router.dart';
import '../data/storage/profile_storage_router_owner.dart';
import '../domain/storage_locator.dart';

final profileStorageRouterOwnerProvider = Provider<ProfileStorageRouterOwner?>(
  (_) => null,
);
final storageRouteRevisionProvider = StateProvider<int>((_) => 0);
final profileStorageRouterProvider = Provider<ProfileStorageRouter?>((ref) {
  ref.watch(storageRouteRevisionProvider);
  // A suspended managed owner throws: null is reserved for the legacy setup,
  // where callers may legitimately use a different storage provider.
  final owner = ref.watch(profileStorageRouterOwnerProvider);
  if (owner == null) return null;
  final subscription = owner.changes.listen((_) {
    if (ref.mounted) ref.invalidateSelf();
  });
  ref.onDispose(() => unawaited(subscription.cancel()));
  return owner.router;
});
final storageAccessLocatorProvider = Provider<IdentityStorageLocator>((ref) {
  ref.watch(storageRouteRevisionProvider);
  return ref.watch(profileStorageRouterProvider)?.access ??
      const LegacyStorageLocator();
});
