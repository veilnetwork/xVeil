/// Identity of the Dart program actually answering the authenticated stand
/// hook. File hashes beside an app are insufficient: an AOT engine ignores a
/// freshly copied kernel_blob.bin and can keep running an old App.framework.
/// These compile-time values let the driver reject that mismatch before it
/// unlocks a container. They contain code/build metadata only.
Map<String, Object> debugCompiledBuildIdentity() => const {
  'version': String.fromEnvironment('XVEIL_VERSION', defaultValue: 'dev'),
  'sourceRevision': String.fromEnvironment('XVEIL_SOURCE_REVISION'),
  'sourceDigest': String.fromEnvironment('XVEIL_SOURCE_DIGEST'),
  'mode': bool.fromEnvironment('dart.vm.product')
      ? 'release'
      : bool.fromEnvironment('dart.vm.profile')
      ? 'profile'
      : 'debug',
  'diagnostics': bool.fromEnvironment('XVEIL_DIAGNOSTICS'),
};
