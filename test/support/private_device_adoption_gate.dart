import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/state/group_service.dart';

/// Test-only SIGSTOP immediately before/after a real encrypted adoption write.
/// No application endpoint, native verifier or durable write is substituted.
class PrivateDeviceAdoptionGate extends HiddenVolumeStorage {
  PrivateDeviceAdoptionGate(super.opener, {required this.directory})
    : super.async();

  final Directory directory;
  bool _captured = false;

  Map<String, dynamic>? _armFor(String write) {
    if (_captured) return null;
    final file = File('${directory.path}/adoption-arm.json');
    if (!file.existsSync()) return null;
    if (file.lengthSync() > 16384) {
      throw StateError('adoption arm too large');
    }
    final value = jsonDecode(file.readAsStringSync());
    if (value is! Map<String, dynamic> ||
        value['nonce'] is! String ||
        (value['nonce'] as String).isEmpty ||
        !const [
          'document',
          'admission',
          'activation',
          'consumption',
        ].contains(value['write']) ||
        !const ['before', 'after'].contains(value['phase'])) {
      throw StateError('invalid adoption arm');
    }
    if (value['write'] != write) return null;
    _captured = true;
    return value;
  }

  @override
  Future<void> storeFileWithSetting(
    StoredFileWrite file, {
    required String settingKey,
    required String settingValue,
  }) async {
    final arm = settingKey == 'devices.gid' ? _armFor('activation') : null;
    final digest = arm == null
        ? null
        : sha256.convert(utf8.encode(settingValue)).toString();
    if (arm?['phase'] == 'before') _pause(arm!, digest!);
    await super.storeFileWithSetting(
      file,
      settingKey: settingKey,
      settingValue: settingValue,
    );
    if (arm?['phase'] == 'after') _pause(arm!, digest!);
  }

  @override
  Future<void> putSetting(String key, String value) async {
    final arm = key == 'devices.gid' ? _armFor('activation') : null;
    final digest = arm == null
        ? null
        : sha256.convert(utf8.encode(value)).toString();
    if (arm?['phase'] == 'before') _pause(arm!, digest!);
    await super.putSetting(key, value);
    if (arm?['phase'] == 'after') _pause(arm!, digest!);
  }

  @override
  Future<void> storeFile(
    String fileId,
    Uint8List bytes, {
    String? name,
    List<String> retireHints = const [],
  }) async {
    Map<String, dynamic>? arm;
    if (fileId == kSovereignIdentitySetting) {
      arm = _armFor('document');
    } else if (fileId == GroupService.kPendingDeviceAdoptionFile) {
      arm = _armFor(bytes.isEmpty ? 'consumption' : 'admission');
    }
    final digest = arm == null ? null : sha256.convert(bytes).toString();
    if (arm?['phase'] == 'before') _pause(arm!, digest!);
    await super.storeFile(fileId, bytes, name: name, retireHints: retireHints);
    if (arm?['phase'] == 'after') _pause(arm!, digest!);
  }

  Never _pause(Map<String, dynamic> arm, String digest) {
    final marker = File('${directory.path}/adoption-reached.json');
    final temporary = File('${marker.path}.new');
    temporary.writeAsStringSync(
      jsonEncode({
        'nonce': arm['nonce'],
        'write': arm['write'],
        'phase': arm['phase'],
        'processId': pid,
        'proposedSha256': digest,
        'storeReturned': arm['phase'] == 'after',
      }),
      flush: true,
    );
    temporary.renameSync(marker.path);
    // No await after the witness: no callback can advance admission or reply.
    if (!Process.killPid(pid, ProcessSignal.sigstop)) {
      throw StateError('could not suspend adoption worker');
    }
    throw StateError('adoption crash worker must not be resumed');
  }
}
