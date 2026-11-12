import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';

/// Lose one completion after the real identity material store has succeeded.
/// Imported only by the synthetic process fixture, never the application.
class PrivateSovereignWriteFault extends HiddenVolumeStorage {
  PrivateSovereignWriteFault(super.opener, {required this.directory})
    : super.async();

  final Directory directory;
  bool _used = false;

  @override
  Future<void> storeFile(
    String fileId,
    Uint8List bytes, {
    String? name,
    List<String> retireHints = const [],
  }) async {
    await super.storeFile(fileId, bytes, name: name, retireHints: retireHints);
    if (_used || fileId != kSovereignIdentitySetting) return;
    final arm = File('${directory.path}/sovereign-write-arm.json');
    if (!arm.existsSync()) return;
    if (arm.lengthSync() > 16384) {
      throw StateError('identity fault arm too large');
    }
    final value = jsonDecode(arm.readAsStringSync()) as Map;
    final nonce = value['nonce'];
    if (nonce is! String || nonce.isEmpty) {
      throw StateError('invalid identity fault nonce');
    }
    final material = decodeSovereignIdentity(utf8.decode(bytes));
    final document = material?[kIdentityDocumentFile];
    if (document == null) throw StateError('identity fault needs a document');
    _used = true;
    final marker = File('${directory.path}/sovereign-write-reached.json');
    final temp = File('${marker.path}.new');
    temp.writeAsStringSync(
      jsonEncode({
        'nonce': nonce,
        'processId': pid,
        'storeReturned': true,
        'document': base64Encode(document),
      }),
      flush: true,
    );
    temp.renameSync(marker.path);
    throw StateError('fixture lost identity write completion');
  }
}
