/// Logical file lengths for ONE enumerable identity, not allocated disk
/// blocks or an estimate of space freed by deletion (sparse/COW files differ).
/// Contains no paths, identity IDs or secrets. The shared catalog is excluded.
final class StorageUsage {
  const StorageUsage({
    required this.dataBytes,
    required this.blobBytes,
    required this.metadataBytes,
    required this.otherBytes,
    required this.files,
    required this.unrecognizedEntries,
  });

  final int dataBytes;
  final int blobBytes;
  final int metadataBytes;
  final int otherBytes;
  final int files;

  /// Unexpected files/directories are counted, never silently adopted as
  /// disposable application data. Even an empty unknown directory counts.
  final int unrecognizedEntries;
  int get totalBytes => dataBytes + blobBytes + metadataBytes + otherBytes;
}

abstract interface class StorageUsageSource {
  /// Null means unsupported; errors mean no complete measurement was obtained.
  Future<StorageUsage?> storageUsage();
}
