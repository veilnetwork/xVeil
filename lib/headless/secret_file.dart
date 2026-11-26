/// Reading a store password, a recovery phrase or an API token off disk.
///
/// The terminal prompt is the primary way in. A file is the unattended
/// fallback, and it is only as safe as the platform's ability to say who else
/// can read it — which is not the same on every platform, so this says out loud
/// where it can and cannot tell.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/posix_file_facts.dart';
import '../data/storage/managed_fs_platform.dart';
import '../data/storage/managed_fs_windows.dart' as win;

/// Ceiling on a SHARED deployment secret read from a file.
///
/// The obfs4 PSK is one base64 line — 44 characters for a 32-byte key. 4 KiB is
/// far past any legitimate value and far below anything worth worrying about.
const int kSharedSecretFileMaxBytes = 4096;

/// Ceiling on a PRIVATE secret read from a file — a container password, a
/// recovery phrase, an API token.
///
/// The longest of the three is a 24-word phrase, some two hundred bytes. The
/// same 4 KiB is far past any of them and far below anything worth worrying
/// about.
const int kSecretFileMaxBytes = 4096;

/// Read at most [maxBytes] of [path], bounded at the STREAM.
///
/// The bound is not a `length()` taken beforehand, and that is the whole
/// point: a file can grow between the measurement and the read, so a
/// pre-measured limit bounds a number rather than an allocation. Reading one
/// byte past the ceiling also keeps "exactly at the limit" and "over it"
/// distinguishable without reading any more than that.
///
/// Returns bytes rather than a string so each caller keeps its own decode:
/// the shared path tolerates malformed UTF-8, the private one must not.
Future<Uint8List> _readBounded(String path, String label, int maxBytes) async {
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in File(path).openRead(0, maxBytes + 1)) {
    buffer.add(chunk);
  }
  final bytes = buffer.takeBytes();
  if (bytes.length > maxBytes) {
    throw StateError(
      '$label file $path is larger than $maxBytes bytes — refusing to read it.',
    );
  }
  return bytes;
}

/// Read a SHARED deployment secret — one every participant already holds — from
/// [path], with a type check and a ceiling and nothing else.
///
/// Deliberately NOT [readSecretFile]. That one refuses anything readable beyond
/// its owner, which is the correct rule for a container password and the wrong
/// one here: the obfs4 PSK ships inside every published APK and every bundle, so
/// demanding 0600 of the operator's copy would break deployments in order to
/// protect a value anyone who has the app already has.
///
/// The two things that ARE checked have nothing to do with secrecy, which is
/// why they belong on this path as much as on the other one:
///
///  * it resolves to a REGULAR FILE. `readAsString` on a named pipe blocks
///    until somebody writes to and closes the other end. This read happens
///    AFTER the deniable container is unlocked, so a fifo at that path does not
///    fail the start — it wedges it, with the store open and the password in
///    memory, and nothing on the console to say why (audit XV-16);
///  * it is at most [maxBytes]. `readAsString` reads whatever is there, so a
///    large file becomes the daemon's heap. The read is bounded at the STREAM,
///    not by a `length()` taken beforehand, so a file that grows between the
///    two calls cannot get past it either.
///
/// Symlinks are followed on purpose: a deployment key reached through a link
/// (`/etc/xveil/psk -> /run/secrets/...`) is ordinary, and there is nothing here
/// worth refusing it over.
Future<String> readSharedSecretFile(
  String path,
  String label, {
  int maxBytes = kSharedSecretFileMaxBytes,
}) async {
  final type = FileSystemEntity.typeSync(path);
  if (type != FileSystemEntityType.file) {
    throw StateError(
      '$label file $path is not a regular file ($type) — refusing to read it.',
    );
  }
  final bytes = await _readBounded(path, label, maxBytes);
  final value = utf8.decode(bytes, allowMalformed: true).trim();
  if (value.isEmpty) throw StateError('$label file is empty');
  return value;
}

/// The flag that lets an operator use a secret file this process cannot vouch
/// for. Named as a statement rather than a switch: the operator is asserting
/// something the program was unable to check.
const String kAcceptUncheckedSecretFilesFlag =
    '--accept-unchecked-secret-files';

/// Same assertion for a service manager, which has no command line to edit.
const String kAcceptUncheckedSecretFilesEnv =
    'XVEIL_ACCEPT_UNCHECKED_SECRET_FILES';

/// Explicit acceptance of a verified read-only grant on an owned secret file.
const String kAcceptReadableSecretFilesFlag = '--accept-readable-secret-files';
const String kAcceptReadableSecretFilesEnv =
    'XVEIL_ACCEPT_READABLE_SECRET_FILES';

/// Explanation for the explicit Windows fallback when the ACL probe fails.
String? unverifiableSecretFileReason({required bool isWindows}) => isWindows
    ? 'the Windows ACL probe is unavailable, so ownership and access by '
          'other accounts could not be established'
    : null;

/// Read a bounded credential after checking file type, ownership and access.
/// Windows uses the native ACL probe when available. Known read-only grants
/// require explicit consent. The caller may separately accept an unavailable
/// Windows probe, and receives a warning before the unverified read.
///
/// [isWindows] and [warn] allow tests to exercise the unavailable-probe path.
Future<String> readSecretFile(
  String path,
  String label, {
  bool acceptUnchecked = false,
  bool acceptReadable = false,
  bool? isWindows,
  void Function(String warning)? warn,
}) async {
  final windows = isWindows ?? Platform.isWindows;
  // THE one call, when the host can answer it. `isWindows: true` deliberately
  // forgoes it even on a POSIX machine: that injection exists to exercise the
  // Windows branch, and a branch that quietly used libc would not be it.
  final before = windows ? null : posixLstat(path);

  if (before != null) {
    if (before.isSymlink) {
      throw StateError(
        '$label file $path is a symlink — refusing to follow it. Point the '
        'option at the real file.',
      );
    }
    if (!before.isRegularFile) {
      throw StateError('$label file $path is not a regular file');
    }
  } else {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw StateError(
        '$label file $path is a symlink — refusing to follow it. Point the '
        'option at the real file.',
      );
    }
    if (type != FileSystemEntityType.file) {
      throw StateError('$label file $path is not a regular file');
    }
  }
  ManagedPathWitness? acl;
  const fs = ManagedFsPlatform();
  final windowsPath = File(path).absolute.path;
  if (windows && Platform.isWindows && isWindows == null) {
    try {
      acl = win.inspect(windowsPath, includeApprovedAcl: true);
    } on ManagedFsFailure catch (error) {
      if (error.unsafeReason != null) {
        throw StateError(
          '$label file $path could not be verified (${error.unsafeReason!.name}). '
          'Check the file and folder permissions or type the secret at the prompt.',
        );
      }
      // Compatibility for systems where the SDK probe cannot read an ACL.
    }
  }
  final unverifiable = acl == null
      ? unverifiableSecretFileReason(isWindows: windows)
      : null;
  if (acl != null) {
    _checkSecretGrant(
      path,
      label,
      acl,
      acceptReadable: acceptReadable,
      warn: warn,
    );
  }
  if (unverifiable != null) {
    // Loud either way: refuse, or say plainly that the guarantee is the
    // operator's and not the program's. Silence was the bug.
    if (!acceptUnchecked) {
      throw StateError(
        '$label file $path cannot be verified: $unverifiable. Run xveil from a '
        'terminal and type the secret at the prompt instead (leave the file '
        'option off). For an unattended service, check the file and folder '
        'security properties and re-run with $kAcceptUncheckedSecretFilesFlag, or set '
        '$kAcceptUncheckedSecretFilesEnv=1 — that flag asserts the file is '
        'private, it does not make it so.',
      );
    }
    warn?.call(
      'xveil: WARNING: $label file $path is being read UNCHECKED '
      '($unverifiable). You asserted it is private; nothing here verified it.',
    );
  } else if (acceptUnchecked) {
    // The flag exists for the platform that cannot check. Where the check
    // works, it is not up for negotiation: silently honouring the flag here
    // would turn one platform's escape hatch into a way to disable the mode
    // check everywhere.
    warn?.call(
      'xveil: note: $kAcceptUncheckedSecretFilesFlag has no effect on this '
      'platform — the permission check still applies to $label file $path.',
    );
  }
  if (before != null) {
    final euid = posixEuid();
    if (euid != null && before.uid != euid) {
      throw StateError(
        '$label file $path is owned by uid ${before.uid}, not by this process '
        '(uid $euid). Use a file you own or type the secret at the prompt.',
      );
    }
    if (Platform.isMacOS || Platform.isLinux) {
      try {
        acl = fs.inspectAcl(path);
      } on ManagedFsFailure catch (error) {
        final details = _secretAclDetails(error.aclWarnings.firstOrNull);
        throw StateError('$label file $path cannot be safely opened.$details');
      }
      if (acl.identity != '${before.deviceId}:${before.inode}:${before.uid}' ||
          !acl.ownedByCurrentUser ||
          acl.directory) {
        throw StateError(
          '$label file $path changed during the permission check.',
        );
      }
      _checkSecretGrant(
        path,
        label,
        acl,
        acceptReadable: acceptReadable,
        warn: warn,
        mode: before.mode & 0x1ff,
      );
    } else if (before.mode & 0x3F != 0) {
      throw StateError(
        '$label file $path is mode ${(before.mode & 0x1FF).toRadixString(8)} — '
        'readable beyond its owner. Run: chmod 600 $path',
      );
    }
  } else if (!windows) {
    final mode = File(path).statSync().mode;
    if (mode & 0x3F != 0) {
      throw StateError(
        '$label file $path is mode ${(mode & 0x1FF).toRadixString(8)} — '
        'readable beyond its owner. Run: chmod 600 $path',
      );
    }
  }

  // The checks are against a NAME and so is the read: separate syscalls, not
  // one descriptor. Dart exposes neither `openat`/`O_NOFOLLOW` nor `fstat`, so
  // the file checked cannot be PROVEN to be the file read without dropping to
  // FFI on three platforms (audit XV-16, X-10). What is reachable is detection:
  // read, look again, and refuse if it is not the same object. A secret that
  // might be somebody else's planted file is worse than no secret.
  if (before != null) {
    // Bounded, and bounded at the stream. A correctly-owned 0600 file is not
    // necessarily a SMALL one, and `readAsString` read whatever was there —
    // so a secret file the operator points at by mistake became the daemon's
    // heap before any of the checks below got to run (report9 X-04).
    final value = utf8
        .decode(await _readBounded(path, label, kSecretFileMaxBytes))
        .trim();
    final after = posixLstat(path);
    if (after == null ||
        !before.sameObjectAs(after) ||
        before.mode != after.mode ||
        before.uid != after.uid) {
      throw StateError(
        '$label file $path changed while it was being read — refusing to use '
        'its contents.',
      );
    }
    if (acl != null) {
      try {
        final verified = fs.inspectAcl(path);
        if (verified.identity != acl.identity ||
            verified.ownerOnly != acl.ownerOnly ||
            verified.aclWarning?.fingerprint != acl.aclWarning?.fingerprint) {
          throw const ManagedFsFailure(ManagedFsFailureKind.changed);
        }
      } on ManagedFsFailure {
        throw StateError(
          '$label file $path changed permissions while being read.',
        );
      }
    }
    if (value.isEmpty) throw StateError('$label file is empty');
    return value;
  }

  if (acl != null) {
    final value = utf8
        .decode(await _readBounded(path, label, kSecretFileMaxBytes))
        .trim();
    final after = win.inspect(windowsPath, includeApprovedAcl: true);
    if (!after.sameObject(acl) ||
        after.ownerOnly != acl.ownerOnly ||
        after.aclWarning?.fingerprint != acl.aclWarning?.fingerprint) {
      throw StateError(
        '$label file $path changed permissions while being read.',
      );
    }
    if (value.isEmpty) throw StateError('$label file is empty');
    return value;
  }

  // Windows, or a POSIX ABI with no layout in the table: size and modification
  // time are all Dart offers. Weaker — both are writable by anyone who can
  // write the file — but it is what these platforms had, and nothing here makes
  // it worse.
  final beforeStat = await File(path).stat();
  final value = utf8
      .decode(await _readBounded(path, label, kSecretFileMaxBytes))
      .trim();
  final afterStat = await File(path).stat();
  if (beforeStat.type != afterStat.type ||
      beforeStat.mode != afterStat.mode ||
      beforeStat.size != afterStat.size ||
      beforeStat.modified != afterStat.modified) {
    throw StateError(
      '$label file $path changed while it was being read — refusing to use '
      'its contents.',
    );
  }
  if (value.isEmpty) throw StateError('$label file is empty');
  return value;
}

void _checkSecretGrant(
  String path,
  String label,
  ManagedPathWitness acl, {
  required bool acceptReadable,
  void Function(String)? warn,
  int? mode,
}) {
  final details = _secretAclDetails(acl.aclWarning);
  if (acl.directory || !acl.ownedByCurrentUser) {
    throw StateError(
      '$label file $path must be owned and writable only by your account '
      'or a trusted system account.$details',
    );
  }
  if (!acl.safeAncestor || !acl.otherUsersHaveReadOnlyAccess) {
    throw StateError(
      '$label file $path can be modified by another account.$details',
    );
  }
  if (acl.ownerOnly) return;
  final description =
      '$label file $path ${mode == null ? '' : 'is mode ${mode.toRadixString(8)} and '}'
      'may be readable beyond its owner.$details';
  if (!acceptReadable || acl.aclWarning == null) {
    throw StateError(
      '$description Check the file permissions${mode == null ? '' : ' (chmod 600 for mode bits)'}, '
      'type the secret at the prompt, or pass '
      '$kAcceptReadableSecretFilesFlag to accept verified read-only grants.',
    );
  }
  (warn ?? stderr.writeln)(
    'xveil: WARNING: $description The operator accepted this access.',
  );
}

String _secretAclDetails(ManagedStorageAclWarning? warning) {
  if (warning == null) return '';
  return [
    if (warning.grantsArePotential)
      'ACL allow entries (deny rules can limit access):',
    for (final grant in warning.grants)
      '${grant.account.isEmpty ? 'other accounts' : grant.account}: '
          '${grant.rights.map((right) => right.name).join(', ')}',
    if (warning.extendedAcl case final acl?) acl.trim(),
  ].map((detail) => '\n$detail').join();
}
