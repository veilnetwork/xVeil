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
/// Fail-closed everywhere. An ACL that cannot be read, an `lstat` that fails,
/// a relative or network path — all refuse. "Could not tell" is never
/// "probably fine" when the answer decides whether to start a root process.
///
/// And the guard never asks a program PATH chose. The first version of this
/// read owner and mode by running `stat`, then the elevation itself ran a bare
/// `pkexec`: a wrapper dropped into any PATH component answered the question
/// AND was handed the answer's consequence (audit C-01). POSIX facts now come
/// from libc directly, and every helper this file will run is named by
/// absolute path and checked before it is used.
library;

import 'dart:io';

import '../../core/posix_file_facts.dart';
import 'native_path_acl.dart';

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

/// Why the name asked about is not the object that answered, or null.
///
/// The handle resolves the whole name, so a junction ABOVE the leaf does not
/// refuse — it silently answers about somewhere else. The final path is how
/// that becomes visible: `C:\\src\\link\\System32` comes back as
/// `C:\\Windows\\System32`, and the two not matching is the fact.
///
/// Kept pure and out of the probe so the comparison is exercised on any host,
/// like every other decision in this file. Case-insensitive because Windows
/// paths are; an 8.3 abbreviated name also lands here, and is named in the
/// message rather than guessed at — refusing is the safe end of that.
String? pathResolutionMismatch(String requested, Object? finalPath) {
  if (finalPath is! String || finalPath.isEmpty) return null;
  final resolved = stripExtendedLengthPrefix(finalPath);
  if (resolved.toLowerCase() == requested.toLowerCase()) return null;
  return 'it resolves to $resolved, so a component of it is a junction, a '
      'symbolic link or an abbreviated name';
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

/// Turns one `lstat(2)` answer into facts. Pure, so the whole mapping is
/// covered without needing a root-owned path to point it at.
///
/// [stat] is null when the call failed or the host cannot answer at all —
/// which is a refusal, not a shrug.
PathSecurityFacts posixFactsFromStat(String path, PosixFileFacts? stat) {
  if (stat == null) {
    return PathSecurityFacts.undetermined(
      path,
      'lstat(2) could not read this path',
    );
  }
  if (stat.isSymlink) {
    // The mode of a symlink is meaningless (0777 on Linux, and nothing
    // enforces it anywhere), so only its OWNER is evidence. What decides
    // whether the link can be repointed is the write bit on its parent, and
    // what it currently points at is walked as its own chain — both are steps
    // of this same walk, judged in their own right.
    return PathSecurityFacts(
      path: path,
      ownerIsPrivileged: stat.uid == 0,
      unprivilegedRights: const {},
    );
  }
  // Group- or other-writable. On POSIX that single bit is both "create
  // entries here" and "delete what is here", so it maps to both.
  return PathSecurityFacts(
    path: path,
    ownerIsPrivileged: stat.uid == 0,
    unprivilegedRights: stat.groupOrOtherWritable
        ? const {
            FilesystemRight.createOrWriteContent,
            FilesystemRight.deleteChild,
          }
        : const {},
  );
}

/// Owner must be uid 0, and neither group nor other may write.
///
/// Facts come from libc's `lstat`, never from a subprocess. `stat` is a bare
/// command name, so whoever can drop a file into a PATH component could answer
/// the question that decides whether this binary is handed to `pkexec`
/// (audit C-01). Nothing in the environment changes which `lstat` the process
/// already has.
///
/// `lstat` also means the link itself rather than what it points at, which the
/// old `stat -L` could not distinguish: [posixFactsFromStat] judges a link by
/// its owner, and the target is walked as its own chain.
///
/// Known limit, unchanged: POSIX mode bits only. An extended ACL (`setfacl`)
/// granting write to somebody is invisible here. That is the shape the
/// decision was specified in; the fix, if it is ever wanted, is an
/// `acl_get_file` pass whose extra entries turn the entry undetermined.
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
  ) async => [
    for (final step in steps)
      posixFactsFromStat(step.path, posixLstat(step.path)),
  ];
}

/// The absolute places a POSIX privilege helper may legitimately live.
///
/// Order decides only which one is found first; every candidate still has to
/// pass [resolveTrustedPosixTool] before it is used.
const List<String> kPkexecCandidates = <String>[
  '/usr/bin/pkexec',
  '/bin/pkexec',
  '/usr/local/bin/pkexec',
  // NixOS keeps its setuid wrappers here and has no /usr/bin at all.
  '/run/wrappers/bin/pkexec',
];

/// The first of [candidates] that exists and is safe to run as a step towards
/// root: a real file, owned by root, not writable by anybody else.
///
/// PATH is not consulted, which is the entire point. The old code ran `pkexec`
/// by bare name, so the guard could pass on the real installation while the
/// elevation went to a wrapper the attacker had planted earlier in PATH — the
/// wrapper only had to forward to the real thing for the polkit dialog to look
/// exactly as expected (audit C-01).
///
/// [stat] is injectable so both answers stay testable on a host that has no
/// polkit at all.
String? resolveTrustedPosixTool(
  List<String> candidates, {
  PosixFileFacts? Function(String path)? stat,
}) {
  final read = stat ?? posixLstat;
  for (final candidate in candidates) {
    final facts = read(candidate);
    if (facts == null) continue;
    // A symlink here is one more thing that can be repointed, and following it
    // would only move the question elsewhere. Candidates are named exactly.
    if (!facts.isRegularFile) continue;
    if (facts.uid != 0) continue;
    if (facts.groupOrOtherWritable) continue;
    return candidate;
  }
  return null;
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

/// `%SystemRoot%`, sanity-checked, or the documented default.
///
/// Read from the environment because a Windows install is not obliged to be on
/// `C:`, but never taken on faith: anything that is not a rooted local path is
/// ignored rather than concatenated into a command line.
String windowsSystemRoot({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  for (final key in const ['SystemRoot', 'SYSTEMROOT', 'windir']) {
    final value = env[key];
    if (value != null && RegExp(r'^[A-Za-z]:\\').hasMatch(value)) {
      return value.replaceFirst(RegExp(r'\\+$'), '');
    }
  }
  return r'C:\Windows';
}

/// Windows PowerShell by absolute path, never by name.
String windowsPowerShellPath({Map<String, String>? environment}) =>
    '${windowsSystemRoot(environment: environment)}'
    r'\System32\WindowsPowerShell\v1.0\powershell.exe';

/// A tool that ships in System32, by absolute path.
String windowsSystem32Tool(String name, {Map<String, String>? environment}) =>
    '${windowsSystemRoot(environment: environment)}\\System32\\$name';

/// The environment a helper process is given — ours is not passed on.
///
/// `PATH` here is only what Windows itself needs; nothing is resolved through
/// it by us. Handing our own environment to a process that is part of an
/// elevation decision would put back the search path this file just took away.
Map<String, String> windowsCleanEnvironment({
  Map<String, String>? environment,
}) {
  final root = windowsSystemRoot(environment: environment);
  return <String, String>{
    'SystemRoot': root,
    'windir': root,
    'Path': '$root\\System32;$root;$root\\System32\\Wbem;'
        '$root\\System32\\WindowsPowerShell\\v1.0',
    'PATHEXT': '.COM;.EXE;.BAT;.CMD',
    'ComSpec': '$root\\System32\\cmd.exe',
  };
}

/// Reads owner + DACL from the HANDLE the path resolved to. Nothing but fact
/// collection lives here.
///
/// This used to shell out to PowerShell `Get-Acl`, and its own comment said
/// what that was: the part of the fix that could be written without a Windows
/// host to verify on. Reading by NAME left two holes — the window between
/// reading permissions and using the path, and a junction whose target's
/// permissions say nothing about who can repoint it (audit C-01).
///
/// Both are closed by `veil_path_security_facts`, which opens the path once
/// and answers from that one handle: `CreateFileW` with
/// `FILE_FLAG_OPEN_REPARSE_POINT` so a link is seen rather than followed,
/// `GetFinalPathNameByHandleW` so a link ABOVE the leaf becomes visible as a
/// path that does not match the one asked about, and `GetSecurityInfo` — the
/// handle-based call, not its named twin, which would look the name up again.
///
/// Verified on a Windows 11 ARM64 host, not reasoned about: a real junction
/// comes back refused, and a path THROUGH one comes back resolved to its
/// target, which is the fact the comparison above reads. What is still not
/// verified end to end is this Dart half on Windows — the FFI crate's
/// BoringSSL dependency does not build on that host, so what ran there was the
/// same Win32 code in a standalone harness.
class WindowsPathSecurityProbe implements PathSecurityProbe {
  const WindowsPathSecurityProbe();

  @override
  Future<String?> canonicalize(String path) async {
    // From the same handle the permissions come from, so "what this name
    // resolves to" and "whose permissions those are" cannot disagree.
    final facts = veilPathSecurityFacts(path);
    final finalPath = facts?['finalPath'];
    if (finalPath is String && finalPath.isNotEmpty) {
      return stripExtendedLengthPrefix(finalPath);
    }
    return null;
  }

  @override
  Future<List<PathSecurityFacts>> inspect(
    List<PrivilegedPathStep> steps,
  ) async {
    if (!veilPathSecurityFactsAvailable()) {
      // Not a fallback to the old path-based read: that read is the hole.
      return [
        for (final step in steps)
          PathSecurityFacts.undetermined(
            step.path,
            'this build cannot read permissions from a handle',
          ),
      ];
    }
    return [for (final step in steps) _factsFor(step.path)];
  }

  PathSecurityFacts _factsFor(String path) {
    final decoded = veilPathSecurityFacts(path);
    if (decoded == null) {
      return PathSecurityFacts.undetermined(
        path,
        'the permissions could not be read from a handle',
      );
    }
    // A junction anywhere in the chain is caught twice: once at its own step,
    // where the native side refuses to follow it, and once here, where the
    // final path of a step BELOW it no longer matches the name asked about.
    // Two nets because one of them is about the leaf and the other about
    // everything above it.
    final moved = pathResolutionMismatch(path, decoded['finalPath']);
    if (moved != null) return PathSecurityFacts.undetermined(path, moved);
    return windowsFactsFromAcl(path, decoded);
  }
}
