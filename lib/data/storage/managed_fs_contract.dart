enum ManagedFsFailureKind {
  unavailable,
  unsafe,
  changed,
  io,
  missingCatalog,
  erasurePending,
}

enum ManagedFsUnsafeReason {
  invalidProfilePath,
  windowsNonDrivePath,
  windowsPathAccessDenied,
  windowsPathOpenFailed,
  windowsPathInfoFailed,
  windowsReparsePoint,
  profileNotDirectory,
  profileOwner,
  unsafeAncestor,
  privateDirectory,
  privateFile,
  invalidLifetimeLock,
}

/// Safe to surface in diagnostics: never includes a path, owner or native text.
final class ManagedFsFailure implements Exception {
  const ManagedFsFailure(this.kind, {this.unsafeReason});
  final ManagedFsFailureKind kind;
  final ManagedFsUnsafeReason? unsafeReason;
  @override
  String toString() => 'ManagedFsFailure(${kind.name})';
}

/// A witness for the object inspected, not a claim of descriptor-relative I/O.
/// Private roots exclude other-user mutation; repeated checks detect ordinary
/// path replacement, but do not defend against hostile same-user ABA races.
final class ManagedPathWitness {
  const ManagedPathWitness({
    required this.identity,
    required this.directory,
    required this.ownerOnly,
    required this.ownedByCurrentUser,
    required this.safeAncestor,
    this.ownedByWindowsAdministrators = false,
    this.otherUsersHaveReadOnlyAccess = false,
  });
  final String identity;
  final bool directory;
  final bool ownerOnly;
  final bool ownedByCurrentUser;
  final bool safeAncestor;
  final bool ownedByWindowsAdministrators;
  final bool otherUsersHaveReadOnlyAccess;

  bool sameObject(ManagedPathWitness other) => identity == other.identity;
}
