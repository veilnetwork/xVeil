import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../data/storage/profile_storage_router.dart';
import '../domain/storage_locator.dart';

final profileStorageRouterProvider = Provider<ProfileStorageRouter?>(
  (_) => null,
);
final storageRouteRevisionProvider = StateProvider<int>((_) => 0);
final storageAccessLocatorProvider = Provider<IdentityStorageLocator>((ref) {
  ref.watch(storageRouteRevisionProvider);
  return ref.watch(profileStorageRouterProvider)?.access ??
      const LegacyStorageLocator();
});
