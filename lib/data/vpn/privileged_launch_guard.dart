/// Refusing to hand a user-writable executable to UAC / polkit (audit X-01).
///
/// The system VPN elevates THIS executable: Windows re-launches `xveil.exe`
/// with `-Verb RunAs`, Linux re-execs it under `pkexec`. Both dialogs already
/// exist, and neither is the defect. The defect is WHAT gets elevated — the
/// release is a portable ZIP / an unpacked tarball, so the binary and every
/// library beside it sit in a directory the unprivileged user can rewrite.
/// Anything dropped there is then run as Administrator/root by a prompt the
/// user has every reason to accept.
///
/// A narrow "verify the signature of the one helper DLL" check would be
/// theatre: `windows/runner/CMakeLists.txt` links Flutter, so
/// `flutter_windows.dll` and the plugin libraries are resolved by the loader
/// from the executable's own directory BEFORE `wWinMain` runs. Foreign code
/// would already be executing inside the elevated process by the time any
/// in-process check could look at anything. The only thing that helps is
/// refusing to elevate at all unless the whole path is out of reach.
///
/// So the guard asks one question — can an unprivileged principal change what
/// this path resolves to? — of the executable, of its directory, and of every
/// ancestor up to the root. A writable grandparent is just as fatal as a
/// writable leaf: swap the directory, keep the name.
///
/// Fail-closed everywhere. An ACL that cannot be read, a `stat` that will not
/// run, a relative or network path — all refuse. "Could not tell" is never
/// "probably fine" when the answer decides whether to start a root process.
library;

import 'dart:convert';
import 'dart:io';

/// What a path is doing in the chain. It decides which rights are fatal — the
/// masks genuinely differ, and using the strictest one everywhere would refuse
/// every real Windows installation.
enum PrivilegedPathRole {
  /// The binary that gets elevated.
  executable,

  /// The directory it sits in. As strict as the executable itself, because the
  /// loader takes the process's libraries from here: being able to CREATE a
  /// file next to the binary is as good as being able to rewrite the binary.
  executableDirectory,

  /// Anything above that. Creating unrelated entries here is harmless — what
  /// matters is whether our own child can be deleted, renamed or re-permitted
  /// out from under us.
  ancestorDirectory,
}

/// One step of the chain that has to be safe.
class PrivilegedPathStep {
  const PrivilegedPathStep(this.path, this.role);

  final String path;
  final PrivilegedPathRole role;

  @override
  bool operator ==(Object other) =>
      other is PrivilegedPathStep && other.path == path && other.role == role;

  @override
  int get hashCode => Object.hash(path, role);

  @override
  String toString() => '$path (${role.name})';
}

/// The rights that matter, named the same way on both platforms so the
/// decision below never has to know which one it is looking at.
enum FilesystemRight {
  /// Create entries in a directory, or rewrite a file's contents.
  createOrWriteContent,

  /// Delete/rename this entry itself.
  delete,

  /// Delete/rename entries INSIDE this directory — i.e. the next step down.
  deleteChild,

  /// Rewrite the entry's permissions, and thereby grant everything else.
  changePermissions,

  /// Take ownership, and thereby rewrite the permissions.
  takeOwnership,
}

/// Which of [FilesystemRight] an unprivileged principal must not hold, per role.
Set<FilesystemRight> fatalRightsFor(PrivilegedPathRole role) => switch (role) {
  PrivilegedPathRole.executable ||
  PrivilegedPathRole.executableDirectory => const {
    FilesystemRight.createOrWriteContent,
    FilesystemRight.delete,
    FilesystemRight.deleteChild,
    FilesystemRight.changePermissions,
    FilesystemRight.takeOwnership,
  },
  // Deliberately WITHOUT `createOrWriteContent`. The default DACL of `C:\`
  // lets any user create a folder there, and that is not a way to reach
  // `C:\Program Files\xVeil` — that directory breaks inheritance and is
  // protected on its own. Refusing on it would refuse every Windows install
  // and quietly turn this guard into "no VPN, ever".
  PrivilegedPathRole.ancestorDirectory => const {
    FilesystemRight.delete,
    FilesystemRight.deleteChild,
    FilesystemRight.changePermissions,
    FilesystemRight.takeOwnership,
  },
};

/// What the platform managed to establish about one path.
class PathSecurityFacts {
  const PathSecurityFacts({
    required this.path,
    required this.ownerIsPrivileged,
    required this.unprivilegedRights,
  }) : undeterminedReason = null;

  /// The probe could not establish the facts. Always refuses.
  const PathSecurityFacts.undetermined(this.path, String reason)
    : ownerIsPrivileged = false,
      unprivilegedRights = const {},
      undeterminedReason = reason;

  final String path;

  /// The owner always holds the implicit right to rewrite the permissions, so
  /// an entry owned by an unprivileged account is writable by it whatever the
  /// current ACL says.
  final bool ownerIsPrivileged;

  /// Rights held by principals that are not SYSTEM/Administrators/root.
  final Set<FilesystemRight> unprivilegedRights;

  final String? undeterminedReason;
}

/// The verdict, and the sentence the user gets to read when it refuses.
class PrivilegedLaunchVerdict {
  const PrivilegedLaunchVerdict.allowed() : offendingPath = null, reason = null;

  const PrivilegedLaunchVerdict.refused(this.offendingPath, this.reason);

  final String? offendingPath;
  final String? reason;

  bool get isAllowed => reason == null;

  /// Deliberately says what to DO. "Permission denied" would send the user
  /// hunting for a checkbox that does not exist; the actual fix is to install
  /// the app instead of running it out of the folder it was unpacked into.
  String get detail {
    if (isAllowed) return '';
    return 'the system VPN elevates this executable, and it is running from a '
        'location an ordinary user can rewrite ($offendingPath: $reason) — '
        'anything planted there would be elevated with it. Install xVeil to a '
        'protected location instead of running an unpacked portable copy.';
  }
}

/// The platform side. Only ever reports facts; every decision is made above it,
/// which is what keeps the Windows half testable without a Windows machine.
abstract interface class PathSecurityProbe {
  /// The path with every symbolic link resolved, or null if it cannot be.
  Future<String?> canonicalize(String path);

  /// Facts for [steps]. Any path it cannot establish must come back
  /// [PathSecurityFacts.undetermined] — never optimistic.
  Future<List<PathSecurityFacts>> inspect(List<PrivilegedPathStep> steps);
}

/// Every path that must be out of reach before [executable] may be elevated.
///
/// Ordered leaf-first, so the refusal names the most specific offender.
List<PrivilegedPathStep> privilegedPathChain(
  String executable, {
  required bool windows,
}) {
  final normalized = windows ? executable.replaceAll('/', r'\') : executable;
  final steps = <PrivilegedPathStep>[
    PrivilegedPathStep(normalized, PrivilegedPathRole.executable),
  ];
  var current = normalized;
  var role = PrivilegedPathRole.executableDirectory;
  // Bounded: a malformed path must not spin here.
  for (var guard = 0; guard < 128; guard++) {
    final parent = _parentOf(current, windows);
    if (parent == null || parent == current) break;
    steps.add(PrivilegedPathStep(parent, role));
    role = PrivilegedPathRole.ancestorDirectory;
    current = parent;
  }
  return steps;
}

String? _parentOf(String path, bool windows) {
  final separator = windows ? r'\' : '/';
  final index = path.lastIndexOf(separator);
  if (index < 0) return null;
  if (!windows) {
    if (index == 0) return path == '/' ? null : '/';
    return path.substring(0, index);
  }
  // Already a drive root (`C:\`).
  if (index == path.length - 1) return null;
  final head = path.substring(0, index);
  if (head.isEmpty) return null;
  if (RegExp(r'^[A-Za-z]:$').hasMatch(head)) return '$head\\';
  return head;
}

/// The decision for one path, given its facts.
///
/// Split out so the whole matrix — owner, each right, each role, undetermined
/// — is exercised without a filesystem, on any host.
String? refusalFor(PathSecurityFacts facts, PrivilegedPathRole role) {
  final undetermined = facts.undeterminedReason;
  if (undetermined != null) {
    return 'permissions could not be read ($undetermined)';
  }
  if (!facts.ownerIsPrivileged) {
    return 'owned by an account that is not an administrator, so it can '
        'rewrite its own permissions';
  }
  final fatal = fatalRightsFor(role).intersection(facts.unprivilegedRights);
  if (fatal.isEmpty) return null;
  return switch (fatal.first) {
    FilesystemRight.createOrWriteContent => 'an ordinary user can write to it',
    FilesystemRight.delete => 'an ordinary user can delete or rename it',
    FilesystemRight.deleteChild =>
      'an ordinary user can delete or rename what it contains',
    FilesystemRight.changePermissions =>
      'an ordinary user can rewrite its permissions',
    FilesystemRight.takeOwnership =>
      'an ordinary user can take ownership of it',
  };
}

/// Asks the question of the whole chain and answers once.
class PrivilegedLaunchGuard {
  PrivilegedLaunchGuard({required this.probe, required this.windows});

  /// The real thing, for the platform it is running on.
  factory PrivilegedLaunchGuard.forHost() => PrivilegedLaunchGuard(
    probe: Platform.isWindows
        ? const WindowsPathSecurityProbe()
        : const PosixPathSecurityProbe(),
    windows: Platform.isWindows,
  );

  final PathSecurityProbe probe;
  final bool windows;

  Future<PrivilegedLaunchVerdict> inspect(String executable) async {
    if (executable.isEmpty) {
      return const PrivilegedLaunchVerdict.refused(
        '',
        'the executable path is empty',
      );
    }
    if (windows) {
      if (executable.startsWith(r'\\') || executable.startsWith('//')) {
        return PrivilegedLaunchVerdict.refused(
          executable,
          'it is on a network share, whose permissions this machine cannot '
          'vouch for',
        );
      }
      if (!RegExp(r'^[A-Za-z]:[\\/]').hasMatch(executable)) {
        return PrivilegedLaunchVerdict.refused(
          executable,
          'it is not an absolute path',
        );
      }
    } else if (!executable.startsWith('/')) {
      return PrivilegedLaunchVerdict.refused(
        executable,
        'it is not an absolute path',
      );
    }

    // Both the literal path AND the path with links resolved have to be safe.
    // Checking only the resolved one misses a symlink an attacker can repoint;
    // checking only the literal one misses where it actually lands.
    final canonical = await probe.canonicalize(executable);
    if (canonical == null) {
      return PrivilegedLaunchVerdict.refused(
        executable,
        'the real location behind it could not be resolved',
      );
    }
    final steps = <String, PrivilegedPathStep>{};
    for (final step in [
      ...privilegedPathChain(canonical, windows: windows),
      ...privilegedPathChain(executable, windows: windows),
    ]) {
      final existing = steps[step.path];
      // A path reached as both leaf and ancestor keeps the stricter role.
      if (existing == null ||
          (existing.role == PrivilegedPathRole.ancestorDirectory &&
              step.role != PrivilegedPathRole.ancestorDirectory)) {
        steps[step.path] = step;
      }
    }
    final ordered = steps.values.toList();

    final List<PathSecurityFacts> facts;
    try {
      facts = await probe.inspect(ordered);
    } on Object catch (error) {
      return PrivilegedLaunchVerdict.refused(
        executable,
        'permissions could not be read ($error)',
      );
    }
    final byPath = {for (final entry in facts) entry.path: entry};
    for (final step in ordered) {
      final entry =
          byPath[step.path] ??
          PathSecurityFacts.undetermined(step.path, 'no answer from the probe');
      final refusal = refusalFor(entry, step.role);
      if (refusal != null) {
        return PrivilegedLaunchVerdict.refused(step.path, refusal);
      }
    }
    return const PrivilegedLaunchVerdict.allowed();
  }
}

// --- Linux -----------------------------------------------------------------

/// Owner must be uid 0, and neither group nor other may write.
///
/// Deliberately dereferences (`stat -L`): the mode of a symlink itself is
/// meaningless on Linux (always 777), and what actually decides whether a link
/// can be repointed is the write bit on its parent — which is a step of this
/// same chain and is checked in its own right.
///
/// Known limit: POSIX mode bits only. An extended ACL (`setfacl`) granting
/// write to somebody is invisible here. That is the shape the decision was
/// specified in; the fix, if it is ever wanted, is a `getfacl --skip-base`
/// pass whose non-empty output turns the entry undetermined.
class PosixPathSecurityProbe implements PathSecurityProbe {
  const PosixPathSecurityProbe();

  @override
  Future<String?> canonicalize(String path) async {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<List<PathSecurityFacts>> inspect(
    List<PrivilegedPathStep> steps,
  ) async {
    ProcessResult result;
    try {
      result = await Process.run(
        'stat',
        <String>[
          '-L',
          '-c',
          '%n\u0001%u\u0001%a',
          ...steps.map((step) => step.path),
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException catch (error) {
      return [
        for (final step in steps)
          PathSecurityFacts.undetermined(step.path, 'stat: ${error.message}'),
      ];
    }
    final parsed = <String, PathSecurityFacts>{};
    for (final line in const LineSplitter().convert(result.stdout as String)) {
      final fields = line.split('\u0001');
      if (fields.length != 3) continue;
      final uid = int.tryParse(fields[1]);
      final mode = int.tryParse(fields[2], radix: 8);
      if (uid == null || mode == null) continue;
      // Group- or other-writable. On POSIX that single bit is both "create
      // entries here" and "delete what is here", so it maps to both.
      final writable = mode & 0x12 != 0; // 0o020 | 0o002
      parsed[fields[0]] = PathSecurityFacts(
        path: fields[0],
        ownerIsPrivileged: uid == 0,
        unprivilegedRights: writable
            ? const {
                FilesystemRight.createOrWriteContent,
                FilesystemRight.deleteChild,
              }
            : const {},
      );
    }
    return [
      for (final step in steps)
        parsed[step.path] ??
            PathSecurityFacts.undetermined(
              step.path,
              'stat did not report this path',
            ),
    ];
  }
}

// --- Windows ---------------------------------------------------------------

/// Well-known SIDs, never account names: the names are localized, so a check
/// against `Users` would simply not match on a Russian install — and would
/// then find nothing to object to.
const Set<String> kPrivilegedWindowsSids = {
  'S-1-5-18', // NT AUTHORITY\SYSTEM
  'S-1-5-32-544', // BUILTIN\Administrators
  // NT SERVICE\TrustedInstaller
  'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',
};

/// `FileSystemRights` is a plain bitmask, so the mapping is pure and testable.
Set<FilesystemRight> windowsRightsFromMask(int mask) {
  const genericAll = 0x10000000;
  const genericWrite = 0x40000000;
  if (mask & genericAll != 0) return FilesystemRight.values.toSet();
  return <FilesystemRight>{
    // WriteData/CreateFiles | AppendData/CreateDirectories
    if (mask & 0x6 != 0 || mask & genericWrite != 0)
      FilesystemRight.createOrWriteContent,
    if (mask & 0x10000 != 0) FilesystemRight.delete, // DELETE
    if (mask & 0x40 != 0) FilesystemRight.deleteChild, // FILE_DELETE_CHILD
    if (mask & 0x40000 != 0) FilesystemRight.changePermissions, // WRITE_DAC
    if (mask & 0x80000 != 0) FilesystemRight.takeOwnership, // WRITE_OWNER
  };
}

/// Turns one `Get-Acl` answer into facts. Pure — this is where the Windows
/// decision is actually made, and it runs in the test suite on any host.
PathSecurityFacts windowsFactsFromAcl(String path, Object? decoded) {
  if (decoded is! Map) {
    return PathSecurityFacts.undetermined(path, 'unreadable ACL response');
  }
  final error = decoded['error'];
  if (error is String && error.isNotEmpty) {
    return PathSecurityFacts.undetermined(path, error);
  }
  final owner = decoded['owner'];
  if (owner is! String || owner.isEmpty) {
    return PathSecurityFacts.undetermined(path, 'the owner could not be read');
  }
  final rules = decoded['rules'];
  if (rules is! List) {
    return PathSecurityFacts.undetermined(path, 'the ACL could not be read');
  }
  final granted = <FilesystemRight>{};
  for (final rule in rules) {
    if (rule is! Map) {
      return PathSecurityFacts.undetermined(path, 'malformed ACL entry');
    }
    // Deny entries are ignored on purpose rather than subtracted: getting
    // Windows' allow/deny ordering subtly wrong would open the hole this is
    // here to close. Ignoring them can only refuse more often.
    if (rule['allow'] != true) continue;
    // Inherit-only entries grant nothing on the object itself — this is what
    // CREATOR OWNER on `C:\Program Files` is, and treating it as a grant would
    // refuse every real installation.
    if (rule['inheritOnly'] == true) continue;
    final sid = rule['sid'];
    if (sid is! String || sid.isEmpty) {
      return PathSecurityFacts.undetermined(path, 'an ACL entry had no SID');
    }
    if (kPrivilegedWindowsSids.contains(sid)) continue;
    final rights = rule['rights'];
    if (rights is! int) {
      return PathSecurityFacts.undetermined(path, 'an ACL entry had no rights');
    }
    granted.addAll(windowsRightsFromMask(rights));
  }
  return PathSecurityFacts(
    path: path,
    ownerIsPrivileged: kPrivilegedWindowsSids.contains(owner),
    unprivilegedRights: granted,
  );
}

/// Reads owner + DACL through PowerShell, which `probe()` has already
/// established is present. Nothing but fact collection lives here.
class WindowsPathSecurityProbe implements PathSecurityProbe {
  const WindowsPathSecurityProbe();

  @override
  Future<String?> canonicalize(String path) async {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<List<PathSecurityFacts>> inspect(
    List<PrivilegedPathStep> steps,
  ) async {
    ProcessResult result;
    try {
      result = await Process.run(
        'powershell.exe',
        <String>[
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          buildWindowsAclScript(steps.map((step) => step.path).toList()),
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException catch (error) {
      return [
        for (final step in steps)
          PathSecurityFacts.undetermined(
            step.path,
            'Get-Acl: ${error.message}',
          ),
      ];
    }
    if (result.exitCode != 0) {
      final detail = (result.stderr as String).trim();
      return [
        for (final step in steps)
          PathSecurityFacts.undetermined(
            step.path,
            detail.isEmpty ? 'Get-Acl failed' : 'Get-Acl failed: $detail',
          ),
      ];
    }
    return decodeWindowsAclReport(
      steps.map((step) => step.path).toList(),
      result.stdout as String,
    );
  }
}

/// Splits the JSON answer back out per path. Pure, so the parser is covered
/// with recorded PowerShell output instead of a Windows host.
List<PathSecurityFacts> decodeWindowsAclReport(
  List<String> paths,
  String stdout,
) {
  Object? decoded;
  try {
    decoded = jsonDecode(stdout.trim());
  } on FormatException {
    return [
      for (final path in paths)
        PathSecurityFacts.undetermined(path, 'Get-Acl returned no usable JSON'),
    ];
  }
  // `ConvertTo-Json` collapses a one-element array to a bare object.
  final entries = decoded is List ? decoded : [decoded];
  final byPath = <String, Object?>{};
  for (final entry in entries) {
    if (entry is Map && entry['path'] is String) {
      byPath[entry['path'] as String] = entry;
    }
  }
  return [
    for (final path in paths)
      byPath.containsKey(path)
          ? windowsFactsFromAcl(path, byPath[path])
          : PathSecurityFacts.undetermined(path, 'Get-Acl skipped this path'),
  ];
}

/// The PowerShell side is kept to fact collection and quoted the same way the
/// elevation script is — single quotes, doubled inside, no interpolation of
/// anything that came from outside.
String buildWindowsAclScript(List<String> paths) {
  String quote(String value) => "'${value.replaceAll("'", "''")}'";
  final literal = paths.map(quote).join(',');
  return '\$ErrorActionPreference = '
      r"'Stop'"
      '; '
      '\$paths = @($literal); '
      r'''$out = New-Object System.Collections.ArrayList; foreach ($p in $paths) { $entry = @{ path = $p }; try { $acl = Get-Acl -LiteralPath $p; $entry.owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value; $rules = New-Object System.Collections.ArrayList; foreach ($r in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) { [void]$rules.Add(@{ sid = $r.IdentityReference.Value; rights = [int]$r.FileSystemRights; allow = ($r.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow); inheritOnly = (($r.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) }) }; $entry.rules = $rules } catch { $entry.error = $_.Exception.Message }; [void]$out.Add($entry) }; ConvertTo-Json -InputObject @($out) -Depth 6 -Compress''';
}
