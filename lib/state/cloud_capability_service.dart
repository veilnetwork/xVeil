import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../core/serve_admission.dart';
import '../data/storage/storage.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/cloud.dart';
import '../domain/cloud_capability.dart';
import '../domain/content_manifest.dart';
import '../domain/device_sync.dart';
import 'cloud_folder_share.dart';
import 'group_service_providers.dart';
import 'providers.dart';

/// Bridges the app [Storage] into the folder-share host's minimal read surface.
class _FolderShareStorageAdapter implements CloudFolderShareStorage {
  _FolderShareStorageAdapter(this._storage);
  final Storage _storage;
  @override
  Future<Uint8List?> readFileRange(String contentId, int offset, int length) =>
      _storage.readFileRange(contentId, offset, length);
}

/// Public handle to one hosted folder bearer share.
class CloudFolderShareInfo {
  const CloudFolderShareInfo({
    required this.shareId,
    required this.folderId,
    required this.folderName,
    required this.link,
    required this.listingRevision,
    required this.expiresAtMs,
  });
  final String shareId;
  final String folderId;
  final String folderName;
  final String link;
  final int listingRevision;
  final int expiresAtMs;
}

abstract interface class CloudCapabilitySyncPort {
  NodeId get selfId;
  Stream<void> get changes;
  Future<List<NodeId>> members();
  Future<List<DeviceSyncRecord>> records();
  Future<bool> post(DeviceSyncEvent event);
  Future<void> close();
}

class GroupCloudCapabilitySyncPort implements CloudCapabilitySyncPort {
  GroupCloudCapabilitySyncPort(this._group) {
    _listener = () {
      if (!_changes.isClosed) _changes.add(null);
    };
    _group.changes.addListener(_listener);
  }
  final GroupService _group;
  final StreamController<void> _changes = StreamController.broadcast();
  late final void Function() _listener;
  @override
  NodeId get selfId => _group.selfId;
  @override
  Stream<void> get changes => _changes.stream;
  @override
  Future<List<NodeId>> members() => _group.deviceMembers();
  @override
  Future<List<DeviceSyncRecord>> records() => _group.deviceSyncRecords();
  @override
  Future<bool> post(DeviceSyncEvent event) => _group.postDeviceEvent(event);
  @override
  Future<void> close() async {
    _group.changes.removeListener(_listener);
    unawaited(_changes.close());
  }
}

abstract interface class CloudCapabilityEndpointPort {
  Uint8List get servicePublicKey;
  Uint8List get appId;
  int get endpointId;
  Stream<Uint8List> get messages;
  Future<void> sendAnonymous({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List data,
  });
  Future<void> close();
}

/// This device's provider slot within its own device group.
///
/// Every device of a sovereign identity derives the SAME hosting seed and
/// alias (they are a function of the shared secret, not of the device), so the
/// slot is the only thing that keeps two of them from registering as the same
/// provider. It is the device's index in the hex-sorted device list, which is
/// stable and needs no coordination: each device computes its own from the
/// group it already syncs.
///
/// The slot does NOT enter the onion identity — the service public key comes
/// from the seed alone and clients address a host by alias + endpointId — so a
/// non-zero slot stays reachable by every client.
///
/// Returns 0 when there is no device group (single-device identity, loopback
/// and test transports). Throws past [kCloudProviderSlotLimit] devices: beyond
/// that the registrations could not be told apart, so failing closed beats
/// silently colliding.
const int kCloudProviderSlotLimit = 8;

/// [selfId]'s index among the hex-sorted union of itself and [devices].
///
/// Kept separate from [cloudProviderSlot] so a caller holding a device list
/// (rather than a sync port) computes the SAME slot — two implementations of
/// this would be free to drift, and a drifted slot is a silent provider
/// collision.
int cloudProviderSlotFor(NodeId selfId, Iterable<NodeId> devices) {
  final byHex = <String>{selfId.hex};
  for (final device in devices) {
    byHex.add(device.hex);
  }
  final ordered = byHex.toList()..sort();
  final slot = ordered.indexOf(selfId.hex);
  if (slot < 0 || slot >= kCloudProviderSlotLimit) {
    throw StateError('capability provider device limit reached');
  }
  return slot;
}

Future<int> cloudProviderSlot(CloudCapabilitySyncPort? sync) async {
  if (sync == null) return 0;
  return cloudProviderSlotFor(sync.selfId, await sync.members());
}

abstract interface class CloudCapabilityNetworkPort {
  /// [extraProviderSlots] asks for that many ADDITIONAL introduction points to
  /// this same node, each on its own rendezvous relay. A sender can then
  /// round-robin a FRAGMENTED reply across them instead of funnelling
  /// redundant copies of every fragment through one relay. Each costs a
  /// circuit build, so only a caller expecting BULK replies should ask.
  /// Honoured on the transient path only.
  Future<CloudCapabilityEndpointPort> host({
    required Uint8List identitySeed,
    required String alias,
    required int endpointId,
    required int providerSlot,
    bool transient = false,
    int extraProviderSlots = 0,
  });

  /// The capability appId for [alias] WITHOUT hosting or registering
  /// anything. Used by a member content client to address a host whose alias
  /// it derives from the document's current epoch key.
  Future<Uint8List> capabilityAppId({
    required String alias,
    required int endpointId,
  });
}

class VeilCloudCapabilityNetwork implements CloudCapabilityNetworkPort {
  VeilCloudCapabilityNetwork(this._transport);
  final VeilFlutterTransport _transport;

  @override
  Future<CloudCapabilityEndpointPort> host({
    required Uint8List identitySeed,
    required String alias,
    required int endpointId,
    required int providerSlot,
    bool transient = false,
    int extraProviderSlots = 0,
  }) async => _VeilCapabilityEndpointPort(
    await (transient
        ? _transport.hostTransientCapabilityEndpoint(
            identitySeed: identitySeed,
            name: alias,
            endpointId: endpointId,
            providerSlot: providerSlot,
            extraProviderSlots: extraProviderSlots,
          )
        : _transport.hostCapabilityEndpoint(
            identitySeed: identitySeed,
            name: alias,
            endpointId: endpointId,
            providerSlot: providerSlot,
          )),
  );

  @override
  Future<Uint8List> capabilityAppId({
    required String alias,
    required int endpointId,
  }) => _transport.capabilityAppId(name: alias, endpointId: endpointId);
}

class _VeilCapabilityEndpointPort implements CloudCapabilityEndpointPort {
  _VeilCapabilityEndpointPort(this._endpoint);
  final VeilCapabilityEndpoint _endpoint;

  @override
  Uint8List get servicePublicKey => _endpoint.servicePublicKey;
  @override
  Uint8List get appId => _endpoint.appId;
  @override
  int get endpointId => _endpoint.endpointId;
  @override
  Stream<Uint8List> get messages => _endpoint.messages;
  @override
  Future<void> sendAnonymous({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List data,
  }) => _endpoint.sendAnonymous(
    servicePublicKey: servicePublicKey,
    targetAppId: targetAppId,
    targetEndpointId: targetEndpointId,
    data: data,
  );
  @override
  Future<void> close() => _endpoint.close();
}

class CloudPublicShare {
  const CloudPublicShare({
    required this.shareId,
    required this.itemId,
    required this.contentId,
    required this.link,
    required this.expiresAtMs,
  });

  final String shareId;
  final String itemId;
  final String contentId;
  final String link;
  final int expiresAtMs;
}

class CloudCapabilityService {
  CloudCapabilityService(
    this._storage,
    this._network, {
    CloudCapabilitySyncPort? sync,
    DateTime Function()? now,
    Random? random,
    // Per-chunk wait over the anonymous onion path: must cover our own
    // request-send circuit build (~5 s) plus the host's reply. See the
    // matching 30 s budget on the bearer download loop.
    Duration folderClientTimeout = const Duration(seconds: 30),
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure(),
       // ignore: prefer_initializing_formals
       _folderClientTimeout = folderClientTimeout,
       // ignore: prefer_initializing_formals
       _sync = sync;

  final Duration _folderClientTimeout;

  static const _registrySetting = 'cloud.capabilities.v1';
  static const _eventsSetting = 'cloud.capability.events.v1';
  static const _registryFile = 'cloud.capabilities.registry.v2';
  static const _eventsFile = 'cloud.capability.events.v2';
  static const _folderRegistryFile = 'cloud.folder.capabilities.registry.v1';
  static const _folderRegistrySetting = 'cloud.folder.capabilities.v1';
  static const _manifestPrefix = 'mf:';
  static const _providerEndpointBase = 40;
  static const _returnEndpointId = 48;
  static const maxActiveShares = 6;
  static const maxShareHistory = 256;
  static const defaultLifetime = Duration(days: 7);

  final Storage _storage;
  final CloudCapabilityNetworkPort _network;
  final DateTime Function() _now;
  final Random _random;
  final CloudCapabilitySyncPort? _sync;
  final Map<String, _HostedShare> _shares = {};
  final Map<String, _RegistryRow> _rows = {};
  final Map<String, CloudCapability> _capabilities = {};
  // Folder bearer shares are LOCAL-hosted only in v1: a folder link is an
  // anonymous bearer capability, so the holder need not be in the owner's
  // device group and no cross-device rehost is required for the core feature.
  // Rows persist locally so hosting survives restart; sharing the same
  // provider-endpoint pool and slot budget as file shares.
  final Map<String, _HostedFolderShare> _folderShares = {};
  final Map<String, _FolderRegistryRow> _folderRows = {};
  final Map<String, CloudFolderCapability> _folderCaps = {};
  final Map<String, DeviceSyncEvent> _events = {};
  final Map<int, Future<void>> _retiringEndpoints = {};
  StreamSubscription<void>? _syncSubscription;
  Timer? _syncTimer;
  Future<void>? _started;
  Future<void> _mutation = Future.value();
  bool _closed = false;
  int _lastTimestamp = 0;

  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    // The event log is read FIRST, because it is the authority on what was
    // revoked; the registry is only what was last written. Hosting from the
    // registry and consulting the log afterwards meant a revoked share was
    // served again from the moment the app opened until the first reconcile —
    // and if its row had survived a crash, served for its whole lifetime.
    await _loadEvents();
    final raw = await _loadMetadata(_registryFile, _registrySetting);
    final keep = <_RegistryRow>[];
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final value in decoded.take(maxActiveShares)) {
            final row = _RegistryRow.parse(value);
            if (row == null) continue;
            CloudCapability capability;
            try {
              capability = await CloudCapabilityCodec.parse(row.link);
            } catch (_) {
              continue;
            }
            if (capability.expiresAtMs <= _now().millisecondsSinceEpoch ||
                !_validProviderEndpoint(capability.endpointId)) {
              continue;
            }
            final key = _shareKey(capability.shareId);
            // A tombstone outranks a row still sitting in the registry: that
            // is what a crash between a revoke's two writes leaves behind.
            if (_events[key]?.payload['deleted'] == true) continue;
            _rows[key] = row;
            _capabilities[key] = capability;
            try {
              await _host(row, capability);
            } catch (_) {
              // Network may not be ready yet. Keep the encrypted row so the
              // next reconcile/unlock can retry; unhosted reveals nothing.
            }
            keep.add(row);
          }
        }
      } catch (_) {}
    }
    await _saveRows(keep);
    for (final entry in _rows.entries) {
      if (!_events.containsKey(entry.key)) {
        await _recordCapabilityEvent(
          entry.key,
          deleted: false,
          row: entry.value,
        );
      }
    }
    await _reconcileSync();
    final sync = _sync;
    if (sync != null) {
      _syncSubscription = sync.changes.listen((_) {
        _syncTimer?.cancel();
        _syncTimer = Timer(
          const Duration(milliseconds: 250),
          () => unawaited(_serialized(_reconcileSync)),
        );
      });
    }
    await _loadFolderShares();
  }

  /// Re-host every persisted folder bearer share. A row whose network host
  /// fails is kept encrypted for the next unlock; unhosted reveals nothing.
  Future<void> _loadFolderShares() async {
    final raw = await _loadMetadata(
      _folderRegistryFile,
      _folderRegistrySetting,
    );
    if (raw == null) return;
    final keep = <_FolderRegistryRow>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final value in decoded.take(maxActiveShares)) {
        final row = _FolderRegistryRow.parse(value);
        if (row == null) continue;
        final listing = CloudFolderListing.fromJson(row.listingJson);
        CloudFolderCapability capability;
        try {
          final parsed = await CloudCapabilityCodec.parseLink(row.link);
          if (parsed is! ParsedCloudFolderLink) continue;
          capability = parsed.capability;
        } catch (_) {
          continue;
        }
        if (listing == null ||
            capability.expiresAtMs <= _now().millisecondsSinceEpoch ||
            !_validProviderEndpoint(capability.endpointId)) {
          continue;
        }
        final key = _shareKey(capability.shareId);
        _folderRows[key] = row;
        _folderCaps[key] = capability;
        try {
          await _hostFolder(row, capability, listing);
        } catch (_) {}
        keep.add(row);
      }
    } catch (_) {}
    _folderRows.removeWhere(
      (key, row) => !keep.any((kept) => identical(kept, row)),
    );
    await _saveFolderRows();
  }

  Future<void> _hostFolder(
    _FolderRegistryRow row,
    CloudFolderCapability capability,
    CloudFolderListing listing,
  ) async {
    final seed = _decode32(row.seed);
    CloudCapabilityEndpointPort? endpoint;
    try {
      final providerSlot = await _providerSlot();
      endpoint = await _network.host(
        identitySeed: seed,
        alias: row.alias,
        endpointId: capability.endpointId,
        providerSlot: providerSlot,
      );
      if (!_equal(endpoint.servicePublicKey, capability.servicePublicKey) ||
          !_equal(endpoint.appId, capability.appId) ||
          endpoint.endpointId != capability.endpointId) {
        throw StateError('folder capability endpoint mismatch');
      }
      final host = CloudFolderShareHost(
        capability: capability,
        storage: _FolderShareStorageAdapter(_storage),
        listing: listing,
        send: endpoint.sendAnonymous,
        now: _now,
      );
      final hosted = _HostedFolderShare(
        row,
        capability,
        endpoint,
        host,
        providerSlot,
      );
      hosted.listen();
      await _installFolder(_shareKey(capability.shareId), hosted);
      // A STORED listing that will not seal must not cost the share its host.
      // It used to: the throw closed the endpoint and the row stayed in the
      // registry with nothing hosting it, so `refreshFolderShare` answered
      // "unknown share" and every restart repeated the same failure — the
      // share could not serve and could not be replaced either (audit XV-18).
      // Host it silent instead: it publishes nothing until a listing that CAN
      // be sealed replaces it, and replacing it is now possible.
      try {
        await host.ready;
      } catch (error) {
        devLog(
          () =>
              'xVeil[cloud]: stored folder listing rev '
              '${row.listingRevision} could not be sealed ($error) — hosting '
              'the share silent so it can be republished',
        );
      }
    } catch (_) {
      await endpoint?.close();
      rethrow;
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  Future<List<CloudPublicShare>> listShares() async {
    await start();
    return [
      for (final entry in _capabilities.entries)
        CloudPublicShare(
          shareId: entry.key,
          itemId: _rows[entry.key]!.itemId,
          contentId: _rows[entry.key]!.contentId,
          link: _rows[entry.key]!.link,
          expiresAtMs: entry.value.expiresAtMs,
        ),
    ];
  }

  Future<CloudPublicShare> createShare(
    CloudItem item, {
    Duration lifetime = defaultLifetime,
  }) async {
    await start();
    return _serialized(() async {
      if (_closed ||
          item.deleted ||
          item.contentId == null ||
          lifetime <= Duration.zero) {
        throw StateError('cloud item cannot be shared');
      }
      if (_rows.length + _folderRows.length >= maxActiveShares) {
        throw StateError('public share limit reached');
      }
      if (_events.length >= maxShareHistory) {
        throw StateError('public share history limit reached');
      }
      if (!await _storage.hasFile(item.contentId!)) {
        throw StateError('cloud item is not stored locally');
      }
      final manifestRaw = await _storage.loadFile(
        '$_manifestPrefix${item.contentId}',
      );
      if (manifestRaw == null) throw StateError('cloud manifest is missing');
      final manifest = _decodeManifest(manifestRaw);
      if (manifest == null || manifest.contentId != item.contentId) {
        throw StateError('cloud manifest is invalid');
      }

      final seed = _randomBytes(32);
      final storedSeed = Uint8List.fromList(seed);
      final alias = _base64(_randomBytes(32));
      final endpointId = _allocateProviderEndpoint();
      CloudCapabilityEndpointPort? endpoint;
      try {
        final providerSlot = await _providerSlot();
        endpoint = await _network.host(
          identitySeed: seed,
          alias: alias,
          endpointId: endpointId,
          providerSlot: providerSlot,
        );
        if (!seed.every((byte) => byte == 0)) {
          throw StateError('native capability seed was not scrubbed');
        }
        final expiresAtMs = _now().add(lifetime).millisecondsSinceEpoch;
        final link = await CloudCapabilityCodec.create(
          manifest: manifest,
          revision: item.revision,
          expiresAtMs: expiresAtMs,
          servicePublicKey: endpoint.servicePublicKey,
          appId: endpoint.appId,
          endpointId: endpoint.endpointId,
          mime: item.mime,
          random: _random,
        );
        final capability = await CloudCapabilityCodec.parse(link);
        final row = _RegistryRow(
          itemId: item.id,
          contentId: item.contentId!,
          seed: _base64(storedSeed),
          alias: alias,
          link: link,
        );
        final hosted = _HostedShare(row, capability, endpoint, providerSlot);
        _listen(hosted);
        final shareKey = _shareKey(capability.shareId);
        await _install(shareKey, hosted);
        _rows[shareKey] = row;
        _capabilities[shareKey] = capability;
        try {
          await _saveCurrentRows();
          await _recordCapabilityEvent(shareKey, deleted: false, row: row);
        } catch (_) {
          _shares.remove(shareKey);
          _rows.remove(shareKey);
          _capabilities.remove(shareKey);
          await hosted.close();
          rethrow;
        }
        return hosted.public;
      } catch (_) {
        await endpoint?.close();
        rethrow;
      } finally {
        seed.fillRange(0, seed.length, 0);
        storedSeed.fillRange(0, storedSeed.length, 0);
      }
    });
  }

  Future<bool> revoke(String shareId) async {
    await start();
    return _serialized(() async {
      if (!_rows.containsKey(shareId)) return false;
      // The tombstone goes down BEFORE the active row comes out.
      //
      // The registry says what was last written; the event log says what was
      // revoked, and a restart reads the log to decide. Taking the row out
      // first and recording the tombstone after left a window where the log
      // still held the OLD active row — and if that write then failed, the
      // window never closed: the next start folded the stale row and re-hosted
      // the very capability the person had just withdrawn, for the rest of its
      // lifetime, which defaults to seven days.
      //
      // In this order a crash in the middle leaves a tombstone and a row that
      // is still in the registry, and `_start` reads the log before it hosts
      // anything, so the row is never served. The opposite order had no such
      // safe middle.
      if (!await _recordCapabilityEvent(shareId, deleted: true)) return false;
      final hosted = _shares.remove(shareId);
      _rows.remove(shareId);
      _capabilities.remove(shareId);
      // Drop the request handler before any awaited write so revoke takes
      // effect immediately and invalid probes remain silent. Descriptor
      // withdrawal can wait on the native rendezvous mutex for tens of
      // seconds, so retire that endpoint in the background and do not make
      // the user wait for network housekeeping.
      await hosted?.stopAccepting();
      if (hosted != null) _retire(hosted);
      await _saveCurrentRows();
      await _storage.scrubDeleted();
      return true;
    });
  }

  List<CloudFolderShareInfo> listFolderShares() => [
    for (final entry in _folderCaps.entries)
      CloudFolderShareInfo(
        shareId: entry.key,
        folderId: _folderRows[entry.key]!.folderId,
        folderName: _folderRows[entry.key]!.folderName,
        link: _folderRows[entry.key]!.link,
        listingRevision: _folderRows[entry.key]!.listingRevision,
        expiresAtMs: entry.value.expiresAtMs,
      ),
  ];

  /// Host a bearer share for one folder. [entries] is the folder's listing
  /// tree built by the caller (recursive, locally-present files only). One
  /// endpoint and one slot are consumed; the link pins listing revision 1 as
  /// the holder's rollback floor.
  Future<CloudFolderShareInfo> createFolderShare({
    required String folderId,
    required String folderName,
    required List<CloudFolderListingEntry> entries,
    Duration lifetime = defaultLifetime,
  }) async {
    await start();
    return _serialized(() async {
      if (_closed || lifetime <= Duration.zero) {
        throw StateError('folder cannot be shared');
      }
      if (_rows.length + _folderRows.length >= maxActiveShares) {
        throw StateError('public share limit reached');
      }
      final listing = CloudFolderListing(
        name: folderName,
        revision: 1,
        entries: entries,
      );
      if (CloudFolderListing.fromJson(listing.toJson()) == null) {
        throw StateError('folder listing is invalid or too large');
      }
      final seed = _randomBytes(32);
      final storedSeed = Uint8List.fromList(seed);
      final alias = _base64(_randomBytes(32));
      final endpointId = _allocateProviderEndpoint();
      CloudCapabilityEndpointPort? endpoint;
      try {
        final providerSlot = await _providerSlot();
        endpoint = await _network.host(
          identitySeed: seed,
          alias: alias,
          endpointId: endpointId,
          providerSlot: providerSlot,
        );
        if (!seed.every((byte) => byte == 0)) {
          throw StateError('native capability seed was not scrubbed');
        }
        final expiresAtMs = _now().add(lifetime).millisecondsSinceEpoch;
        final link = await CloudCapabilityCodec.createFolder(
          folderName: folderName,
          listingRevision: 1,
          expiresAtMs: expiresAtMs,
          servicePublicKey: endpoint.servicePublicKey,
          appId: endpoint.appId,
          endpointId: endpoint.endpointId,
          random: _random,
        );
        final capability =
            (await CloudCapabilityCodec.parseLink(link))
                as ParsedCloudFolderLink;
        final row = _FolderRegistryRow(
          folderId: folderId,
          folderName: folderName,
          seed: _base64(storedSeed),
          alias: alias,
          link: link,
          listingRevision: 1,
          listingJson: listing.toJson(),
        );
        final host = CloudFolderShareHost(
          capability: capability.capability,
          storage: _FolderShareStorageAdapter(_storage),
          listing: listing,
          send: endpoint.sendAnonymous,
          now: _now,
        );
        await host.ready;
        final hosted = _HostedFolderShare(
          row,
          capability.capability,
          endpoint,
          host,
          providerSlot,
        );
        hosted.listen();
        final shareKey = _shareKey(capability.capability.shareId);
        await _installFolder(shareKey, hosted);
        _folderRows[shareKey] = row;
        _folderCaps[shareKey] = capability.capability;
        try {
          await _saveFolderRows();
        } catch (_) {
          _folderShares.remove(shareKey);
          _folderRows.remove(shareKey);
          _folderCaps.remove(shareKey);
          await hosted.close();
          rethrow;
        }
        return hosted.public;
      } catch (_) {
        await endpoint?.close();
        rethrow;
      } finally {
        seed.fillRange(0, seed.length, 0);
        storedSeed.fillRange(0, storedSeed.length, 0);
      }
    });
  }

  /// Republish a folder share with a fresh listing tree (revision bumped). A
  /// file removed from [entries] stops being served the instant the host
  /// swaps its listing. Returns false if the share is unknown.
  Future<bool> refreshFolderShare(
    String shareId, {
    required String folderName,
    required List<CloudFolderListingEntry> entries,
  }) async {
    await start();
    return _serialized(() async {
      final hosted = _folderShares[shareId];
      final row = _folderRows[shareId];
      if (hosted == null || row == null) return false;
      final nextRevision = row.listingRevision + 1;
      final listing = CloudFolderListing(
        name: folderName,
        revision: nextRevision,
        entries: entries,
      );
      if (CloudFolderListing.fromJson(listing.toJson()) == null) {
        throw StateError('folder listing is invalid or too large');
      }
      // SEAL IT FIRST — and throw here, before anything durable moves.
      //
      // The structural check above counts entries; the 256 KiB ceiling is on
      // the CIPHERTEXT, and long names carry a listing past it with an entry
      // count well under the cap. The old order wrote the row, then discovered
      // the refusal, and the damage was not the failed publish: the share
      // stopped answering with the listing it was ALREADY serving, the durable
      // row named a revision whose bytes could never exist, and a restart
      // re-read that row, failed to host it, and left the share registered
      // with nothing hosting it — which is also what made `refreshFolderShare`
      // answer "unknown share" from then on. Unrepairable, permanently
      // (audit XV-18).
      //
      // Sealing is deterministic in (key, revision, listing), so the seal the
      // host performs a few lines below produces these exact bytes.
      await CloudCapabilityCodec.sealListing(
        capability: hosted.capability,
        listing: listing,
      );
      // Persist the bumped revision + new listing BEFORE serving the new
      // sealed ciphertext. The listing nonce is derived from the revision, so
      // a crash after serving but before persisting would let the next
      // refresh reuse revision N+1 for DIFFERENT content — an AEAD key+nonce
      // reuse. Persisting first guarantees the durable revision is >= any
      // revision whose ciphertext was ever served, and a restart re-seals the
      // identical persisted listing under the same nonce (byte-identical, so
      // no reuse).
      final updated = row.copyWith(
        folderName: folderName,
        listingRevision: nextRevision,
        listingJson: listing.toJson(),
      );
      _folderRows[shareId] = updated;
      hosted.row = updated;
      await _saveFolderRows();
      await hosted.host.setListing(listing);
      return true;
    });
  }

  Future<bool> revokeFolderShare(String shareId) async {
    await start();
    return _serialized(() async {
      final hosted = _folderShares.remove(shareId);
      final existed = _folderRows.remove(shareId) != null;
      _folderCaps.remove(shareId);
      if (!existed) return false;
      await hosted?.stopAccepting();
      if (hosted != null) _retireFolder(hosted);
      await _saveFolderRows();
      return true;
    });
  }

  /// Anonymously fetch the current listing of a shared folder from its link.
  Future<CloudFolderListing> fetchFolderListing(String link) async {
    await start();
    final parsed = await CloudCapabilityCodec.parseLink(link);
    if (parsed is! ParsedCloudFolderLink) {
      throw StateError('not a folder link');
    }
    final capability = parsed.capability;
    if (capability.expiresAtMs <= _now().millisecondsSinceEpoch) {
      throw StateError('folder capability expired');
    }
    return _withFolderClient(capability, (client) => client.fetchListing());
  }

  /// Anonymously fetch ONE file from a shared folder and commit it to the
  /// deniable content store, returning the synthetic per-file capability so
  /// the caller can adopt it into the cloud index via [CloudService].
  Future<CloudCapability> downloadFolderFile(
    String link,
    CloudFolderListingEntry entry,
  ) async {
    await start();
    final parsed = await CloudCapabilityCodec.parseLink(link);
    if (parsed is! ParsedCloudFolderLink) {
      throw StateError('not a folder link');
    }
    final capability = parsed.capability;
    if (capability.expiresAtMs <= _now().millisecondsSinceEpoch) {
      throw StateError('folder capability expired');
    }
    final fileCapability = CloudCapabilityCodec.folderFileCapability(
      capability,
      entry,
    );
    final manifest = fileCapability.manifest;
    if (await _storage.hasFile(manifest.contentId)) return fileCapability;
    final bytes = await _withFolderClient(
      capability,
      (client) => client.fetchFile(entry),
    );
    var stored = false;
    try {
      if (manifest.pieceCount == 0) {
        await _storage.storeFile(
          manifest.contentId,
          Uint8List(0),
          name: manifest.name,
        );
        stored = true;
      } else {
        for (var piece = 0; piece < manifest.pieceCount; piece++) {
          final offset = piece * manifest.pieceSize;
          final length = manifest.pieceLength(piece);
          await _storage.storeFilePiece(
            manifest.contentId,
            piece,
            manifest.pieceCount,
            manifest.pieceSize,
            manifest.size,
            Uint8List.sublistView(bytes, offset, offset + length),
            name: manifest.name,
          );
          // Mark stored as soon as the first piece lands so a mid-loop
          // failure still scrubs the partial blob in the catch below.
          stored = true;
        }
      }
      await _storage.storeFile(
        '$_manifestPrefix${manifest.contentId}',
        Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
        name: 'cloud-manifest',
      );
      return fileCapability;
    } catch (_) {
      if (stored) {
        await _storage.deleteStoredFile(manifest.contentId);
        await _storage.deleteStoredFile(
          '$_manifestPrefix${manifest.contentId}',
        );
        await _storage.scrubDeleted();
      }
      rethrow;
    }
  }

  Future<T> _withFolderClient<T>(
    CloudFolderCapability capability,
    Future<T> Function(CloudFolderShareClient client) body,
  ) async {
    final seed = _randomBytes(32);
    final alias = _base64(_randomBytes(32));
    CloudCapabilityEndpointPort? endpoint;
    StreamSubscription<Uint8List>? subscription;
    final incoming = StreamController<Uint8List>.broadcast();
    try {
      endpoint = await _network.host(
        identitySeed: seed,
        alias: alias,
        endpointId: _returnEndpointId,
        providerSlot: 0,
        transient: true,
      );
      if (!seed.every((byte) => byte == 0)) {
        throw StateError('native return-service seed was not scrubbed');
      }
      subscription = endpoint.messages.listen(incoming.add);
      final resolvedEndpoint = endpoint;
      final client = CloudFolderShareClient(
        capability: capability,
        returnServicePublicKey: resolvedEndpoint.servicePublicKey,
        returnAppId: resolvedEndpoint.appId,
        returnEndpointId: resolvedEndpoint.endpointId,
        incoming: incoming.stream,
        send: (data) => resolvedEndpoint.sendAnonymous(
          servicePublicKey: capability.servicePublicKey,
          targetAppId: capability.appId,
          targetEndpointId: capability.endpointId,
          data: data,
        ),
        timeout: _folderClientTimeout,
        randomBytes: _randomBytes,
      );
      return await body(client);
    } finally {
      seed.fillRange(0, seed.length, 0);
      await subscription?.cancel();
      await endpoint?.close();
      await incoming.close();
    }
  }

  void _retireFolder(_HostedFolderShare hosted) {
    final endpointId = hosted.endpoint.endpointId;
    late final Future<void> withdrawal;
    withdrawal = hosted.withdraw().catchError((_) {}).whenComplete(() {
      if (identical(_retiringEndpoints[endpointId], withdrawal)) {
        _retiringEndpoints.remove(endpointId);
      }
    });
    _retiringEndpoints[endpointId] = withdrawal;
    unawaited(withdrawal);
  }

  Future<void> _saveFolderRows() => _saveMetadata(
    _folderRegistryFile,
    jsonEncode([for (final row in _folderRows.values) row.toJson()]),
  );

  /// Download one bearer capability into the deniable content store. The
  /// requester publishes only a temporary random return service; neither side
  /// learns the other's sovereign node id. Pieces are committed only after
  /// every AEAD chunk and the manifest hash verify.
  Future<CloudCapability> download(String link) async {
    await start();
    final capability = await CloudCapabilityCodec.parse(link);
    if (capability.expiresAtMs <= _now().millisecondsSinceEpoch) {
      throw StateError('cloud capability expired');
    }
    if (await _storage.hasFile(capability.manifest.contentId)) {
      return capability;
    }
    final seed = _randomBytes(32);
    final alias = _base64(_randomBytes(32));
    CloudCapabilityEndpointPort? endpoint;
    StreamSubscription<Uint8List>? subscription;
    final responses = StreamController<_PieceResponse>.broadcast();
    var storedAny = false;
    try {
      endpoint = await _network.host(
        identitySeed: seed,
        alias: alias,
        endpointId: _returnEndpointId,
        providerSlot: 0,
        transient: true,
      );
      if (!seed.every((byte) => byte == 0)) {
        throw StateError('native return-service seed was not scrubbed');
      }
      subscription = endpoint.messages.listen((wire) {
        final response = _PieceResponse.parse(wire);
        if (response != null && _equal(response.shareId, capability.shareId)) {
          responses.add(response);
        }
      });
      for (var piece = 0; piece < capability.manifest.pieceCount; piece++) {
        final clearPiece = BytesBuilder(copy: false);
        final chunks = CloudCapabilityCodec.chunkCount(capability, piece);
        for (var chunk = 0; chunk < chunks; chunk++) {
          Uint8List? clear;
          Object? lastError;
          for (var attempt = 0; attempt < 5 && clear == null; attempt++) {
            final nonce = _randomBytes(16);
            final request = _PieceRequest.create(
              capability: capability,
              returnServicePublicKey: endpoint.servicePublicKey,
              returnAppId: endpoint.appId,
              returnEndpointId: endpoint.endpointId,
              pieceIndex: piece,
              chunkIndex: chunk,
              nonce: nonce,
            );
            // The timeout clock starts here, BEFORE our own sendAnonymous
            // below — and over the anonymous onion path that request-send
            // alone builds a rendezvous circuit that can take ~5 s, leaving
            // the host's reply (another ~5 s circuit build + return traversal)
            // no room inside a tight window. Budget for BOTH legs of the
            // onion round-trip so a slow-but-delivered reply still matches.
            final pending = responses.stream
                .firstWhere(
                  (response) =>
                      response.pieceIndex == piece &&
                      response.chunkIndex == chunk &&
                      _equal(response.nonce, nonce),
                )
                .timeout(const Duration(seconds: 30));
            try {
              await endpoint.sendAnonymous(
                servicePublicKey: capability.servicePublicKey,
                targetAppId: capability.appId,
                targetEndpointId: capability.endpointId,
                data: request.encode(),
              );
              final response = await pending;
              clear = await CloudCapabilityCodec.openChunk(
                capability: capability,
                pieceIndex: piece,
                chunkIndex: chunk,
                sealed: response.sealed,
              );
            } catch (error) {
              pending.ignore();
              lastError = error;
            } finally {
              nonce.fillRange(0, nonce.length, 0);
            }
          }
          if (clear == null) {
            throw StateError('capability chunk unavailable: $lastError');
          }
          clearPiece.add(clear);
        }
        final bytes = clearPiece.toBytes();
        if (!capability.manifest.verifyPiece(piece, bytes)) {
          throw StateError('capability piece hash mismatch');
        }
        await _storage.storeFilePiece(
          capability.manifest.contentId,
          piece,
          capability.manifest.pieceCount,
          capability.manifest.pieceSize,
          capability.manifest.size,
          bytes,
          name: capability.manifest.name,
        );
        storedAny = true;
      }
      // Empty files have zero pieces but still need a concrete local blob.
      if (capability.manifest.pieceCount == 0) {
        await _storage.storeFile(
          capability.manifest.contentId,
          Uint8List(0),
          name: capability.manifest.name,
        );
        storedAny = true;
      }
      await _storage.storeFile(
        '$_manifestPrefix${capability.manifest.contentId}',
        Uint8List.fromList(
          utf8.encode(jsonEncode(capability.manifest.toJson())),
        ),
        name: 'cloud-manifest',
      );
      return capability;
    } catch (_) {
      if (storedAny) {
        await _storage.deleteStoredFile(capability.manifest.contentId);
        await _storage.deleteStoredFile(
          '$_manifestPrefix${capability.manifest.contentId}',
        );
        await _storage.scrubDeleted();
      }
      rethrow;
    } finally {
      seed.fillRange(0, seed.length, 0);
      await subscription?.cancel();
      await endpoint?.close();
      await responses.close();
    }
  }

  Future<void> _host(_RegistryRow row, CloudCapability capability) async {
    if (!_validProviderEndpoint(capability.endpointId)) {
      throw StateError('capability provider endpoint is out of range');
    }
    final seed = _decode32(row.seed);
    CloudCapabilityEndpointPort? endpoint;
    try {
      final providerSlot = await _providerSlot();
      endpoint = await _network.host(
        identitySeed: seed,
        alias: row.alias,
        endpointId: capability.endpointId,
        providerSlot: providerSlot,
      );
      if (!_equal(endpoint.servicePublicKey, capability.servicePublicKey) ||
          !_equal(endpoint.appId, capability.appId) ||
          endpoint.endpointId != capability.endpointId) {
        throw StateError('capability registry endpoint mismatch');
      }
      final hosted = _HostedShare(row, capability, endpoint, providerSlot);
      _listen(hosted);
      await _install(_shareKey(capability.shareId), hosted);
    } catch (_) {
      await endpoint?.close();
      rethrow;
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  void _listen(_HostedShare share) {
    share.subscription = share.endpoint.messages.listen((data) {
      unawaited(_serve(share, data));
    });
  }

  Future<void> _serve(_HostedShare share, Uint8List wire) async {
    // Every malformed, unauthorized, expired, revoked, unavailable or failed
    // request follows the same silent path. Never emit a read/existence oracle.
    try {
      if (_closed ||
          !_shares.containsKey(_shareKey(share.capability.shareId))) {
        return;
      }
      if (share.capability.expiresAtMs <= _now().millisecondsSinceEpoch) return;
      final request = _PieceRequest.parse(wire);
      if (request == null ||
          !_equal(request.shareId, share.capability.shareId)) {
        return;
      }
      final expectedMac = CloudCapabilityCodec.requestMac(
        capability: share.capability,
        returnServicePublicKey: request.returnServicePublicKey,
        returnAppId: request.returnAppId,
        returnEndpointId: request.returnEndpointId,
        pieceIndex: request.pieceIndex,
        chunkIndex: request.chunkIndex,
        requestNonce: request.nonce,
      );
      if (!_equal(expectedMac, request.mac)) return;
      // AFTER the MAC, never before: a gate ahead of authorization lets anyone
      // who can reach the endpoint fill the queue with garbage, and the
      // authorized requests become the ones refused.
      await share.admission.run(() => _answer(share, request));
    } catch (_) {}
  }

  /// Read the asked-for chunk, seal it, and send it back down a return circuit.
  ///
  /// Split out of [_serve] so the bounded part is exactly the expensive part.
  /// Answering is what costs: the request is a couple of hundred bytes and the
  /// reply is a full anonymous round trip, so an unbounded `unawaited` per
  /// inbound datagram let one holder of a valid capability turn tiny requests
  /// into as many onion circuits as it cared to ask for.
  Future<void> _answer(_HostedShare share, _PieceRequest request) async {
    final length = CloudCapabilityCodec.chunkLength(
      share.capability,
      request.pieceIndex,
      request.chunkIndex,
    );
    final offset =
        request.pieceIndex * share.capability.manifest.pieceSize +
        request.chunkIndex * CloudCapabilityCodec.publicChunkBytes;
    final clear = await _storage.readFileRange(
      share.row.contentId,
      offset,
      length,
    );
    if (clear == null || clear.length != length) return;
    final sealed = await CloudCapabilityCodec.sealChunk(
      capability: share.capability,
      pieceIndex: request.pieceIndex,
      chunkIndex: request.chunkIndex,
      clear: clear,
    );
    final response = _PieceResponse(
      shareId: share.capability.shareId,
      pieceIndex: request.pieceIndex,
      chunkIndex: request.chunkIndex,
      nonce: request.nonce,
      sealed: sealed,
    ).encode();
    await share.endpoint.sendAnonymous(
      servicePublicKey: request.returnServicePublicKey,
      targetAppId: request.returnAppId,
      targetEndpointId: request.returnEndpointId,
      data: response,
    );
  }

  Future<void> _saveCurrentRows() =>
      _saveRows([for (final row in _rows.values) row]);

  int _nextTimestamp() {
    final now = _now().millisecondsSinceEpoch;
    _lastTimestamp = now > _lastTimestamp ? now : _lastTimestamp + 1;
    return _lastTimestamp;
  }

  Future<void> _loadEvents() async {
    final raw = await _loadMetadata(_eventsFile, _eventsSetting);
    if (raw == null) return;
    try {
      final values = jsonDecode(raw);
      if (values is! List) return;
      final folded = foldDeviceSync([
        for (final value in values)
          if (value is String) ?DeviceSyncEvent.fromBody(value),
      ]);
      final newest = folded.entries.toList()
        ..sort((a, b) => b.value.tsMs.compareTo(a.value.tsMs));
      for (final entry in newest.take(maxShareHistory)) {
        if (entry.key.$1 == DeviceSyncKind.cloudCapability) {
          _events[entry.key.$2] = entry.value;
          if (entry.value.tsMs > _lastTimestamp) {
            _lastTimestamp = entry.value.tsMs;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _saveEvents() => _saveMetadata(
    _eventsFile,
    jsonEncode([for (final event in _events.values) event.toBody()]),
  );

  /// Record a capability event, and say whether it reached the disk.
  ///
  /// The return value is the whole point for a tombstone. The event log is
  /// what a restart reads to decide which shares are still live, so a
  /// tombstone that stayed in RAM is a revoke that will be undone by the
  /// stale active row still sitting in the file. This used to swallow the
  /// write error and carry on, and the caller reported the revoke as done.
  ///
  /// On failure the in-memory map is put back the way the file has it, so the
  /// two never disagree about what was recorded.
  ///
  /// Delivery to the other devices is NOT part of the answer: an event that is
  /// on disk here is re-posted by `_reconcileSync`, which offers every local
  /// event the remote log does not already carry. A post that fails is a
  /// retry, not a loss.
  Future<bool> _recordCapabilityEvent(
    String shareId, {
    required bool deleted,
    _RegistryRow? row,
  }) async {
    final event = DeviceSyncEvent(
      kind: DeviceSyncKind.cloudCapability,
      key: shareId,
      tsMs: _nextTimestamp(),
      payload: {
        'deleted': deleted,
        if (!deleted && row != null) 'row': row.toJson(),
      },
    );
    final previous = _events[shareId];
    _events[shareId] = event;
    try {
      await _saveEvents();
    } catch (_) {
      if (previous == null) {
        _events.remove(shareId);
      } else {
        _events[shareId] = previous;
      }
      return false;
    }
    try {
      await _sync?.post(event);
    } catch (_) {}
    return true;
  }

  Future<void> _reconcileSync() async {
    if (_closed) return;
    final sync = _sync;
    if (sync == null) return;
    List<DeviceSyncRecord> remote;
    try {
      remote = await sync.records();
    } catch (_) {
      return;
    }
    final folded = foldDeviceSync([
      ..._events.values,
      for (final record in remote)
        if (record.event.kind == DeviceSyncKind.cloudCapability) record.event,
    ]);
    for (final entry in folded.entries) {
      if (entry.key.$1 != DeviceSyncKind.cloudCapability) continue;
      final shareId = entry.key.$2;
      final event = entry.value;
      if (!_events.containsKey(shareId) && _events.length >= maxShareHistory) {
        continue;
      }
      _events[shareId] = event;
      if (event.tsMs > _lastTimestamp) _lastTimestamp = event.tsMs;
      if (event.payload['deleted'] == true) {
        final hosted = _shares.remove(shareId);
        _rows.remove(shareId);
        _capabilities.remove(shareId);
        await hosted?.close();
        continue;
      }
      final row = _RegistryRow.parse(event.payload['row']);
      if (row == null) continue;
      if (!_rows.containsKey(shareId) && _rows.length >= maxActiveShares) {
        continue;
      }
      CloudCapability capability;
      try {
        capability = await CloudCapabilityCodec.parse(row.link);
      } catch (_) {
        continue;
      }
      if (_shareKey(capability.shareId) != shareId ||
          capability.expiresAtMs <= _now().millisecondsSinceEpoch ||
          !_validProviderEndpoint(capability.endpointId)) {
        continue;
      }
      final current = _rows[shareId];
      _rows[shareId] = row;
      _capabilities[shareId] = capability;
      int providerSlot;
      try {
        providerSlot = await _providerSlot();
      } catch (_) {
        continue;
      }
      if (_shares[shareId] == null ||
          current?.link != row.link ||
          _shares[shareId]!.providerSlot != providerSlot) {
        await _shares.remove(shareId)?.close();
        try {
          await _host(row, capability);
        } catch (_) {}
      }
    }
    await _saveCurrentRows();
    await _saveEvents();

    final remoteBodies = {
      for (final record in remote)
        if (record.event.kind == DeviceSyncKind.cloudCapability)
          record.event.toBody(),
    };
    for (final event in _events.values) {
      if (!remoteBodies.contains(event.toBody())) {
        try {
          await sync.post(event);
        } catch (_) {}
      }
    }
  }

  Future<void> _saveRows(List<_RegistryRow> rows) => _saveMetadata(
    _registryFile,
    jsonEncode([for (final row in rows) row.toJson()]),
  );

  Future<String?> _loadMetadata(String fileId, String legacySetting) async {
    final bytes = await _storage.loadFile(fileId);
    if (bytes != null) {
      try {
        return utf8.decode(bytes);
      } catch (_) {
        return null;
      }
    }
    return _storage.getSetting(legacySetting);
  }

  Future<void> _saveMetadata(String fileId, String value) => _storage.storeFile(
    fileId,
    Uint8List.fromList(utf8.encode(value)),
    name: 'cloud-capability-metadata',
  );

  Future<int> _providerSlot() => cloudProviderSlot(_sync);

  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _mutation.then((_) => body());
    _mutation = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Install a hosted share, or close it if the service shut down while it was
  /// being set up.
  ///
  /// Every registration here happens after awaits — a provider slot, an onion
  /// registration, a listing seal — and `close` sweeps these maps exactly once.
  /// Anything that lands afterwards is a live endpoint nobody will ever close:
  /// it holds a provider slot and goes on answering, and no later reconcile
  /// exists to notice, because the service is closed. Returns whether it was
  /// installed; the caller's own bookkeeping is in-memory and going away with
  /// the service, so a refusal needs no unwinding beyond this.
  Future<bool> _install(String key, _HostedShare hosted) async {
    if (_closed) {
      await hosted.close();
      return false;
    }
    _shares[key] = hosted;
    return true;
  }

  /// The folder twin of [_install]. Same race, same answer.
  Future<bool> _installFolder(String key, _HostedFolderShare hosted) async {
    if (_closed) {
      await hosted.close();
      return false;
    }
    _folderShares[key] = hosted;
    return true;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _syncTimer?.cancel();
    await _syncSubscription?.cancel();
    final shares = _shares.values.toList();
    _shares.clear();
    for (final share in shares) {
      await share.close();
    }
    final folderShares = _folderShares.values.toList();
    _folderShares.clear();
    for (final share in folderShares) {
      await share.close();
    }
    await Future.wait(_retiringEndpoints.values.toList());
    await _sync?.close();
  }

  ContentManifest? _decodeManifest(Uint8List bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map
          ? ContentManifest.fromJson(Map<String, dynamic>.from(value))
          : null;
    } catch (_) {
      return null;
    }
  }

  Uint8List _randomBytes(int count) => Uint8List.fromList([
    for (var i = 0; i < count; i++) _random.nextInt(256),
  ]);

  int _allocateProviderEndpoint() {
    final used = {
      for (final capability in _capabilities.values) capability.endpointId,
      for (final capability in _folderCaps.values) capability.endpointId,
      ..._retiringEndpoints.keys,
    };
    for (var offset = 0; offset < maxActiveShares; offset++) {
      final candidate = _providerEndpointBase + offset;
      if (!used.contains(candidate)) return candidate;
    }
    throw StateError('public share endpoint slots exhausted');
  }

  bool _validProviderEndpoint(int endpointId) =>
      endpointId >= _providerEndpointBase &&
      endpointId < _providerEndpointBase + maxActiveShares;

  void _retire(_HostedShare hosted) {
    final endpointId = hosted.endpoint.endpointId;
    late final Future<void> withdrawal;
    withdrawal = hosted.withdraw().catchError((_) {}).whenComplete(() {
      if (identical(_retiringEndpoints[endpointId], withdrawal)) {
        _retiringEndpoints.remove(endpointId);
      }
    });
    _retiringEndpoints[endpointId] = withdrawal;
    unawaited(withdrawal);
  }
}

class _RegistryRow {
  const _RegistryRow({
    required this.itemId,
    required this.contentId,
    required this.seed,
    required this.alias,
    required this.link,
  });
  final String itemId;
  final String contentId;
  final String seed;
  final String alias;
  final String link;

  Map<String, dynamic> toJson() => {
    'item': itemId,
    'cid': contentId,
    'seed': seed,
    'alias': alias,
    'link': link,
  };

  static _RegistryRow? parse(Object? value) {
    try {
      if (value is! Map ||
          value.keys.any(
            (key) =>
                !const {'item', 'cid', 'seed', 'alias', 'link'}.contains(key),
          )) {
        return null;
      }
      final row = _RegistryRow(
        itemId: value['item'] as String,
        contentId: value['cid'] as String,
        seed: value['seed'] as String,
        alias: value['alias'] as String,
        link: value['link'] as String,
      );
      final seed = _decode32(row.seed);
      seed.fillRange(0, seed.length, 0);
      if (row.itemId.length > 128 ||
          row.contentId.length != 64 ||
          row.alias.length > 128 ||
          row.link.length > 2 * 1024 * 1024) {
        return null;
      }
      return row;
    } catch (_) {
      return null;
    }
  }
}

class _FolderRegistryRow {
  const _FolderRegistryRow({
    required this.folderId,
    required this.folderName,
    required this.seed,
    required this.alias,
    required this.link,
    required this.listingRevision,
    required this.listingJson,
  });
  final String folderId;
  final String folderName;
  final String seed;
  final String alias;
  final String link;
  final int listingRevision;
  final Map<String, dynamic> listingJson;

  _FolderRegistryRow copyWith({
    String? folderName,
    int? listingRevision,
    Map<String, dynamic>? listingJson,
  }) => _FolderRegistryRow(
    folderId: folderId,
    folderName: folderName ?? this.folderName,
    seed: seed,
    alias: alias,
    link: link,
    listingRevision: listingRevision ?? this.listingRevision,
    listingJson: listingJson ?? this.listingJson,
  );

  Map<String, dynamic> toJson() => {
    'folder': folderId,
    'name': folderName,
    'seed': seed,
    'alias': alias,
    'link': link,
    'lrev': listingRevision,
    'listing': listingJson,
  };

  static _FolderRegistryRow? parse(Object? value) {
    try {
      if (value is! Map ||
          value.keys.any(
            (key) => !const {
              'folder',
              'name',
              'seed',
              'alias',
              'link',
              'lrev',
              'listing',
            }.contains(key),
          )) {
        return null;
      }
      final listing = value['listing'];
      if (value['folder'] is! String ||
          value['name'] is! String ||
          value['seed'] is! String ||
          value['alias'] is! String ||
          value['link'] is! String ||
          value['lrev'] is! int ||
          (value['lrev'] as int) < 1 ||
          listing is! Map) {
        return null;
      }
      final row = _FolderRegistryRow(
        folderId: value['folder'] as String,
        folderName: value['name'] as String,
        seed: value['seed'] as String,
        alias: value['alias'] as String,
        link: value['link'] as String,
        listingRevision: value['lrev'] as int,
        listingJson: Map<String, dynamic>.from(listing),
      );
      final seed = _decode32(row.seed);
      seed.fillRange(0, seed.length, 0);
      if (row.folderId.length > 128 ||
          row.folderName.length > 512 ||
          row.alias.length > 128 ||
          row.link.length > 2 * 1024 * 1024) {
        return null;
      }
      return row;
    } catch (_) {
      return null;
    }
  }
}

class _HostedFolderShare {
  _HostedFolderShare(
    this.row,
    this.capability,
    this.endpoint,
    this.host,
    this.providerSlot,
  );
  _FolderRegistryRow row;
  final CloudFolderCapability capability;
  final CloudCapabilityEndpointPort endpoint;
  final CloudFolderShareHost host;
  final int providerSlot;
  StreamSubscription<Uint8List>? subscription;

  CloudFolderShareInfo get public => CloudFolderShareInfo(
    shareId: _shareKey(capability.shareId),
    folderId: row.folderId,
    folderName: row.folderName,
    link: row.link,
    listingRevision: row.listingRevision,
    expiresAtMs: capability.expiresAtMs,
  );

  void listen() {
    subscription = endpoint.messages.listen((data) {
      unawaited(host.serve(data));
    });
  }

  Future<void> close() async {
    await stopAccepting();
    await withdraw();
  }

  Future<void> stopAccepting() async {
    final current = subscription;
    subscription = null;
    await current?.cancel();
  }

  Future<void> withdraw() async {
    await endpoint.close();
  }
}

class _HostedShare {
  _HostedShare(this.row, this.capability, this.endpoint, this.providerSlot);
  final _RegistryRow row;
  final CloudCapability capability;
  final CloudCapabilityEndpointPort endpoint;
  final int providerSlot;
  StreamSubscription<Uint8List>? subscription;

  /// Per share, not per service: a holder who floods can only crowd out the
  /// share it was trusted with. One gate for the whole device would let that
  /// holder starve every OTHER share the user is hosting.
  final ServeAdmission admission = ServeAdmission();

  CloudPublicShare get public => CloudPublicShare(
    shareId: _shareKey(capability.shareId),
    itemId: row.itemId,
    contentId: row.contentId,
    link: row.link,
    expiresAtMs: capability.expiresAtMs,
  );

  Future<void> close() async {
    await stopAccepting();
    await withdraw();
  }

  Future<void> stopAccepting() async {
    final current = subscription;
    subscription = null;
    // Before the cancel: whoever is queued for a slot is woken and refused
    // rather than left holding a request nobody will ever answer.
    admission.close();
    await current?.cancel();
  }

  Future<void> withdraw() async {
    await endpoint.close();
  }
}

class _PieceRequest {
  const _PieceRequest({
    required this.shareId,
    required this.returnServicePublicKey,
    required this.returnAppId,
    required this.returnEndpointId,
    required this.pieceIndex,
    required this.chunkIndex,
    required this.nonce,
    required this.mac,
  });
  static const _length = 4 + 32 + 32 + 32 + 2 + 4 + 4 + 16 + 32;
  final Uint8List shareId;
  final Uint8List returnServicePublicKey;
  final Uint8List returnAppId;
  final int returnEndpointId;
  final int pieceIndex;
  final int chunkIndex;
  final Uint8List nonce;
  final Uint8List mac;

  factory _PieceRequest.create({
    required CloudCapability capability,
    required Uint8List returnServicePublicKey,
    required Uint8List returnAppId,
    required int returnEndpointId,
    required int pieceIndex,
    required int chunkIndex,
    required Uint8List nonce,
  }) => _PieceRequest(
    shareId: capability.shareId,
    returnServicePublicKey: returnServicePublicKey,
    returnAppId: returnAppId,
    returnEndpointId: returnEndpointId,
    pieceIndex: pieceIndex,
    chunkIndex: chunkIndex,
    nonce: nonce,
    mac: CloudCapabilityCodec.requestMac(
      capability: capability,
      returnServicePublicKey: returnServicePublicKey,
      returnAppId: returnAppId,
      returnEndpointId: returnEndpointId,
      pieceIndex: pieceIndex,
      chunkIndex: chunkIndex,
      requestNonce: nonce,
    ),
  );

  Uint8List encode() {
    final wire = Uint8List(_length)..setAll(0, utf8.encode('XCR1'));
    wire.setAll(4, shareId);
    wire.setAll(36, returnServicePublicKey);
    wire.setAll(68, returnAppId);
    final data = ByteData.sublistView(wire);
    data.setUint16(100, returnEndpointId, Endian.big);
    data.setUint32(102, pieceIndex, Endian.big);
    data.setUint32(106, chunkIndex, Endian.big);
    wire.setAll(110, nonce);
    wire.setAll(126, mac);
    return wire;
  }

  static _PieceRequest? parse(Uint8List wire) {
    if (wire.length != _length ||
        utf8.decode(wire.sublist(0, 4), allowMalformed: true) != 'XCR1') {
      return null;
    }
    final data = ByteData.sublistView(wire);
    return _PieceRequest(
      shareId: Uint8List.fromList(wire.sublist(4, 36)),
      returnServicePublicKey: Uint8List.fromList(wire.sublist(36, 68)),
      returnAppId: Uint8List.fromList(wire.sublist(68, 100)),
      returnEndpointId: data.getUint16(100, Endian.big),
      pieceIndex: data.getUint32(102, Endian.big),
      chunkIndex: data.getUint32(106, Endian.big),
      nonce: Uint8List.fromList(wire.sublist(110, 126)),
      mac: Uint8List.fromList(wire.sublist(126, 158)),
    );
  }
}

class _PieceResponse {
  const _PieceResponse({
    required this.shareId,
    required this.pieceIndex,
    required this.chunkIndex,
    required this.nonce,
    required this.sealed,
  });
  final Uint8List shareId;
  final int pieceIndex;
  final int chunkIndex;
  final Uint8List nonce;
  final Uint8List sealed;

  static _PieceResponse? parse(Uint8List wire) {
    const headerLength = 62;
    if (wire.length < headerLength ||
        utf8.decode(wire.sublist(0, 4), allowMalformed: true) != 'XCP1') {
      return null;
    }
    final data = ByteData.sublistView(wire);
    final sealedLength = data.getUint16(60, Endian.big);
    if (sealedLength < 16 || headerLength + sealedLength != wire.length) {
      return null;
    }
    return _PieceResponse(
      shareId: Uint8List.fromList(wire.sublist(4, 36)),
      pieceIndex: data.getUint32(36, Endian.big),
      chunkIndex: data.getUint32(40, Endian.big),
      nonce: Uint8List.fromList(wire.sublist(44, 60)),
      sealed: Uint8List.fromList(wire.sublist(headerLength)),
    );
  }

  Uint8List encode() {
    if (sealed.length > 0xffff) throw StateError('sealed chunk too large');
    final header = Uint8List(4 + 32 + 4 + 4 + 16 + 2);
    header.setAll(0, utf8.encode('XCP1'));
    header.setAll(4, shareId);
    final data = ByteData.sublistView(header);
    data.setUint32(36, pieceIndex, Endian.big);
    data.setUint32(40, chunkIndex, Endian.big);
    header.setAll(44, nonce);
    data.setUint16(60, sealed.length, Endian.big);
    return (BytesBuilder(copy: false)
          ..add(header)
          ..add(sealed))
        .toBytes();
  }
}

String _base64(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');
String _shareKey(Uint8List bytes) => _base64(bytes);

Uint8List _decode32(String value) {
  final decoded = Uint8List.fromList(
    base64Url.decode(base64Url.normalize(value)),
  );
  if (decoded.length != 32) throw const FormatException('expected 32 bytes');
  return decoded;
}

bool _equal(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var diff = 0;
  for (var i = 0; i < left.length; i++) {
    diff |= left[i] ^ right[i];
  }
  return diff == 0;
}

final cloudCapabilityServiceProvider = Provider<CloudCapabilityService?>((ref) {
  final transport = ref.watch(veilTransportProvider);
  if (transport is! VeilFlutterTransport) return null;
  final group = ref.watch(groupServiceProvider);
  final service = CloudCapabilityService(
    ref.read(storageProvider),
    VeilCloudCapabilityNetwork(transport),
    sync: group == null ? null : GroupCloudCapabilitySyncPort(group),
  );
  unawaited(service.start());
  ref.onDispose(() => unawaited(service.close()));
  return service;
});
