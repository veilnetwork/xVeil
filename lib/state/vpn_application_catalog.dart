import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/vpn/vpn_application_catalog.dart';

final vpnApplicationCatalogProvider = Provider<VpnApplicationCatalog>(
  (ref) => const MethodChannelVpnApplicationCatalog(),
);

final vpnApplicationsProvider = FutureProvider<List<VpnApplication>>(
  (ref) => ref.watch(vpnApplicationCatalogProvider).listApplications(),
);
