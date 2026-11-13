import 'dart:math';
import 'dart:typed_data';

import 'kv_log_store.dart';

/// Authenticated maintenance hints, not authorization or anti-rollback state.
/// Missing means a never-repacked identity; malformed data is never reset.
final class ManagedReclaimBudget {
  ManagedReclaimBudget({
    this.contentBytes = 0,
    this.contentOwned = 0,
    this.maintenanceBytes = 0,
  }) {
    for (final value in [contentBytes, contentOwned, maintenanceBytes]) {
      if (value < 0 || value > 0x7fffffffffffffff) {
        throw ArgumentError('Invalid managed reclamation budget');
      }
    }
  }
  final int contentBytes;
  final int contentOwned;
  final int maintenanceBytes;
  static const contentFloor = 64 * 1024 * 1024;
  static const maintenanceFloor = 8 * 1024 * 1024;
  static const _magic = [0x58, 0x56, 0x52, 0x43, 1, 0, 0, 0];
  static Uint8List get _key => Uint8List.fromList([0x78, 0x56, 0x72, 1]);

  bool contentDue(int bytes, int? owned, {bool force = false}) {
    _observed(bytes, owned);
    if (force) return true;
    if (bytes < contentFloor) return false;
    // Subtraction avoids overflowing a doubled historical size. Live growth
    // is amortized; deletion can trigger without additional file growth.
    final grown =
        bytes >= contentBytes &&
        bytes - contentBytes >= max(contentFloor, contentBytes);
    final deleted =
        owned != null &&
        contentOwned > 0 &&
        owned < contentOwned - contentOwned ~/ 4;
    return grown || deleted;
  }

  bool maintenanceDue(int bytes, {bool force = false}) {
    _observed(bytes, null);
    return force ||
        (bytes >= maintenanceBytes &&
            bytes - maintenanceBytes >=
                max(maintenanceFloor, maintenanceBytes));
  }

  static void _observed(int bytes, int? owned) {
    if (bytes < 0 || (owned != null && owned < 0)) {
      throw ArgumentError('Invalid managed reclamation observation');
    }
  }

  Uint8List encode() {
    final result = Uint8List(32)..setRange(0, 8, _magic);
    final data = ByteData.sublistView(result);
    data.setUint64(8, contentBytes, Endian.big);
    data.setUint64(16, contentOwned, Endian.big);
    data.setUint64(24, maintenanceBytes, Endian.big);
    return result;
  }

  factory ManagedReclaimBudget.decode(Uint8List value) {
    if (value.length != 32) {
      throw const FormatException('Invalid managed reclamation budget');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (value[i] != _magic[i]) {
        throw const FormatException('Unknown managed reclamation budget');
      }
    }
    final data = ByteData.sublistView(value);
    try {
      return ManagedReclaimBudget(
        contentBytes: data.getUint64(8, Endian.big),
        contentOwned: data.getUint64(16, Endian.big),
        maintenanceBytes: data.getUint64(24, Endian.big),
      );
    } on ArgumentError {
      throw const FormatException('Invalid managed reclamation budget');
    }
  }

  static ManagedReclaimBudget read(KvLogStore maintenance) {
    final value = maintenance.get(Ns.settings, _key);
    return value == null
        ? ManagedReclaimBudget()
        : ManagedReclaimBudget.decode(value);
  }

  void write(KvLogStore maintenance) =>
      maintenance.commit([PutOp(Ns.settings, _key, encode())]);
}

/// Local size accounting; no path, local ID or key is an IPC result.
final class ManagedReclaimReport {
  const ManagedReclaimReport({
    required this.beforeBytes,
    required this.afterBytes,
    required this.contentRepacked,
    required this.maintenanceRepacked,
  });
  final int beforeBytes;
  final int afterBytes;
  final bool contentRepacked;
  final bool maintenanceRepacked;
  bool get changed => contentRepacked || maintenanceRepacked;
}
