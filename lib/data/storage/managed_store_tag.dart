import 'dart:typed_data';

import 'kv_log_store.dart';
import 'managed_identity_catalog.dart';

enum ManagedStoreRole { keybox, content, maintenance }

/// Authenticated *inside* a managed HV space. A file name or public catalog
/// entry is not sufficient evidence that an unlocked space has this role.
final class ManagedStoreTag {
  ManagedStoreTag({
    required this.identity,
    required this.role,
    this.generation,
  }) {
    if (role == ManagedStoreRole.content
        ? generation == null ||
              generation!.length != 64 ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(generation!)
        : generation != null) {
      throw ArgumentError('Invalid managed store role marker');
    }
  }

  static const namespace = 254;
  static Uint8List get _key => Uint8List.fromList([0x78, 0x56, 0x52, 1]);
  final ManagedIdentityId identity;
  final ManagedStoreRole role;
  final String? generation;

  Uint8List encode() => Uint8List.fromList([
    0x58,
    0x56,
    0x4d,
    0x52,
    1,
    role.index,
    ..._unhex(identity.value),
    if (generation != null) ..._unhex(generation!),
  ]);

  factory ManagedStoreTag.decode(Uint8List bytes) {
    if (bytes.length < 22 ||
        _hex(bytes.sublist(0, 5)) != '58564d5201' ||
        bytes[5] >= ManagedStoreRole.values.length) {
      throw const FormatException('Invalid managed store role marker');
    }
    final role = ManagedStoreRole.values[bytes[5]];
    if (bytes.length != (role == ManagedStoreRole.content ? 54 : 22)) {
      throw const FormatException('Invalid managed store role marker length');
    }
    return ManagedStoreTag(
      identity: ManagedIdentityId(_hex(bytes.sublist(6, 22))),
      role: role,
      generation: role == ManagedStoreRole.content
          ? _hex(bytes.sublist(22))
          : null,
    );
  }

  /// Only the future managed-file owner may initialize a newly admitted file
  /// or rotate the content generation during prepared compaction. A missing
  /// tag on an existing file must never call this as an automatic fallback.
  PutOp putOp() => PutOp(namespace, _key, encode());

  static ManagedStoreTag read(
    KvLogStore store, {
    required ManagedIdentityId identity,
    required ManagedStoreRole role,
  }) {
    final bytes = store.get(namespace, _key);
    if (bytes == null) throw StateError('Managed store role marker is missing');
    final tag = ManagedStoreTag.decode(bytes);
    if (tag.identity != identity || tag.role != role) {
      throw StateError('Managed store role does not match its owner');
    }
    return tag;
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
Uint8List _unhex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);
