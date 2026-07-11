import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/identity/veil_identity.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/veil_stack.dart';

/// The provenance contract of the deniable boot's config step (phrase epic
/// P4): a FRESH provision records [kIdentityOriginSetting] ('phrase' or
/// 'mined'), while a space with an existing config keeps its marker state
/// untouched — a legacy space (config present, marker absent) must stay
/// honestly "no phrase" forever. Env-gated on VEIL_FFI_DYLIB.
class _MemStorage implements Storage {
  String? config;
  final settings = <String, String>{};

  @override
  Future<String?> loadNodeConfig() async => config;
  @override
  Future<void> saveNodeConfig(String configToml) async => config = configToml;
  @override
  Future<void> putSetting(String key, String value) async =>
      settings[key] = value;
  @override
  Future<String?> getSetting(String key) async => settings[key];

  // ensureNodeConfig touches nothing else on Storage.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final hasDylib = dylib?.isNotEmpty ?? false;
  final skip = hasDylib ? false : 'set VEIL_FFI_DYLIB to libveilclient_ffi';

  test('fresh provision from a phrase records origin=phrase', () async {
    final lib = DynamicLibrary.open(dylib!);
    final storage = _MemStorage();
    final toml = await RealVeilStack.ensureNodeConfig(
      storage,
      identityPhrase: veilGeneratePhrase()!,
      lib: lib,
    );
    expect(toml, isNotEmpty);
    expect(storage.config, toml, reason: 'config persisted');
    expect(storage.settings[kIdentityOriginSetting], 'phrase');
  }, skip: skip);

  test('fresh provision without a phrase records origin=mined', () async {
    final lib = DynamicLibrary.open(dylib!);
    final storage = _MemStorage();
    await RealVeilStack.ensureNodeConfig(storage, lib: lib);
    expect(storage.settings[kIdentityOriginSetting], 'mined');
  }, skip: skip);

  test(
      'an existing config short-circuits: nothing rewritten, a legacy space '
      'never gains a marker (stays honestly "no phrase")', () async {
    final lib = DynamicLibrary.open(dylib!);
    final storage = _MemStorage()..config = 'stored = "legacy"';
    final toml = await RealVeilStack.ensureNodeConfig(
      storage,
      identityPhrase: veilGeneratePhrase()!,
      lib: lib,
    );
    expect(toml, 'stored = "legacy"');
    expect(storage.settings, isEmpty);
  }, skip: skip);
}
