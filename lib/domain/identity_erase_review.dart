/// Ephemeral consent for one authenticated, unchanged identity directory.
/// Counts are local UI data. The opaque worker-bound token is never persisted
/// or exported in diagnostics and is not a credential on its own.
final class IdentityEraseReview {
  const IdentityEraseReview({
    required this.token,
    required this.files,
    required this.directories,
    required this.bytes,
  });
  final String token;
  final int files, directories, bytes;
}
