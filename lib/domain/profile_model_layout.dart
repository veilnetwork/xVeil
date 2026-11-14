/// The on-disk model names shared by stores, bundle readers and headless
/// profile cleanup. This module must not import platform or Flutter APIs.
abstract final class ProfileModelLayout {
  static const speechFile = 'ggml-base-q5_1.bin';
  static const translationDirectory = 'translate';
  static const translationFiles = <String>[
    'model.bin',
    'config.json',
    'shared_vocabulary.json',
    'source.spm',
    'target.spm',
  ];
}
