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
  preferencesAccessPolicy,
  preferencesStagingAccess,
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

enum ManagedAclRight {
  read,
  write,
  execute,
  delete,
  deleteChildren,
  changePermissions,
  changeOwner,
  fullControl,
  other,
}

typedef ManagedAclGrant = ({String account, Set<ManagedAclRight> rights});

/// Local UI evidence. Keep this out of reports, logs and app preferences.
final class ManagedStorageAclWarning {
  ManagedStorageAclWarning({
    required this.path,
    required this.fingerprint,
    required Iterable<ManagedAclGrant> grants,
    this.directory = true,
    this.owner,
    this.extendedAcl,
    this.canContinue = true,
    this.readOnlyInApp = false,
    this.grantsArePotential = false,
  }) : grants = List.unmodifiable(grants);

  final String path;
  final String fingerprint;
  final List<ManagedAclGrant> grants;
  final bool directory;
  final String? owner;
  final String? extendedAcl;
  final bool canContinue;
  final bool readOnlyInApp;
  final bool grantsArePotential;

  ManagedStorageAclWarning withPolicy({
    bool? canContinue,
    bool? readOnlyInApp,
  }) => ManagedStorageAclWarning(
    path: path,
    fingerprint: fingerprint,
    grants: grants,
    directory: directory,
    owner: owner,
    extendedAcl: extendedAcl,
    canContinue: canContinue ?? this.canContinue,
    readOnlyInApp: readOnlyInApp ?? this.readOnlyInApp,
    grantsArePotential: grantsArePotential,
  );
}

/// The exception text is safe to log. Permission details are local to
/// the startup UI and must never be serialized with the exception.
final class ManagedFsFailure implements Exception {
  const ManagedFsFailure(
    this.kind, {
    this.unsafeReason,
    this.ancestorRefusal,
    this.path,
    this.aclWarnings = const [],
  });
  final ManagedFsFailureKind kind;
  final ManagedFsUnsafeReason? unsafeReason;
  final ManagedAncestorRefusal? ancestorRefusal;
  final String? path;
  final List<ManagedStorageAclWarning> aclWarnings;
  @override
  String toString() => 'ManagedFsFailure(${kind.name})';
}

/// A witness for the object inspected, not a claim of descriptor-relative I/O.
/// Private roots exclude other-user mutation; repeated checks detect ordinary
/// path replacement, but do not defend against hostile same-user ABA races.
/// Consent is kept apart from the observed facts so strict callers can still
/// require a private object. Approval applies only to the observed ACL.
final class ManagedPathWitness {
  const ManagedPathWitness({
    required this.identity,
    required this.directory,
    required this.ownerOnly,
    required this.ownedByCurrentUser,
    required this.safeAncestor,
    this.unsafeAncestorCause,
    this.aclWarning,
    this.aclApproved = false,
    this.ownedByWindowsAdministrators = false,
    this.otherUsersHaveReadOnlyAccess = false,
  });
  final String identity;
  final bool directory;
  final bool ownerOnly;
  final bool ownedByCurrentUser;
  final bool safeAncestor;
  final ManagedAncestorRefusalCause? unsafeAncestorCause;
  final ManagedStorageAclWarning? aclWarning;
  final bool aclApproved;
  bool get admitsAncestor => safeAncestor || aclApproved;
  final bool ownedByWindowsAdministrators;
  final bool otherUsersHaveReadOnlyAccess;

  bool sameObject(ManagedPathWitness other) => identity == other.identity;
}
