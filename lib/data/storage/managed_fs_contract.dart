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
typedef ManagedInheritedAclGrant = ({
  String account,
  Set<ManagedAclRight> rights,
  bool files,
  bool directories,
  bool directChildrenOnly,
});

/// Local UI evidence. Keep this out of reports, logs and app preferences.
final class ManagedStorageAclWarning {
  ManagedStorageAclWarning({
    required this.path,
    required this.fingerprint,
    required Iterable<ManagedAclGrant> grants,
    Iterable<ManagedAclGrant> inheritedGrants = const [],
    Iterable<ManagedInheritedAclGrant> inheritedScopes = const [],
    this.directory = true,
    this.owner,
    this.extendedAcl,
    this.canContinue = true,
    this.readOnlyInApp = false,
    this.grantsArePotential = false,
  }) : grants = List.unmodifiable(grants),
       inheritedGrants = List.unmodifiable(inheritedGrants),
       inheritedScopes = List.unmodifiable(inheritedScopes);

  final String path;
  final String fingerprint;
  final List<ManagedAclGrant> grants;
  final List<ManagedAclGrant> inheritedGrants;
  final List<ManagedInheritedAclGrant> inheritedScopes;
  final bool directory;
  final String? owner;
  final String? extendedAcl;
  final bool canContinue;
  final bool readOnlyInApp;
  final bool grantsArePotential;

  ManagedStorageAclWarning withPolicy({
    String? fingerprint,
    bool? canContinue,
    bool? readOnlyInApp,
  }) => ManagedStorageAclWarning(
    path: path,
    fingerprint: fingerprint ?? this.fingerprint,
    grants: grants,
    inheritedGrants: inheritedGrants,
    inheritedScopes: inheritedScopes,
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
/// Exact local inventory requiring separate approval before whole-profile erasure.
final class ManagedErasureContentsReview {
  ManagedErasureContentsReview(this.fingerprint, Iterable<String> paths)
    : paths = List.unmodifiable(paths);

  final String fingerprint;
  final List<String> paths;
}

final class ManagedFsFailure implements Exception {
  const ManagedFsFailure(
    this.kind, {
    this.unsafeReason,
    this.ancestorRefusal,
    this.path,
    this.posixError,
    this.erasureReview,
    this.aclWarnings = const [],
  });
  final ManagedFsFailureKind kind;
  final ManagedFsUnsafeReason? unsafeReason;
  final ManagedAncestorRefusal? ancestorRefusal;
  final String? path;
  final int? posixError;
  final ManagedErasureContentsReview? erasureReview;
  bool get accessDenied =>
      posixError == 1 ||
      posixError == 13 ||
      unsafeReason == ManagedFsUnsafeReason.windowsPathAccessDenied;
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
    this.permissionFingerprint,
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
  final String? permissionFingerprint;

  String get accessPolicy =>
      permissionFingerprint ??
      '${aclWarning?.fingerprint}:$ownerOnly:$ownedByCurrentUser:$safeAncestor';

  bool sameObject(ManagedPathWitness other) => identity == other.identity;
}
