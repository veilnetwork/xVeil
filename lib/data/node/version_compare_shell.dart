/// The shell comparator both node scripts use to decide "is this newer".
///
/// One text, because there were two and they disagreed with the app.
///
/// `sort -V` was the first answer and it is wrong for the one shape that
/// matters here: it orders `0.8.1` BEFORE `0.8.1-rc1`, so a release candidate
/// reads as newer than the stable release of the same number. Two consequences,
/// and the second is the dangerous one — a node on stable would install an RC,
/// and a node that somebody put an RC on would REFUSE the stable release that
/// followed it, which is how a security update sits unapplied (report16 XV-11).
///
/// So the comparison is numeric, field by field, and states what it does with a
/// suffix rather than inheriting an opinion from a sort utility:
///
/// * a CANDIDATE tag carrying anything but digits and dots is refused outright.
///   These scripts install published releases; `v1.2.3-rc1` is not one, and
///   `releases/latest` does not offer pre-releases in the first place — this is
///   what makes that true here rather than assumed.
/// * an INSTALLED version carrying a suffix counts as older than its own base,
///   so `0.8.1-rc1` does not block `0.8.1`.
/// * equal is NOT newer, so a re-run installs nothing.
library;

/// `newer_than <candidate> <installed>` — true when the candidate should be
/// installed over what is there.
const String kNewerThanShell = r'''
newer_than() {
  local a="${1#v}" b="${2#v}"
  # A candidate that is not plainly N.N.N is not something to install.
  case "$a" in ''|*[!0-9.]*) return 1 ;; esac
  # A suffix on the installed side means a pre-release OF that number, which
  # the release itself supersedes.
  local b_pre=0
  case "$b" in *[!0-9.]*) b_pre=1; b="${b%%[!0-9.]*}"; b="${b%.}" ;; esac
  case "$b" in '') b=0 ;; esac
  local -a A B
  local i a_i b_i
  IFS=. read -r -a A <<<"$a"
  IFS=. read -r -a B <<<"$b"
  for i in 0 1 2; do
    # Compared by `[ -gt ]`, which reads a decimal string — including a
    # zero-padded one. NOT `$(( ))`: arithmetic expansion treats `08` as octal
    # and errors out, and that error would be an answer nobody asked for. The
    # padding is handled by not doing arithmetic at all.
    a_i=${A[i]:-0}
    b_i=${B[i]:-0}
    [ "$a_i" -gt "$b_i" ] && return 0
    [ "$a_i" -lt "$b_i" ] && return 1
  done
  # Same numbers: newer only if what is installed is a pre-release of them.
  [ "$b_pre" = 1 ]
}
''';
