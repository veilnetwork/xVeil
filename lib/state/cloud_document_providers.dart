import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../data/transport/veil_mailbox.dart';
import '../domain/chat.dart';
import 'dart:typed_data';

import 'app_controller.dart';
import 'cloud_capability_service.dart' show VeilCloudCapabilityNetwork;
import 'cloud_document_crypto.dart';
import 'cloud_document_envelope_service.dart';
import 'cloud_document_replication_service.dart';
import 'cloud_document_store.dart';
import 'messaging.dart';
import 'cloud_capability_service.dart' show cloudProviderSlotFor;
import 'device_group_reader.dart';
import 'providers.dart';

/// Member content hosting reads and writes files through the same encrypted
/// store the personal cloud uses; this adapter narrows [Storage] to the port
/// the replication service's coordinator needs.
class _StorageMemberFolderAdapter implements CloudMemberFolderStoragePort {
  _StorageMemberFolderAdapter(this._storage);
  final Storage _storage;

  @override
  Future<Uint8List?> readFileRange(String contentId, int offset, int length) =>
      _storage.readFileRange(contentId, offset, length);

  @override
  Future<bool> hasFile(String contentId) => _storage.hasFile(contentId);

  @override
  Future<void> storeFile(String contentId, Uint8List bytes, {String? name}) =>
      _storage.storeFile(contentId, bytes, name: name);

  @override
  Future<void> storeFilePiece(
    String contentId,
    int pieceIndex,
    int pieceCount,
    int pieceSize,
    int totalSize,
    Uint8List bytes, {
    String? name,
  }) => _storage.storeFilePiece(
    contentId,
    pieceIndex,
    pieceCount,
    pieceSize,
    totalSize,
    bytes,
    name: name,
  );
}

/// Mutation signer for the identity currently visible in the UI. In all-online
/// mode every hosted identity still receives frames, but only the active
/// identity gets a signer/control surface; switching rebuilds it from that
/// identity's deniable node config.
final cloudDocumentSignerProvider = FutureProvider<CloudDocumentSigner?>((
  ref,
) async {
  final self = ref.watch(
    appControllerProvider.select((state) => state.identity?.nodeId),
  );
  if (self == null) return null;
  final toml = await ref.read(storageProvider).loadNodeConfig();
  if (toml == null) return null;
  return NativeCloudDocumentSigner(identityToml: toml, selfId: self);
});

/// Production lifecycle for CLOUD-3B2 replication. Null while locked; rebuilt
/// on identity switch so keys and pending invites never cross deniable spaces.
final cloudDocumentReplicationServiceProvider =
    Provider<CloudDocumentReplicationService?>((ref) {
      final self = ref.watch(
        appControllerProvider.select((state) => state.identity?.nodeId),
      );
      if (self == null) return null;
      final session = ref.watch(sessionProvider);
      final active = ref.watch(activeIdentityProvider);
      final signer = ref.watch(cloudDocumentSignerProvider).value;
      final attached =
          <
            ({
              MessagingService messaging,
              Future<bool> Function(NodeId, String) handler,
              CloudDocumentReplicationService service,
            })
          >[];

      CloudDocumentReplicationService attach({
        required NodeId nodeId,
        required MessagingService messaging,
        required Storage storage,
        required VeilMailboxCrypto crypto,
        required VeilFlutterTransport? transport,
        CloudDocumentSigner? signer,
      }) {
        final service = CloudDocumentReplicationService(
          localNodeId: nodeId,
          // Runtime publishes the active per-instance ML-KEM cert as v1.
          ourCertVersion: 1,
          store: CloudDocumentStore(storage),
          envelopes: CloudDocumentEnvelopeService(crypto),
          sendFrame: messaging.sendCloudDocumentFrame,
          signer: signer,
          acceptedContact: (peer) async =>
              (await storage.getContact(peer))?.status ==
              ContactStatus.accepted,
          // Member content hosting for shared ACL folders. Loopback/test
          // transports leave the ports null: metadata replication works, no
          // bytes are served.
          memberContentNetwork: transport == null
              ? null
              : VeilCloudCapabilityNetwork(transport),
          memberContentStorage: _StorageMemberFolderAdapter(storage),
          // Slot 0 until the device group is known. Every device of an identity
          // derives the SAME member host seed and alias (both come from
          // documentId + epochKey), so a distinct slot is the only thing that
          // keeps two sovereign devices from registering as one provider — but
          // the device list lives in GroupService, which already watches THIS
          // provider to keep ingress alive. Reading it back here would close a
          // dependency cycle, so groupServiceProvider installs the real
          // resolver via [CloudDocumentReplicationService.memberProviderSlot]
          // once it is built.
          // NOT a constant any more. Only the ACTIVE identity gets a
          // GroupService, so every other identity kept slot 0 — and two
          // devices of one of them, hosting the same shared folder, registered
          // as ONE provider and collided (report20 XV20-M9). The device group
          // is per-identity DATA and always was; what was missing was a way to
          // read it without that identity's live service, and
          // [deviceMembersOf] is that — over the same
          // `GroupService.deviceMembers`, so there is no second implementation
          // to drift.
          //
          // FAIL CLOSED on "unknown": a slot guessed from an unread device
          // list is the collision this exists to stop. `null` from the
          // resolver leaves hosting unregistered rather than registering it
          // wrongly, and a single-device identity answers 0 through the
          // ordinary path because its device list is empty.
          memberProviderSlot: () async {
            final devices = await deviceMembersOf(
              storage: storage,
              selfId: nodeId,
            );
            if (devices == null) return null;
            return cloudProviderSlotFor(nodeId, devices);
          },
        );
        unawaited(service.reconcileMemberHosting());
        Future<bool> handler(NodeId peer, String frameJson) async {
          try {
            // Invalid/unauthorized input is a terminal silent drop (ACK it so
            // the sender does not retry forever). A thrown storage failure is
            // retryable: Messaging deliberately withholds the durable ACK.
            await service.ingest(peer, frameJson);
            return true;
          } catch (_) {
            return false;
          }
        }

        messaging.onCloudDocumentFrame = handler;
        attached.add((
          messaging: messaging,
          handler: handler,
          service: service,
        ));
        return service;
      }

      CloudDocumentReplicationService? selected;
      if (session != null) {
        for (final label in session.labels) {
          final stack = session.stackFor(label);
          final messaging = session.messagingFor(label);
          final storage = session.storageFor(label);
          if (stack == null || messaging == null || storage == null) continue;
          final transport = stack.transport;
          final crypto = transport is VeilFlutterTransport
              ? transport.mailboxCrypto()
              : LoopbackMailboxCrypto(senderForOpen: stack.myInvite.nodeId);
          final service = attach(
            nodeId: stack.myInvite.nodeId,
            messaging: messaging,
            storage: storage,
            crypto: crypto,
            transport: transport is VeilFlutterTransport ? transport : null,
            signer: label == active && signer?.selfId == stack.myInvite.nodeId
                ? signer
                : null,
          );
          if (label == active) selected = service;
        }
      } else {
        final messaging = ref.read(messagingServiceProvider);
        final transport = ref.watch(veilTransportProvider);
        selected = attach(
          nodeId: self,
          messaging: messaging,
          storage: ref.watch(storageProvider),
          crypto: transport is VeilFlutterTransport
              ? transport.mailboxCrypto()
              : LoopbackMailboxCrypto(senderForOpen: self),
          transport: transport is VeilFlutterTransport ? transport : null,
          signer: signer?.selfId == self ? signer : null,
        );
      }
      ref.onDispose(() {
        for (final entry in attached) {
          // `==`, not `identical`: Dart leaves it unspecified whether two
          // closures of the same function are the same object, and the same
          // check written with `identical` in the model-exchange service was
          // false every time — leaving a handler installed on a pipeline that
          // had moved on. Equality is what "still ours" means here.
          if (entry.messaging.onCloudDocumentFrame == entry.handler) {
            entry.messaging.onCloudDocumentFrame = null;
          }
          unawaited(entry.service.close());
        }
      });
      return selected;
    });
