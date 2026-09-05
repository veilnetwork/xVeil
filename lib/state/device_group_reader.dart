import 'dart:typed_data';

import '../core/ids.dart';
import '../data/node/embedded_node.dart';
import '../data/storage/storage.dart';
import 'group_service.dart';

/// The devices of ONE identity, read from that identity's own container.
///
/// The device group has always been per-identity DATA — `devices.gid` and its
/// bundle live in the identity's storage. What did not exist was a way to read
/// it without that identity's live [GroupService], and only the ACTIVE identity
/// gets one. So everything that needed the device list for a non-active
/// identity had to answer with a constant, and the cloud capability slot
/// answered 0 — which is how two devices of a non-active identity, hosting the
/// same shared folder, registered as one provider and collided (report20
/// XV20-M9).
///
/// This is deliberately not a second implementation of that read.
/// [GroupService.deviceMembers] stays the one place that knows how a device
/// group folds; this builds an unstarted service over the given container and
/// asks it. The constructor does no work and starts nothing — no maintenance
/// loop, no epoch service, no message handlers — so an identity nobody is
/// looking at pays for a fold and a storage read, and nothing else.
///
/// Null when the identity has no node config yet, when the native signer is
/// unavailable (tests, a locked container), or when the read throws. A caller
/// that cannot learn the device list must fail closed rather than guess a slot.
Future<List<NodeId>?> deviceMembersOf({
  required Storage storage,
  required NodeId selfId,
}) async {
  try {
    final toml = await storage.loadNodeConfig();
    if (toml == null) return null;
    final Uint8List publicKey;
    try {
      publicKey = EmbeddedNode.signMessage(toml, Uint8List(0)).publicKey;
    } catch (_) {
      // No native library, or a config this build cannot sign with. Not an
      // error worth failing a boot over — the caller decides what to do with
      // "unknown".
      return null;
    }
    final service = GroupService(
      storage,
      NativeGroupSigner(
        identityToml: toml,
        selfId: selfId,
        selfPubKey: publicKey,
      ),
    );
    try {
      return await service.deviceMembers();
    } finally {
      service.dispose();
    }
  } catch (_) {
    return null;
  }
}
