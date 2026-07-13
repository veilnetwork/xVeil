import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/cloud.dart';
import '../domain/cloud_capability.dart';
import '../domain/content_manifest.dart';
import '../domain/device_sync.dart';
import 'group_service.dart';
import 'providers.dart';

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

abstract interface class CloudCapabilityNetworkPort {
  Future<CloudCapabilityEndpointPort> host({
    required Uint8List identitySeed,
    required String alias,
    required int endpointId,
    required int providerSlot,
    bool transient = false,
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
  }) async => _VeilCapabilityEndpointPort(
    await (transient
        ? _transport.hostTransientCapabilityEndpoint(
            identitySeed: identitySeed,
            name: alias,
            endpointId: endpointId,
            providerSlot: providerSlot,
          )
        : _transport.hostCapabilityEndpoint(
            identitySeed: identitySeed,
            name: alias,
            endpointId: endpointId,
            providerSlot: providerSlot,
          )),
  );
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
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure(),
       // ignore: prefer_initializing_formals
       _sync = sync;

  static const _registrySetting = 'cloud.capabilities.v1';
  static const _eventsSetting = 'cloud.capability.events.v1';
  static const _registryFile = 'cloud.capabilities.registry.v2';
  static const _eventsFile = 'cloud.capability.events.v2';
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
    await _loadEvents();
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
      if (_rows.length >= maxActiveShares) {
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
        _shares[shareKey] = hosted;
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
      final hosted = _shares.remove(shareId);
      final existed = _rows.remove(shareId) != null;
      _capabilities.remove(shareId);
      if (!existed) return false;
      // Drop the request handler before any awaited write so revoke takes
      // effect immediately and invalid probes remain silent. Descriptor
      // withdrawal can wait on the native rendezvous mutex for tens of
      // seconds, so retire that endpoint in the background and do not make
      // the user wait for network housekeeping.
      await hosted?.stopAccepting();
      if (hosted != null) _retire(hosted);
      await _saveCurrentRows();
      await _recordCapabilityEvent(shareId, deleted: true);
      await _storage.scrubDeleted();
      return true;
    });
  }

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
            final pending = responses.stream
                .firstWhere(
                  (response) =>
                      response.pieceIndex == piece &&
                      response.chunkIndex == chunk &&
                      _equal(response.nonce, nonce),
                )
                .timeout(const Duration(seconds: 8));
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
      _shares[_shareKey(capability.shareId)] = hosted;
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
    } catch (_) {}
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

  Future<void> _recordCapabilityEvent(
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
    _events[shareId] = event;
    try {
      await _saveEvents();
    } catch (_) {}
    try {
      await _sync?.post(event);
    } catch (_) {}
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

  Future<int> _providerSlot() async {
    final sync = _sync;
    if (sync == null) return 0;
    final byHex = <String, NodeId>{sync.selfId.hex: sync.selfId};
    for (final member in await sync.members()) {
      byHex[member.hex] = member;
    }
    final ordered = byHex.keys.toList()..sort();
    final slot = ordered.indexOf(sync.selfId.hex);
    if (slot < 0 || slot >= 8) {
      throw StateError('capability provider device limit reached');
    }
    return slot;
  }

  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _mutation.then((_) => body());
    _mutation = result.then<void>((_) {}, onError: (_) {});
    return result;
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

class _HostedShare {
  _HostedShare(this.row, this.capability, this.endpoint, this.providerSlot);
  final _RegistryRow row;
  final CloudCapability capability;
  final CloudCapabilityEndpointPort endpoint;
  final int providerSlot;
  StreamSubscription<Uint8List>? subscription;

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
