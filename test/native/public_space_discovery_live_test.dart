import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/log.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/message_mention.dart';
import 'package:xveil/domain/space_invite.dart';
import 'package:xveil/features/chat/mentions_screen.dart';
import 'package:xveil/headless/headless_config.dart';
import 'package:xveil/headless/headless_runtime.dart';
import 'package:xveil/state/group_service.dart';

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _waitUntil(
  Future<bool> Function() predicate, {
  String reason = 'live public discovery did not converge',
  Duration timeout = const Duration(seconds: 90),
  Duration interval = const Duration(milliseconds: 300),
}) async {
  final until = DateTime.now().add(timeout);
  Object? lastError;
  while (DateTime.now().isBefore(until)) {
    try {
      if (await predicate()) return;
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(interval);
  }
  throw TimeoutException(
    lastError == null ? reason : '$reason (last error: $lastError)',
  );
}

Future<String> _metrics(int port) async {
  String? lastError;
  for (var attempt = 0; attempt < 30; attempt++) {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/metrics'),
      );
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode == HttpStatus.ok) return body;
      lastError = 'HTTP ${response.statusCode}';
    } catch (error) {
      lastError = '$error';
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('metrics endpoint $port unavailable: $lastError');
}

HeadlessConfig _config(String root, String label, int listenPort) =>
    HeadlessConfig(
      storePath: '$root/$label/store.hv',
      runtimeDir: '$root/$label/runtime',
      blobDir: '$root/$label/blobs',
      listenPort: listenPort,
      apiPort: 0,
      anonymous: false,
      bootstrapPeers: const [],
    );

Future<void> _preprovisionFastIdentity(
  HeadlessConfig config,
  String password,
  int fixtureIndex,
) async {
  await Directory(config.storePath).parent.create(recursive: true);
  final storage = HiddenVolumeStorage.async(
    workerSpaceOpener(config.storePath),
  );
  try {
    expect(
      await storage.open(password: password, createIfMissing: true),
      isTrue,
    );
    await storage.saveNodeConfig(
      await File(
        'test/native/fixtures/public_discovery_identity_$fixtureIndex.toml',
      ).readAsString(),
    );
  } finally {
    await storage.close();
  }
}

Future<void> _join(HeadlessRuntime joining, HeadlessRuntime target) async {
  final joiningTransport = joining.stack.transport as VeilFlutterTransport;
  final targetTransport = target.stack.transport as VeilFlutterTransport;
  await joiningTransport.joinInvite(await targetTransport.createInvite());
}

Future<bool> _containsBytes(Directory root, List<int> needle) async {
  if (needle.isEmpty || !await root.exists()) return false;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final bytes = await entity.readAsBytes();
    if (_indexOf(bytes, needle) >= 0) return true;
  }
  return false;
}

int _indexOf(Uint8List haystack, List<int> needle) {
  if (needle.length > haystack.length) return -1;
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[start + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return start;
  }
  return -1;
}

void main() {
  final enabled = Platform.environment['PUBLIC_SPACE_DISCOVERY_LIVE'] == '1';

  test(
    'three real nodes transfer authority, form holder quorum and navigate an exact public mention without plaintext telemetry',
    () async {
      // Native IPC uses Unix-domain sockets with a short platform path cap.
      final temp = await Directory(
        '/tmp',
      ).createTemp('xveil-public-discovery-live-');
      HeadlessRuntime? genesis;
      HeadlessRuntime? publisher;
      HeadlessRuntime? reader;
      String? plaintextCanary;
      final metricsPorts = <int>[];
      try {
        const password = 'public-discovery-live-password';
        const apiToken =
            'public-discovery-live-token-0123456789abcdef0123456789';
        for (var index = 0; index < 3; index++) {
          metricsPorts.add(await _freePort());
        }
        final genesisConfig = _config(temp.path, 'genesis', await _freePort());
        final publisherConfig = _config(
          temp.path,
          'publisher',
          await _freePort(),
        );
        final readerConfig = _config(temp.path, 'reader', await _freePort());
        await _preprovisionFastIdentity(genesisConfig, password, 0);
        await _preprovisionFastIdentity(publisherConfig, password, 1);
        await _preprovisionFastIdentity(readerConfig, password, 2);
        genesis = await HeadlessRuntime.start(
          config: genesisConfig,
          password: password,
          apiToken: apiToken,
          debugMetricsPort: metricsPorts[0],
          groupEpochCryptoOverride: LoopbackMailboxCrypto(),
        );
        final genesisNodeId =
            await (genesis.stack.transport as VeilFlutterTransport).nodeId();
        publisher = await HeadlessRuntime.start(
          config: publisherConfig,
          password: password,
          apiToken: apiToken,
          debugMetricsPort: metricsPorts[1],
          groupEpochCryptoOverride: LoopbackMailboxCrypto(
            senderForOpen: genesisNodeId,
          ),
        );
        reader = await HeadlessRuntime.start(
          config: readerConfig,
          password: password,
          apiToken: apiToken,
          debugMetricsPort: metricsPorts[2],
        );
        final owner = genesis;
        final nextOwner = publisher;
        final subscriber = reader;
        final ownerTransport = owner.stack.transport as VeilFlutterTransport;
        final publisherTransport =
            nextOwner.stack.transport as VeilFlutterTransport;
        final readerTransport =
            subscriber.stack.transport as VeilFlutterTransport;
        final ownerId = await ownerTransport.nodeId();
        final publisherId = await publisherTransport.nodeId();
        final readerId = await readerTransport.nodeId();

        await _join(nextOwner, owner);
        await _join(subscriber, owner);
        await _join(subscriber, nextOwner);
        await _waitUntil(
          () async =>
              (await ownerTransport.peers())
                      .where((peer) => peer.isActive)
                      .length >=
                  2 &&
              (await publisherTransport.peers())
                      .where((peer) => peer.isActive)
                      .length >=
                  2 &&
              (await readerTransport.peers())
                      .where((peer) => peer.isActive)
                      .length >=
                  2,
          reason: 'the three-node transport mesh did not become active',
        );
        await owner.messaging.sendRequest(
          publisherId,
          'public-discovery-live-membership',
        );
        await _waitUntil(
          () async =>
              (await nextOwner.storage.getContact(ownerId))?.status ==
              ContactStatus.pendingIncoming,
          reason: 'the future publisher did not receive the contact request',
        );
        await nextOwner.messaging.acceptContact(ownerId);
        await _waitUntil(
          () async =>
              (await owner.storage.getContact(publisherId))?.status ==
                  ContactStatus.accepted &&
              (await nextOwner.storage.getContact(ownerId))?.status ==
                  ContactStatus.accepted,
          reason: 'the publisher contact relationship did not converge',
        );

        final canary =
            'QzPrivacyCanary${DateTime.now().microsecondsSinceEpoch}';
        plaintextCanary = canary;
        final query = canary.toLowerCase();
        final spaceId = await owner.groups.createSpace(
          canary,
          description: 'Public discovery live boundary',
          visibility: SpaceVisibility.public,
          discoverable: true,
        );
        expect(await owner.groups.inviteToSpace(spaceId, publisherId), isTrue);
        PendingSpaceInvite? incomingInvite;
        await _waitUntil(() async {
          final pending = await nextOwner.groups.pendingSpaceInvites();
          for (final entry in pending) {
            if (entry.invite.spaceId == spaceId) incomingInvite = entry;
          }
          return incomingInvite != null;
        }, reason: 'the future publisher did not receive the Space proposal');
        await _waitUntil(
          () async {
            await nextOwner.groups.decideSpaceInvite(
              incomingInvite!.invite.inviteId,
              accept: true,
            );
            return await nextOwner.groups.load(spaceId) != null;
          },
          reason: 'the future publisher did not receive its member snapshot',
          timeout: const Duration(seconds: 45),
          interval: const Duration(seconds: 3),
        );

        final authored = await owner.groups.publishSpacePost(
          spaceId,
          title: 'Exact mention',
          body: 'Hello ${encodeMessageMention(readerId)}',
        );
        expect(authored, isNotNull);
        await _waitUntil(
          () async =>
              (await nextOwner.groups.load(
                spaceId,
              ))?.posts.any((post) => post.postId == authored!.postId) ==
              true,
          reason: 'the future publisher did not receive the public post',
        );

        expect(
          await owner.groups.transferSpaceOwnership(spaceId, publisherId),
          isTrue,
        );
        SpacePublicDiscoveryPublication? transferred;
        await _waitUntil(() async {
          transferred = await nextOwner.groups
              .buildSpacePublicDiscoveryPublication(spaceId);
          return transferred != null;
        }, reason: 'the transferred owner did not accept its authority chain');
        final publication = transferred!;
        expect(publication.discovery.descriptor.publisher, publisherId);
        expect(publication.discovery.descriptor.authorityGeneration, 1);
        expect(
          await owner.groups.buildSpacePublicDiscoveryPublication(spaceId),
          isNull,
          reason: 'the genesis publisher must be revoked immediately',
        );

        await _waitUntil(() async {
          final sweep = await nextOwner.groups.publishPublicSpaceDiscovery();
          return sweep.spacesPublished >= 1 && sweep.failures == 0;
        }, reason: 'the transferred publisher did not reach the native DHT');
        SpacePublicDiscoveryPublication? formerOwnerHolder;
        await _waitUntil(() async {
          formerOwnerHolder = await owner.groups
              .replicateVerifiedPublicSpaceDiscovery(
                publication.discovery.descriptor,
                [publication.discovery.holder],
              );
          return formerOwnerHolder?.discovery.holder.holder == ownerId;
        }, reason: 'the former owner did not verify and reseed the new feed');
        await _waitUntil(() async {
          final sweep = await owner.groups.publishPublicSpaceDiscovery();
          return sweep.spacesPublished >= 1 && sweep.failures == 0;
        }, reason: 'the former owner did not become an independent holder');

        SpacePublicDiscoverySearchOutcome? outcome;
        await _waitUntil(() async {
          outcome = await subscriber.groups.searchPublicSpaceDiscoveryOutcome(
            query,
            timeout: const Duration(seconds: 3),
          );
          return outcome!.status ==
                  SpacePublicDiscoverySearchStatus.available &&
              outcome!.results.length == 1 &&
              outcome!.results.single.holders.length >= 2;
        }, reason: 'global search did not reach a two-holder quorum');
        final result = outcome!.results.single;
        expect(result.descriptor.authorityGeneration, 1);
        expect({
          for (final holder in result.holders) holder.holder,
        }, containsAll(<Object>[ownerId, publisherId]));

        final subscription = await subscriber.groups
            .subscribeToPublicSpaceDiscovery(result);
        expect(subscription, isNotNull);
        expect(
          await subscriber.groups.load(spaceId),
          isNull,
          reason: 'public-only reading must not mint fake membership',
        );
        final mentioned = subscription!.feed.posts.singleWhere(
          (post) => post.postId == authored!.postId,
        );
        final inbox = publicSpacePostMentionInboxEntry(
          self: readerId,
          spaceId: spaceId,
          spaceName: subscription.descriptor.name,
          post: mentioned,
        );
        expect(inbox, isNotNull);
        expect(
          inbox!.route,
          '/space/${spaceId.hex}/public-posts?post='
          '${Uri.encodeQueryComponent(authored!.postId)}',
        );

        final telemetry = StringBuffer();
        for (final port in metricsPorts) {
          telemetry.writeln(await _metrics(port));
        }
        telemetry.writeln(devLogSnapshot(limit: 4000).lines.join('\n'));
        final telemetryLower = telemetry.toString().toLowerCase();
        expect(telemetryLower, isNot(contains(query)));
        expect(telemetryLower, isNot(contains(canary.toLowerCase())));
      } finally {
        await reader?.close();
        await publisher?.close();
        await genesis?.close();
      }

      // Runtime sockets/configs are deleted on close and durable stores are
      // encrypted. The scan is a final live guard against an accidental
      // plaintext side log or metric dump in the per-node directories.
      expect(await _containsBytes(temp, utf8.encode(plaintextCanary)), isFalse);
      expect(
        await _containsBytes(temp, utf8.encode(plaintextCanary.toLowerCase())),
        isFalse,
      );
      await temp.delete(recursive: true);
    },
    skip: enabled
        ? false
        : 'set PUBLIC_SPACE_DISCOVERY_LIVE=1 with both native dylibs',
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
