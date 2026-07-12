import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../data/transport/veil_mailbox.dart';
import 'app_controller.dart';
import 'cloud_document_envelope_service.dart';
import 'cloud_document_replication_service.dart';
import 'cloud_document_store.dart';
import 'messaging.dart';
import 'providers.dart';

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
      final attached =
          <
            ({
              MessagingService messaging,
              void Function(NodeId, String) handler,
            })
          >[];

      CloudDocumentReplicationService attach({
        required NodeId nodeId,
        required MessagingService messaging,
        required Storage storage,
        required VeilMailboxCrypto crypto,
      }) {
        final service = CloudDocumentReplicationService(
          localNodeId: nodeId,
          ourCertVersion: 0,
          store: CloudDocumentStore(storage),
          envelopes: CloudDocumentEnvelopeService(crypto),
          sendFrame: messaging.sendCloudDocumentFrame,
        );
        void handler(NodeId peer, String frameJson) {
          unawaited(service.ingest(peer, frameJson));
        }

        messaging.onCloudDocumentFrame = handler;
        attached.add((messaging: messaging, handler: handler));
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
        );
      }
      ref.onDispose(() {
        for (final entry in attached) {
          if (identical(entry.messaging.onCloudDocumentFrame, entry.handler)) {
            entry.messaging.onCloudDocumentFrame = null;
          }
        }
      });
      return selected;
    });
