import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_ffi.dart' as veil;

import '../core/ids.dart';
import '../data/node/space_discovery_transport.dart';
import 'app_controller.dart';
import 'cloud_capability_service.dart';
import 'group_service_providers.dart';
import 'providers.dart';
import 'public_directory_service.dart';

/// Lifecycle for the identity's public file directory. Null while locked or
/// before a signer exists; rebuilt on identity switch so a published pointer
/// never crosses deniable spaces. Started lazily (republish timer + restore).
final publicDirectoryServiceProvider = Provider<PublicDirectoryService?>((ref) {
  final selfId = ref.watch(
    appControllerProvider.select((state) => state.identity?.nodeId),
  );
  final signer = ref.watch(groupSignerProvider).value;
  if (selfId == null || signer == null || signer.selfId != selfId) {
    return null;
  }
  final storage = ref.watch(storageProvider);
  final capabilities = ref.watch(cloudCapabilityServiceProvider);
  final service = PublicDirectoryService(
    transport: NativeSpaceDiscoveryTransport(selfId),
    selfId: selfId,
    selfPublicKey: signer.selfPubKey,
    sign: signer.signDetached,
    verify: signer.verifyDetached,
    putSetting: storage.putSetting,
    getSetting: storage.getSetting,
    revokeShare: capabilities == null
        ? null
        : (shareId) async {
            await capabilities.revokeFolderShare(shareId);
          },
    resolveNickname: (nickname) async {
      final normalized = veil.normalizeNickname(nickname);
      if (normalized.isEmpty) return null;
      final resolved = await veil.resolveNicknameAsync(
        selfNodeId: selfId.bytes,
        name: normalized,
      );
      if (resolved == null) return null;
      final owner = resolved.ownerNodeId;
      if (owner.length != 32) return null;
      return NodeId(Uint8List.fromList(owner));
    },
  );
  ref.onDispose(service.close);
  return service;
});
