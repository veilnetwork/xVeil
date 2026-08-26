/// Refuse a binary this machine cannot execute, before anything is installed.
///
/// One text, used by BOTH scripts that put a release binary on a server —
/// deployment and update. They arrive at the same mistake by different roads:
/// deployment asks the operator to pick an architecture for a machine they
/// often have not looked at, and the update path picked one for the whole
/// fleet. Neither is caught by anything else on the way: a digest proves the
/// bytes are the ones the release published and says nothing about what they
/// were built for, so the wrong build is a perfectly genuine file that
/// installs as root and then cannot start.
///
/// Deployment is the worse of the two, because there is no previous binary to
/// go back to.
///
/// ELF carries the answer in one byte at offset 18 — 62 (0x3E) is x86-64, 183
/// (0xB7) is AArch64, little-endian on both. Reading the header beats running
/// the file: it needs no working loader and it answers before the install.
///
/// The host is asked twice over. `uname -m` names the common cases, and a name
/// this script does not know falls back to the ELF machine of the running
/// shell — ground truth that needs no table. Only a host where BOTH fail lets
/// a binary through unchecked, and that is a machine veil publishes no build
/// for anyway.
const String kArchGuardShell = '''
case "\$(uname -m)" in
  x86_64|amd64)  want_machine=62 ;;
  aarch64|arm64) want_machine=183 ;;
  *)
    # A name nobody taught this script about is not a reason to wave a binary
    # through. Ask the host directly instead: read the ELF machine of the shell
    # that is running THIS script. Whatever it is, it demonstrably runs here,
    # and it needs no table of names to be right.
    want_machine="\$(od -An -t u1 -j 18 -N 1 /proc/self/exe 2>/dev/null | tr -d ' ' || true)"
    ;;
esac
check_machine() {
  # An architecture nobody taught this script about is not a reason to block an
  # install it may well be able to run.
  [ -n "\$want_machine" ] || return 0
  got="\$(sudo od -An -t u1 -j 18 -N 1 "\$1" | tr -d ' ')"
  [ "\$got" = "\$want_machine" ] || {
    echo "refusing \$1: built for another architecture (ELF machine \$got, this host is \$(uname -m))" >&2
    exit 1
  }
}
''';
