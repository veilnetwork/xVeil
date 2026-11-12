import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/veil_stack.dart';

/// Produce a real master-signed invitation document without mutating the source.
/// All input material belongs to the synthetic stand; only the public document
/// leaves this helper. This does not mock signature or merge verification.
Future<Uint8List> privateLinkDocument(
  Storage source, {
  required Uint8List publicKey,
  required String secret,
}) async {
  final raw = await readSovereignMaterial(source);
  final credential = await readSovereignCredential(source);
  if (raw == null || credential.corrupt || credential.bundle == null) {
    throw StateError('link fixture needs complete source material');
  }
  final copy = _SigningCopy(await source.loadNodeConfig(), {
    kSovereignIdentitySetting: Uint8List.fromList(utf8.encode(raw)),
    kSovereignBundleSetting: Uint8List.fromList(credential.bundle!),
  });
  try {
    final result = await RealVeilStack.delegateDeviceIntoDocument(
      copy,
      secret: secret,
      devicePubkey: publicKey,
      stagingBase: Directory.systemTemp.path,
    );
    if (!result.documentNamesDevice ||
        await readSovereignMaterial(source) != raw) {
      throw StateError('link fixture did not preserve source material');
    }
    return (await RealVeilStack.storedSovereignDocument(copy))!;
  } finally {
    for (final bytes in copy.files.values) {
      bytes.fillRange(0, bytes.length, 0);
    }
    copy.files.clear();
  }
}

class _SigningCopy implements Storage {
  _SigningCopy(this.config, this.files);
  final String? config;
  final Map<String, Uint8List> files;
  final settings = <String, String>{};
  @override
  Future<String?> loadNodeConfig() async => config;
  @override
  Future<String?> getSetting(String key) async => settings[key];
  @override
  Future<void> putSetting(String key, String value) async =>
      settings[key] = value;
  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) async =>
      files[fileId] == null ? null : Uint8List.fromList(files[fileId]!);
  @override
  Future<void> storeFile(
    String fileId,
    Uint8List bytes, {
    String? name,
    List<String> retireHints = const [],
  }) async => files[fileId] = Uint8List.fromList(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
