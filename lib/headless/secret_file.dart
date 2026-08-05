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

/// Ceiling on a SHARED deployment secret read from a file.
///
/// The obfs4 PSK is one base64 line — 44 characters for a 32-byte key. 4 KiB is
/// far past any legitimate value and far below anything worth worrying about.
const int kSharedSecretFileMaxBytes = 4096;

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
  // One byte past the ceiling, so "exactly at the limit" and "over it" are
  // distinguishable without reading any more than that.
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

/// Why this platform cannot prove a secret file is private, or null when it
/// can.
///
/// POSIX can: the permission bits say exactly who may open it, and
/// [FileStat.mode] carries them.
///
/// Windows cannot — not from Dart. Access there is an ACL, and nothing in
/// `dart:io` reads one: [FileStat.mode] is synthesised from the read-only
/// attribute and has no relation to who may open the file, and [FileStat]
/// carries no owner on any platform. So a `--password-file` on Windows used to
/// be accepted with NO check of any kind: not the owner, not the ACL, not even
/// the useless mode. A password sitting in a world-readable directory — the
/// default for anything under `C:\ProgramData` — passed silently (audit X-10).
///
/// This is a statement about what can be verified, not about what is likely.
/// The remedy is not a better check in Dart; it is to type the secret in, or to
/// take responsibility for the file explicitly.
String? unverifiableSecretFileReason({required bool isWindows}) => isWindows
    ? 'Windows access control is an ACL, and Dart exposes neither the ACL nor '
          'the owner — this process cannot tell whether another account can '
          'read the file'
    : null;

/// Read a secret from [path], refusing one this process cannot show is private.
///
/// This used to be a bare `readAsString` (audit XV-16). A container password, a
/// recovery phrase or an API token sitting at mode 0644 — the default under
/// most umasks — is readable by every account on the box, and a headless
/// deployment is exactly where nobody is watching. Worse, the path could be a
/// SYMLINK: point `--password-file` at one and the daemon reads wherever it
/// leads, which turns a config knob into a file-disclosure primitive for anyone
/// who can write the config.
///
/// Checked, not assumed, and fail-closed. What is checked, exactly:
///
///  * it is not a symlink, and it is a regular file;
///  * on POSIX, no permission bit is set beyond the owner's;
///  * on Windows, NOTHING can be checked, so the read is refused unless the
///    operator asserts otherwise ([acceptUnchecked]);
///  * the file did not change between the check and the read.
///
/// Ownership is NOT checked on any platform, because [FileStat] carries no uid.
/// A file owned by another account but at mode 0600 passes on POSIX; the mode
/// check is what stands between that and a disclosure.
///
/// [isWindows] and [warn] are injected so the refusal is testable from any
/// host — this is the branch that had no coverage at all.
Future<String> readSecretFile(
  String path,
  String label, {
  bool acceptUnchecked = false,
  bool? isWindows,
  void Function(String warning)? warn,
}) async {
  final windows = isWindows ?? Platform.isWindows;
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
  final unverifiable = unverifiableSecretFileReason(isWindows: windows);
  if (unverifiable != null) {
    // Loud either way: refuse, or say plainly that the guarantee is the
    // operator's and not the program's. Silence was the bug.
    if (!acceptUnchecked) {
      throw StateError(
        '$label file $path cannot be verified: $unverifiable. Run xveil from a '
        'terminal and type the secret at the prompt instead (leave the file '
        'option off). For an unattended service, restrict the file yourself '
        '(icacls <file> /inheritance:r /grant:r "%USERNAME%":R) and re-run '
        'with $kAcceptUncheckedSecretFilesFlag, or set '
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
  if (!windows) {
    final mode = File(path).statSync().mode;
    if (mode & 0x3F != 0) {
      throw StateError(
        '$label file $path is mode ${(mode & 0x1FF).toRadixString(8)} — '
        'readable beyond its owner. Run: chmod 600 $path',
      );
    }
  }
  // The checks above are path-based, and so is the read: separate syscalls
  // against a name, not one descriptor. Dart exposes neither
  // `openat`/`O_NOFOLLOW` nor `fstat`, so the file checked cannot be PROVEN to
  // be the file read without dropping to FFI on three platforms (audit XV-16,
  // X-10). What is reachable is detection. Capture the state, read, and
  // compare: a swap between the check and the read changes the type, the mode,
  // the size or the modification time, and any of those differing means we no
  // longer know what we just read. Refuse rather than return it — a secret that
  // might be someone else's planted file is worse than no secret.
  final before = await File(path).stat();
  final value = (await File(path).readAsString()).trim();
  final after = await File(path).stat();
  if (before.type != after.type ||
      before.mode != after.mode ||
      before.size != after.size ||
      before.modified != after.modified) {
    throw StateError(
      '$label file $path changed while it was being read — refusing to use '
      'its contents.',
    );
  }
  if (value.isEmpty) throw StateError('$label file is empty');
  return value;
}
