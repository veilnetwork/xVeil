enum ManagedFsFailureKind {
  unavailable,
  unsafe,
  changed,
  io,
  missingCatalog,
  erasurePending,
}

/// Safe to surface in diagnostics: never includes a path, owner or native text.
final class ManagedFsFailure implements Exception {
  const ManagedFsFailure(this.kind);
  final ManagedFsFailureKind kind;
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
  });
  final String identity;
  final bool directory;
  final bool ownerOnly;
  final bool ownedByCurrentUser;
  final bool safeAncestor;
  final bool ownedByWindowsAdministrators;

  bool sameObject(ManagedPathWitness other) => identity == other.identity;
}
