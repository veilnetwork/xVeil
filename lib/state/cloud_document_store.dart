import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../domain/cloud_document.dart';
import '../domain/cloud_document_envelope.dart';
import '../domain/cloud_document_replication.dart';
import '../domain/cloud_document_payload.dart';

const int _maxDocumentControls = 4096;
const int _maxDocumentOperations = 100000;
const int _maxDocumentEpochs = 1024;

class CloudDocumentStoredBundle {
  CloudDocumentStoredBundle({
    required this.root,
    required List<CloudDocumentControlEntry> controls,
    required List<CloudDocumentOperation> operations,
    required List<CloudDocumentEpochEnvelopeBundle> envelopes,
    required Map<int, Uint8List> localEpochKeys,
    List<CloudDocumentEncryptedPayload> payloads = const [],
  }) : controls = List.unmodifiable(controls),
       operations = List.unmodifiable(operations),
       envelopes = List.unmodifiable(envelopes),
       localEpochKeys = Map.unmodifiable(localEpochKeys),
       payloads = List.unmodifiable(payloads);

  final CloudDocumentRoot root;
  final List<CloudDocumentControlEntry> controls;
  final List<CloudDocumentOperation> operations;
  final List<CloudDocumentEpochEnvelopeBundle> envelopes;
  final List<CloudDocumentEncryptedPayload> payloads;

  /// Decrypted keys live only inside the deniable hidden-volume file. Callers
  /// receive fresh byte copies on load and must not write them to ordinary disk.
  final Map<int, Uint8List> localEpochKeys;

  void wipeLocalEpochKeys() {
    for (final key in localEpochKeys.values) {
      key.fillRange(0, key.length, 0);
    }
  }

  Map<String, dynamic> toJson() => {
    'v': 2,
    'root': root.toJson(),
    'controls': controls.map((entry) => entry.toJson()).toList(),
    'operations': operations.map((entry) => entry.toJson()).toList(),
    'envelopes': envelopes.map((entry) => entry.toJson()).toList(),
    'payloads': payloads.map((entry) => entry.toJson()).toList(),
    'keys': {
      for (final epoch in (localEpochKeys.keys.toList()..sort()))
        '$epoch': base64Encode(localEpochKeys[epoch]!),
    },
  };

  bool get isStructurallyValid {
    if (CloudDocumentRoot.fromJson(root.toJson()) == null ||
        controls.length > _maxDocumentControls ||
        operations.length > _maxDocumentOperations ||
        envelopes.length > _maxDocumentEpochs ||
        payloads.length > _maxDocumentOperations ||
        localEpochKeys.length > _maxDocumentEpochs ||
        controls.any(
          (entry) =>
              entry.documentId != root.documentId ||
              CloudDocumentControlEntry.fromJson(entry.toJson()) == null,
        ) ||
        operations.any(
          (entry) =>
              entry.documentId != root.documentId ||
              CloudDocumentOperation.fromJson(entry.toJson()) == null,
        ) ||
        envelopes.any(
          (entry) =>
              entry.documentId != root.documentId ||
              CloudDocumentEpochEnvelopeBundle.fromJson(entry.toJson()) == null,
        ) ||
        payloads.any(
          (entry) =>
              entry.documentId != root.documentId || !entry.isStructurallyValid,
        )) {
      return false;
    }
    final payloadByOperation = <String, CloudDocumentEncryptedPayload>{};
    for (final payload in payloads) {
      if (payloadByOperation.containsKey(payload.operationId)) return false;
      payloadByOperation[payload.operationId] = payload;
    }
    if (payloadByOperation.length != operations.length) return false;
    for (final operation in operations) {
      final payload = payloadByOperation[operation.operationId];
      if (payload == null ||
          payload.membershipEpoch != operation.membershipEpoch ||
          payload.payloadHash != operation.payloadHash) {
        return false;
      }
    }
    final expected = <int, Set<(String, String)>>{
      0: {(root.epochKeyCommitment, root.epochEnvelopeHash)},
    };
    for (final control in controls) {
      expected.putIfAbsent(control.nextEpoch, () => {}).add((
        control.epochKeyCommitment,
        control.epochEnvelopeHash,
      ));
    }
    final envelopeEpochs = <int>{};
    for (final envelope in envelopes) {
      if (!envelopeEpochs.add(envelope.epoch) ||
          !(expected[envelope.epoch]?.contains((
                envelope.keyCommitment,
                envelope.bundleHash,
              )) ??
              false)) {
        return false;
      }
    }
    for (final entry in localEpochKeys.entries) {
      if (entry.key < 0 || entry.value.length != 32) return false;
      final commitment = cloudDocumentEpochKeyCommitment(
        documentId: root.documentId,
        epoch: entry.key,
        key: entry.value,
      );
      if (!(expected[entry.key]?.any(
            (candidate) => candidate.$1 == commitment,
          ) ??
          false)) {
        return false;
      }
    }
    return true;
  }

  static CloudDocumentStoredBundle? fromJson(Object? value) {
    if (value is! Map || (value['v'] != 1 && value['v'] != 2)) return null;
    final root = CloudDocumentRoot.fromJson(value['root']);
    final rawControls = value['controls'];
    final rawOperations = value['operations'];
    final rawEnvelopes = value['envelopes'];
    final rawKeys = value['keys'];
    final rawPayloads = value['v'] == 2 ? value['payloads'] : const [];
    if (root == null ||
        rawControls is! List ||
        rawControls.length > _maxDocumentControls ||
        rawOperations is! List ||
        rawOperations.length > _maxDocumentOperations ||
        rawEnvelopes is! List ||
        rawEnvelopes.length > _maxDocumentEpochs ||
        rawKeys is! Map ||
        rawKeys.length > _maxDocumentEpochs ||
        rawPayloads is! List ||
        rawPayloads.length > _maxDocumentOperations) {
      return null;
    }
    final controls = rawControls
        .map(CloudDocumentControlEntry.fromJson)
        .whereType<CloudDocumentControlEntry>()
        .toList();
    final operations = rawOperations
        .map(CloudDocumentOperation.fromJson)
        .whereType<CloudDocumentOperation>()
        .toList();
    final envelopes = rawEnvelopes
        .map(CloudDocumentEpochEnvelopeBundle.fromJson)
        .whereType<CloudDocumentEpochEnvelopeBundle>()
        .toList();
    final payloads = rawPayloads
        .map(CloudDocumentEncryptedPayload.fromJson)
        .whereType<CloudDocumentEncryptedPayload>()
        .toList();
    if (controls.length != rawControls.length ||
        operations.length != rawOperations.length ||
        envelopes.length != rawEnvelopes.length ||
        payloads.length != rawPayloads.length) {
      return null;
    }
    final keys = <int, Uint8List>{};
    CloudDocumentStoredBundle? reject([Uint8List? extra]) {
      extra?.fillRange(0, extra.length, 0);
      for (final key in keys.values) {
        key.fillRange(0, key.length, 0);
      }
      return null;
    }

    try {
      for (final entry in rawKeys.entries) {
        if (entry.key is! String || entry.value is! String) return reject();
        final epoch = int.tryParse(entry.key as String);
        final key = Uint8List.fromList(base64Decode(entry.value as String));
        if (epoch == null || epoch < 0 || key.length != 32) return reject(key);
        keys[epoch] = key;
      }
    } catch (_) {
      return reject();
    }
    final bundle = CloudDocumentStoredBundle(
      root: root,
      controls: controls,
      operations: operations,
      envelopes: envelopes,
      localEpochKeys: keys,
      payloads: payloads,
    );
    if (!bundle.isStructurallyValid) {
      return reject();
    }
    return bundle;
  }
}

class CloudDocumentStore {
  CloudDocumentStore(this._storage);

  final Storage _storage;
  Future<void> _writeTail = Future.value();

  static const String _indexKey = 'cloud.documents.index.v1';
  static const String _pendingKey = 'cloud.documents.pending.v1';
  static const String _inviteIndexKey = 'cloud.document.invites.index.v1';
  static const String _invitePendingKey = 'cloud.document.invites.pending.v1';

  String _documentKey(String documentId) => 'cloud.document.v1.$documentId';
  String _inviteKey(String documentId) =>
      'cloud.document.invite.v1.$documentId';

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _writeTail.then((_) => action());
    _writeTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<T?> _loadAtomic<T>(
    String key,
    T? Function(Object? decoded) decode,
  ) async {
    final active = await _storage.getSetting('$key.active');
    final slots = active == 'a' || active == 'b'
        ? [active!, active == 'a' ? 'b' : 'a']
        : const ['a', 'b'];
    for (final slot in slots) {
      final bytes = await _storage.loadFile('$key.$slot');
      if (bytes == null) continue;
      try {
        final value = decode(
          jsonDecode(utf8.decode(bytes, allowMalformed: true)),
        );
        if (value != null) return value;
      } catch (_) {}
    }
    return null;
  }

  Future<void> _saveAtomic(String key, String value) async {
    var active = await _storage.getSetting('$key.active');
    if (active == 'a' || active == 'b') {
      final other = active == 'a' ? 'b' : 'a';
      if (!await _storage.hasFile('$key.$active') &&
          await _storage.hasFile('$key.$other')) {
        active = other;
      }
    }
    final next = active == 'a' ? 'b' : 'a';
    await _storage.storeFile(
      '$key.$next',
      Uint8List.fromList(utf8.encode(value)),
      name: 'cloud-document-log',
    );
    await _storage.putSetting('$key.active', next);
  }

  Future<CloudDocumentStoredBundle?> load(String documentId) async {
    return _loadAtomic(
      _documentKey(documentId),
      CloudDocumentStoredBundle.fromJson,
    );
  }

  Future<List<String>> listDocumentIds() async {
    final result = await _loadAtomic<List<String>>(_indexKey, (decoded) {
      if (decoded is! Map || decoded['v'] != 1 || decoded['ids'] is! List) {
        return null;
      }
      final ids = (decoded['ids'] as List).whereType<String>().toList();
      if (ids.length != (decoded['ids'] as List).length ||
          ids.length > 100000 ||
          ids.toSet().length != ids.length ||
          ids.any((id) {
            try {
              NodeId.fromHex(id);
              return false;
            } catch (_) {
              return true;
            }
          })) {
        return null;
      }
      final sorted = [...ids]..sort();
      return sorted;
    });
    final ids = (result ?? const <String>[]).toSet();
    final pending = await _storage.getSetting(_pendingKey);
    if (pending != null && pending.isNotEmpty) {
      try {
        NodeId.fromHex(pending);
        if (await load(pending) != null) ids.add(pending);
      } catch (_) {}
    }
    final sorted = ids.toList()..sort();
    return sorted;
  }

  Future<CloudDocumentPendingInvite?> loadPendingInvite(String documentId) =>
      _loadAtomic(_inviteKey(documentId), CloudDocumentPendingInvite.fromJson);

  Future<List<String>> listPendingInviteIds() async {
    final result = await _loadAtomic<List<String>>(_inviteIndexKey, (decoded) {
      if (decoded is! Map || decoded['v'] != 1 || decoded['ids'] is! List) {
        return null;
      }
      final raw = decoded['ids'] as List;
      final ids = raw.whereType<String>().toList();
      if (ids.length != raw.length ||
          ids.length > 100000 ||
          ids.toSet().length != ids.length) {
        return null;
      }
      try {
        for (final id in ids) {
          NodeId.fromHex(id);
        }
      } catch (_) {
        return null;
      }
      return ids..sort();
    });
    final ids = (result ?? const <String>[]).toSet();
    final pending = await _storage.getSetting(_invitePendingKey);
    if (pending != null && pending.isNotEmpty) {
      try {
        NodeId.fromHex(pending);
        if (await loadPendingInvite(pending) != null) ids.add(pending);
      } catch (_) {}
    }
    return ids.toList()..sort();
  }

  Future<void> savePendingInvite(CloudDocumentPendingInvite invite) =>
      _serialized(() async {
        final id = invite.frame.root.documentId.hex;
        if (invite.sender != invite.frame.root.owner ||
            CloudDocumentPendingInvite.fromJson(invite.toJson()) == null) {
          throw ArgumentError('invalid cloud document invite');
        }
        final ids = (await listPendingInviteIds()).toSet()..add(id);
        await _storage.putSetting(_invitePendingKey, id);
        await _saveAtomic(_inviteKey(id), jsonEncode(invite.toJson()));
        await _saveAtomic(
          _inviteIndexKey,
          jsonEncode({'v': 1, 'ids': (ids.toList()..sort())}),
        );
        await _storage.putSetting(_invitePendingKey, '');
      });

  Future<void> removePendingInvite(String documentId) => _serialized(() async {
    final ids = (await listPendingInviteIds()).toSet()..remove(documentId);
    await _saveAtomic(
      _inviteIndexKey,
      jsonEncode({'v': 1, 'ids': (ids.toList()..sort())}),
    );
    await _storage.deleteStoredFile('${_inviteKey(documentId)}.a');
    await _storage.deleteStoredFile('${_inviteKey(documentId)}.b');
    await _storage.putSetting('${_inviteKey(documentId)}.active', '');
    if (await _storage.getSetting(_invitePendingKey) == documentId) {
      await _storage.putSetting(_invitePendingKey, '');
    }
  });

  Future<void> save(CloudDocumentStoredBundle bundle) => _serialized(() async {
    if (!bundle.isStructurallyValid) {
      throw ArgumentError('invalid cloud document bundle');
    }
    final documentId = bundle.root.documentId.hex;
    // Recover a prior crash-window orphan before replacing the single pending
    // marker with this serialized write.
    final ids = (await listDocumentIds()).toSet()..add(documentId);
    await _storage.putSetting(_pendingKey, documentId);
    await _saveAtomic(_documentKey(documentId), jsonEncode(bundle.toJson()));
    final sorted = ids.toList()..sort();
    await _saveAtomic(_indexKey, jsonEncode({'v': 1, 'ids': sorted}));
    await _storage.putSetting(_pendingKey, '');
  });
}
