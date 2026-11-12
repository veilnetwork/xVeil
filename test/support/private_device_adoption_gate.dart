import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/state/group_service.dart';

/// Test-only SIGSTOP immediately before/after a real encrypted adoption write.
/// No application endpoint, native verifier or durable write is substituted.
class PrivateDeviceAdoptionGate extends HiddenVolumeStorage {
  PrivateDeviceAdoptionGate(super.opener, {required this.directory})
    : super.async();

  final Directory directory;
  bool _captured = false;

  @override
  Future<void> storeFile(
    String fileId,
    Uint8List bytes, {
    String? name,
    List<String> retireHints = const [],
  }) async {
    Map<String, dynamic>? arm;
    if (!_captured &&
        (fileId == kSovereignIdentitySetting ||
            fileId == GroupService.kPendingDeviceAdoptionFile)) {
      final file = File('${directory.path}/adoption-arm.json');
      if (file.existsSync()) {
        if (file.lengthSync() > 16384) {
          throw StateError('adoption arm too large');
        }
        final value = jsonDecode(file.readAsStringSync());
        if (value is! Map<String, dynamic> ||
            value['nonce'] is! String ||
            (value['nonce'] as String).isEmpty ||
            !const ['document', 'admission'].contains(value['write']) ||
            !const ['before', 'after'].contains(value['phase'])) {
          throw StateError('invalid adoption arm');
        }
        final target = value['write'] == 'document'
            ? kSovereignIdentitySetting
            : GroupService.kPendingDeviceAdoptionFile;
        if (fileId == target) {
          arm = value;
          _captured = true;
        }
      }
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
