import 'dart:typed_data';
import 'package:xveil/data/storage/kv_log_store.dart';
export 'storage_commit_labels.dart';

bool _prefix(Uint8List key, String prefix) {
  if (key.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (key[i] != prefix.codeUnitAt(i)) return false;
  }
  return true;
}

String _setting(Uint8List key) {
  if (_prefix(key, 'set:device.history.cursor.v2:')) return 'historyCursor';
  if (_prefix(key, 'set:ratchet_reserve:')) return 'ratchetReservation';
  if (_prefix(key, 'msg_next_id') || _prefix(key, 'msglog_ns:v1:')) {
    return 'messageAllocator';
  }
  if (_prefix(key, 'conv_seq:')) return 'messageSequence';
  if (_prefix(key, 'set:sync_floor:')) return 'syncFloor';
  if (_prefix(key, 'set:group.') || _prefix(key, 'set:groups.')) {
    return 'groupSettings';
  }
  if (_prefix(key, 'set:devices.') || _prefix(key, 'set:device.')) {
    return 'deviceSettings';
  }
  if (_prefix(key, 'contact.') ||
      _prefix(key, 'contacts:index') ||
      _prefix(key, 'read:')) {
    return 'contactSettings';
  }
  if (_prefix(key, 'file:') ||
      _prefix(key, 'filepiece:') ||
      _prefix(key, 'file_next_log') ||
      _prefix(key, 'file_chunk_gc')) {
    return 'files';
  }
  return 'settingsOther';
}

/// Classify only operation shapes, fixed key prefixes and the existing
/// allowlisted file context. Values, payloads and key suffixes are not read.
({String primary, List<String> components}) classifyStorageCommit(
  List<KvLogOp> ops, {
  String? storageOperation,
}) {
  final components = <String>{};
  for (final op in ops) {
    final (namespace, key) = switch (op) {
      PutOp(:final namespace, :final key) ||
      DeleteOp(:final namespace, :final key) => (namespace, key),
      AppendLogOp(:final namespace) ||
      DeleteLogOp(:final namespace) => (namespace, null),
    };
    final label = switch (namespace) {
      Ns.settings => key == null ? 'settingsOther' : _setting(key),
      Ns.ratchet =>
        key != null && (key.length == 1 || key.length == 35) && key[0] == 0x50
            ? 'peerAuthorization'
            : 'ratchet',
      Ns.messageLog => 'messages',
      >= Ns.messageLogShardFirst && <= Ns.messageLogShardLast => 'messages',
      Ns.outbox || Ns.outboxIndex => 'outbox',
      Ns.fileChunks => 'files',
      Ns.contacts => 'contactSettings',
      _ => 'other',
    };
    components.add(label);
  }
  final major = components.intersection({
    'peerAuthorization',
    'ratchet',
    'messages',
    'outbox',
  });
  final String primary;
  if (ops.isEmpty) {
    primary = 'empty';
  } else if (major.length > 1 ||
      (major.isNotEmpty && components.contains('files'))) {
    primary = 'mixed';
  } else if (major.isNotEmpty) {
    primary = major.single;
  } else if (storageOperation == 'file.storePair.header' ||
      storageOperation == 'file.storePair.segment') {
    primary = 'groupPair';
  } else if (const {
    'file.store.header',
    'file.delete.header',
  }.contains(storageOperation)) {
    primary = 'groupHeader';
  } else if (const {
    'file.store.segment',
    'file.delete.segment',
  }.contains(storageOperation)) {
    primary = 'groupSegment';
  } else if (components.length == 1) {
    primary = components.single;
  } else {
    primary = 'mixed';
  }
  return (primary: primary, components: components.toList()..sort());
}
