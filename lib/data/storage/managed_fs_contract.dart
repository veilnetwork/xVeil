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

// Keep the ordinal values stable in exported diagnostics.
enum ManagedAncestorRefusalCause {
  notDirectory,
  untrustedOwner,
  unsafePermissions,
}

/// Distance from the starting directory of the admission check, in 0..255.
typedef ManagedAncestorRefusal = ({
  int depth,
  ManagedAncestorRefusalCause? cause,
});

/// Local UI evidence. Keep this out of reports, logs and app preferences.
final class ManagedWindowsDeleteWarning {
  ManagedWindowsDeleteWarning({
    required this.path,
    required this.fingerprint,
    required Iterable<({String account, bool canList})> grants,
  }) : grants = List.unmodifiable(grants);

  final String path;
  final String fingerprint;
  final List<({String account, bool canList})> grants;
}

/// The exception text is safe to log. Windows warning details are local to
/// the startup UI and must never be serialized with the exception.
final class ManagedFsFailure implements Exception {
  const ManagedFsFailure(
    this.kind, {
    this.unsafeReason,
    this.ancestorRefusal,
    this.windowsDeleteWarning,
  });
  final ManagedFsFailureKind kind;
  final ManagedFsUnsafeReason? unsafeReason;
  final ManagedAncestorRefusal? ancestorRefusal;
  final ManagedWindowsDeleteWarning? windowsDeleteWarning;
  @override
  String toString() => 'ManagedFsFailure(${kind.name})';
}

/// A witness for the object inspected, not a claim of descriptor-relative I/O.
/// Private roots exclude other-user mutation; repeated checks detect ordinary
/// path replacement, but do not defend against hostile same-user ABA races.
/// A Windows ancestor can also be admitted by explicit user consent for its
/// exact DELETE grant. That consent accepts the risk of replacement.
final class ManagedPathWitness {
  const ManagedPathWitness({
    required this.identity,
    required this.directory,
    required this.ownerOnly,
    required this.ownedByCurrentUser,
    required this.safeAncestor,
    this.unsafeAncestorCause,
    this.windowsDeleteWarning,
    this.ownedByWindowsAdministrators = false,
    this.otherUsersHaveReadOnlyAccess = false,
  });
  final String identity;
  final bool directory;
  final bool ownerOnly;
  final bool ownedByCurrentUser;
  final bool safeAncestor;
  final ManagedAncestorRefusalCause? unsafeAncestorCause;
  final ManagedWindowsDeleteWarning? windowsDeleteWarning;
  final bool ownedByWindowsAdministrators;
  final bool otherUsersHaveReadOnlyAccess;

  bool sameObject(ManagedPathWitness other) => identity == other.identity;
}
