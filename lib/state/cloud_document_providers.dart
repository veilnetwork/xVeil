import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../data/transport/veil_mailbox.dart';
import '../domain/chat.dart';
import 'app_controller.dart';
import 'cloud_document_crypto.dart';
import 'cloud_document_envelope_service.dart';
import 'cloud_document_replication_service.dart';
import 'cloud_document_store.dart';
import 'messaging.dart';
import 'providers.dart';

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
        );
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
          signer: signer?.selfId == self ? signer : null,
        );
      }
      ref.onDispose(() {
        for (final entry in attached) {
          if (identical(entry.messaging.onCloudDocumentFrame, entry.handler)) {
            entry.messaging.onCloudDocumentFrame = null;
          }
          unawaited(entry.service.close());
        }
      });
      return selected;
    });
