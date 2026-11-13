import 'dart:math';
import 'dart:typed_data';

import 'managed_identity_catalog.dart';
import 'managed_metadata_blob.dart';
import 'rollback_anchor.dart';

const _maxSequence = 0x7fffffffffffffff;
final _rootPattern = RegExp(r'^[0-9a-f]{64}$');

/// One authenticated content generation. Repack rotates [marker] and its
/// physical commit sequence; the logical sequence must continue monotonically.
final class ManagedGeneration {
  ManagedGeneration({
    required this.marker,
    required this.innerFloor,
    required this.offset,
  }) {
    if (!_rootPattern.hasMatch(marker) ||
        marker.length != 64 ||
        innerFloor < 1 ||
        offset < -_maxSequence) {
      throw ArgumentError('Invalid managed content generation');
    }
    if (project(innerFloor) < 1) {
      throw ArgumentError('Invalid managed content generation floor');
    }
  }

  factory ManagedGeneration.fresh({
    required int innerFloor,
    required int offset,
  }) {
    final random = Random.secure();
    return ManagedGeneration(
      marker: _hex(
        Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
      ),
      innerFloor: innerFloor,
      offset: offset,
    );
  }

  final String marker;
  final int innerFloor;
  final int offset;

  int get logicalFloor => project(innerFloor);

  int project(int innerSequence) {
    // Check before adding: Dart's native int arithmetic can wrap at 64 bits.
    if (innerSequence < innerFloor ||
        (offset >= 0 && innerSequence > _maxSequence - offset) ||
        (offset < 0 && innerSequence < -offset)) {
      throw StateError('Managed content sequence is outside its generation');
    }
    return innerSequence + offset;
  }
}

/// A verified *logical* head. Only [ManagedAnchorState.resolve] can create it;
/// prepare/settle refuse a snapshot obtained from another state object.
final class ManagedAnchorSnapshot {
  ManagedAnchorSnapshot._(
    this._owner,
    this.generation,
    this.sequence,
    Map<int, String> roots,
  ) : roots = Map.unmodifiable(roots);

  final ManagedAnchorState _owner;
  final ManagedGeneration generation;
  final int sequence;
  final Map<int, String> roots;
  List<int> get history => List.unmodifiable(roots.keys);
}

/// Encrypted maintenance metadata for a single enumerable identity. It is not
/// a new cipher or an external anti-rollback anchor: native HV authenticates
/// both content and maintenance; the existing host anchor judges the result.
final class ManagedAnchorState {
  ManagedAnchorState._({
    required this.identity,
    required this.active,
    required this.checkpoint,
    required Map<int, String> roots,
    this.prepared,
  }) : retainedRoots = Map.unmodifiable(
         Map.fromEntries(
           roots.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
         ),
       ) {
    if (checkpoint < 0 ||
        checkpoint < active.logicalFloor - 1 ||
        roots.length > anchorHorizon ||
        roots.entries.any(
          (e) =>
              e.key < 0 ||
              e.key > checkpoint ||
              checkpoint - e.key >= anchorHorizon ||
              e.value.length != 64 ||
              !_rootPattern.hasMatch(e.value),
        ) ||
        (roots.isEmpty
            ? (prepared != null || checkpoint != active.logicalFloor - 1)
            : retainedRoots.keys.last != checkpoint)) {
      throw ArgumentError('Invalid managed anchor checkpoint');
    }
    final next = prepared;
    if (next != null &&
        (next.marker == active.marker ||
            checkpoint == _maxSequence ||
            checkpoint < active.logicalFloor ||
            next.logicalFloor != checkpoint + 1)) {
      throw ArgumentError('Invalid prepared managed generation');
    }
  }

  factory ManagedAnchorState.initial({
    required ManagedIdentityId identity,
    required ManagedGeneration generation,
  }) => ManagedAnchorState._(
    identity: identity,
    active: generation,
    checkpoint: generation.logicalFloor - 1,
    roots: const {},
  );

  final ManagedIdentityId identity;
  final ManagedGeneration active;
  final ManagedGeneration? prepared;
  final int checkpoint;
  final Map<int, String> retainedRoots;

  ManagedAnchorSnapshot resolve({
    required ManagedIdentityId contentIdentity,
    required String contentMarker,
    required int innerSequence,
    required Map<int, String> innerRoots,
  }) {
    if (identity != contentIdentity || innerRoots.length > anchorHorizon) {
      throw StateError('Managed content does not match its maintenance state');
    }
    final next = prepared;
    final generation = contentMarker == active.marker
        ? active
        : next != null && contentMarker == next.marker
        ? next
        : throw StateError('Unknown managed content generation');
    final sequence = generation.project(innerSequence);
    if (sequence < checkpoint ||
        (next != null &&
            identical(generation, active) &&
            sequence != checkpoint) ||
        !innerRoots.containsKey(innerSequence)) {
      throw StateError('Managed content head does not match its checkpoint');
    }
    final lower = max(0, sequence - anchorHorizon + 1);
    final roots = <int, String>{
      for (final entry in retainedRoots.entries)
        if (entry.key >= lower) entry.key: entry.value,
    };
    for (final entry in innerRoots.entries) {
      if (entry.key < 0 ||
          entry.key > innerSequence ||
          entry.value.length != 64 ||
          !_rootPattern.hasMatch(entry.value)) {
        throw StateError('Invalid authenticated managed content history');
      }
      // Copy/repack creates earlier staging commits. They must not be assigned
      // logical numbers belonging to the previous generation's real history.
      if (entry.key < generation.innerFloor) continue;
      final logical = generation.project(entry.key);
      if (logical < lower) continue;
      final known = roots[logical];
      if (known != null && known != entry.value) {
        throw StateError(
          'Managed content history conflicts with its checkpoint',
        );
      }
      roots[logical] = entry.value;
    }
    final ordered = Map.fromEntries(
      roots.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return ManagedAnchorSnapshot._(this, generation, sequence, ordered);
  }

  /// Persist this PREPARED state while native compaction still owns the source
  /// lock, before allowing the replacement to publish.
  ManagedAnchorState prepare({
    required ManagedAnchorSnapshot source,
    required ManagedGeneration replacement,
  }) {
    if (prepared != null ||
        !identical(source._owner, this) ||
        !identical(source.generation, active) ||
        source.sequence == _maxSequence) {
      throw StateError('Managed compaction source is not current');
    }
    return ManagedAnchorState._(
      identity: identity,
      active: active,
      checkpoint: source.sequence,
      roots: source.roots,
      prepared: replacement,
    );
  }

  /// Recover by the marker actually authenticated from the content file, not
  /// by guessing whether a rename or its response happened before a crash.
  ManagedAnchorState settle(ManagedAnchorSnapshot observed) {
    if (prepared == null || !identical(observed._owner, this)) {
      throw StateError('Managed compaction observation is not current');
    }
    return ManagedAnchorState._(
      identity: identity,
      active: observed.generation,
      checkpoint: observed.sequence,
      roots: observed.roots,
    );
  }

  /// Compact binary encoding shares one bounded history across old/new maps.
  /// 1024 roots and a prepared generation fit in <42 KiB, below the blob cap.
  Uint8List encode() {
    final writer = _Writer()
      ..bytes.add([0x58, 0x56, 0x4d, 0x53, 1, prepared == null ? 0 : 1, 0, 0]);
    writer.bytes.add(_unhex(identity.value));
    writer.uint64(checkpoint);
    writer.generation(active);
    final next = prepared;
    if (next != null) writer.generation(next);
    writer.bytes.add(
      (ByteData(
        2,
      )..setUint16(0, retainedRoots.length, Endian.big)).buffer.asUint8List(),
    );
    for (final entry in retainedRoots.entries) {
      writer.uint64(entry.key);
      writer.bytes.add(_unhex(entry.value));
    }
    return writer.bytes.takeBytes();
  }

  factory ManagedAnchorState.decode(Uint8List bytes) {
    if (bytes.length > ManagedMetadataBlob.maxBytes) {
      throw const FormatException('Managed anchor state exceeds its limit');
    }
    try {
      final reader = _Reader(bytes);
      final magic = reader.take(8);
      if (_hex(magic.sublist(0, 5)) != '58564d5301' ||
          magic[5] > 1 ||
          magic[6] != 0 ||
          magic[7] != 0) {
        throw const FormatException('Unknown managed anchor state format');
      }
      final identity = ManagedIdentityId(_hex(reader.take(16)));
      final checkpoint = reader.uint64();
      final active = reader.generation();
      final prepared = magic[5] == 1 ? reader.generation() : null;
      final count = ByteData.sublistView(
        reader.take(2),
      ).getUint16(0, Endian.big);
      if (count > anchorHorizon) {
        throw const FormatException('Managed anchor history exceeds its limit');
      }
      final roots = <int, String>{};
      var last = -1;
      for (var i = 0; i < count; i++) {
        final seq = reader.uint64();
        if (seq <= last) {
          throw const FormatException('Unordered managed anchor history');
        }
        last = seq;
        roots[seq] = _hex(reader.take(32));
      }
      if (reader.offset != bytes.length) {
        throw const FormatException('Trailing managed anchor state');
      }
      return ManagedAnchorState._(
        identity: identity,
        active: active,
        checkpoint: checkpoint,
        roots: roots,
        prepared: prepared,
      );
    } on ArgumentError {
      throw const FormatException('Invalid managed anchor state');
    } on StateError {
      throw const FormatException('Invalid managed anchor state');
    }
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
Uint8List _unhex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);

final class _Writer {
  final bytes = BytesBuilder(copy: false);
  void uint64(int value) => bytes.add(
    (ByteData(8)..setUint64(0, value, Endian.big)).buffer.asUint8List(),
  );
  void generation(ManagedGeneration value) {
    bytes.add(_unhex(value.marker));
    uint64(value.innerFloor);
    bytes.add(
      (ByteData(8)..setInt64(0, value.offset, Endian.big)).buffer.asUint8List(),
    );
  }
}

final class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  Uint8List take(int length) {
    if (length > bytes.length - offset) {
      throw const FormatException('Incomplete managed anchor state');
    }
    final result = bytes.sublist(offset, offset + length);
    offset += length;
    return result;
  }

  int uint64() {
    final value = ByteData.sublistView(take(8)).getUint64(0, Endian.big);
    if (value < 0) throw const FormatException('Invalid managed sequence');
    return value;
  }

  ManagedGeneration generation() {
    final marker = _hex(take(32));
    final floor = uint64();
    final offset = ByteData.sublistView(take(8)).getInt64(0, Endian.big);
    return ManagedGeneration(marker: marker, innerFloor: floor, offset: offset);
  }
}
