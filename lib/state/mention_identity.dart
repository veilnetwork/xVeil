import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../core/ids.dart';
import '../features/chat/message_mentions.dart';
import 'app_controller.dart';
import 'messaging.dart';
import 'nickname_peers.dart';
import 'providers.dart';

enum MentionIdentitySource { contact, dht, nodeId }

class MentionIdentityKey {
  const MentionIdentityKey(this.nodeHex, {this.dhtHint});

  final String nodeHex;
  final String? dhtHint;

  @override
  bool operator ==(Object other) =>
      other is MentionIdentityKey &&
      other.nodeHex == nodeHex &&
      other.dhtHint == dhtHint;

  @override
  int get hashCode => Object.hash(nodeHex, dhtHint);
}

class MentionIdentityLabel {
  const MentionIdentityLabel({
    required this.nodeId,
    required this.label,
    required this.source,
    this.dhtName,
  });

  final NodeId nodeId;
  final String label;
  final MentionIdentitySource source;
  final String? dhtName;
}

/// Resolve display data in the privacy-preserving order required by the UI:
/// local encrypted contact alias, verified DHT name, compact node id. The
/// canonical mention token always retains the full node id regardless of this
/// local presentation choice.
final mentionIdentityProvider =
    FutureProvider.family<MentionIdentityLabel, MentionIdentityKey>((
      ref,
      key,
    ) async {
      final nodeId = NodeId.fromHex(key.nodeHex);
      final conversations = ref.watch(conversationsProvider).value;
      if (conversations != null) {
        for (final conversation in conversations) {
          if (conversation.peer.nodeId == nodeId) {
            final alias = conversation.peer.name?.trim();
            if (alias != null && alias.isNotEmpty) {
              return MentionIdentityLabel(
                nodeId: nodeId,
                label: alias,
                source: MentionIdentitySource.contact,
              );
            }
            break;
          }
        }
      }
      // The conversation stream is optimized for visible rows and can be an
      // empty/partial snapshot during startup. The encrypted contact record is
      // the final local source for an alias and is never copied to the token.
      try {
        final contact = await ref.read(storageProvider).getContact(nodeId);
        final alias = contact?.name?.trim();
        if (alias != null && alias.isNotEmpty) {
          return MentionIdentityLabel(
            nodeId: nodeId,
            label: alias,
            source: MentionIdentitySource.contact,
          );
        }
      } catch (_) {}

      final identity = ref.watch(appControllerProvider).identity;
      if (identity?.nodeId == nodeId) {
        final ownDht = identity?.username?.trim().toLowerCase();
        if (ownDht != null && ownDht.isNotEmpty) {
          return MentionIdentityLabel(
            nodeId: nodeId,
            label: ownDht,
            source: MentionIdentitySource.dht,
            dhtName: ownDht,
          );
        }
      }

      final pinned = await ref.watch(peerNicknameProvider(nodeId.hex).future);
      if (pinned != null && !pinned.ownerChanged) {
        return MentionIdentityLabel(
          nodeId: nodeId,
          label: pinned.name,
          source: MentionIdentitySource.dht,
          dhtName: pinned.name,
        );
      }

      final hint = key.dhtHint?.trim().toLowerCase();
      if (hint != null && hint.isNotEmpty) {
        try {
          final normalized = veil.normalizeNickname(hint);
          final selfHex = await ref
              .read(messagingServiceProvider)
              .savedSelfHex();
          final Uint8List self = NodeId.fromHex(selfHex).bytes;
          final resolved = await veil.resolveNicknameAsync(
            selfNodeId: self,
            name: normalized,
            timeoutMs: 4000,
          );
          if (resolved != null && NodeId(resolved.ownerNodeId) == nodeId) {
            await savePeerNickname(
              ref.read(storageProvider),
              nodeId.hex,
              normalized,
            );
            return MentionIdentityLabel(
              nodeId: nodeId,
              label: normalized,
              source: MentionIdentitySource.dht,
              dhtName: normalized,
            );
          }
        } catch (_) {
          // Offline/unsupported lookup: never trust the sender's text hint; fall
          // through to the node id until the DHT proof can be obtained locally.
        }
      }

      return MentionIdentityLabel(
        nodeId: nodeId,
        label: nodeId.short,
        source: MentionIdentitySource.nodeId,
      );
    });

Future<String> resolveMentionsForLocalDisplay(
  WidgetRef ref,
  String body,
) async {
  final mentions = parseMessageMentions(body);
  if (mentions.isEmpty) return body;
  final labels = await Future.wait([
    for (final mention in mentions)
      ref
          .read(
            mentionIdentityProvider(
              MentionIdentityKey(mention.nodeId.hex, dhtHint: mention.dhtName),
            ).future,
          )
          .timeout(
            const Duration(milliseconds: 350),
            onTimeout: () => MentionIdentityLabel(
              nodeId: mention.nodeId,
              label: mention.nodeId.short,
              source: MentionIdentitySource.nodeId,
            ),
          ),
  ]);
  final out = StringBuffer();
  var cursor = 0;
  for (var index = 0; index < mentions.length; index++) {
    final mention = mentions[index];
    out
      ..write(body.substring(cursor, mention.start))
      ..write('@${labels[index].label}');
    cursor = mention.end;
  }
  out.write(body.substring(cursor));
  return out.toString();
}
