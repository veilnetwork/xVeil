"""Shared ground for prepare.py and builder.py.

The two scripts answer different questions about the same five targets, and
the answers have to agree: what a target needs, whether this machine can host
it, and which existing script already knows how to do the work. Keeping that
in one place is the only way `prepare.py android` and `builder.py android`
cannot drift apart.

Where a POSIX shell script already exists, these delegate to it: the scripts
under scripts/ and native/ carry knowledge that was expensive to acquire —
deployment targets, staging paths, entitlements, signing workarounds. Windows
has no such scripts, so the equivalent commands are spelled out here instead.

Everything is stdlib. A bootstrapper that needs `pip install` first is not a
bootstrapper.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import urllib.request
from dataclasses import dataclass, field
from typing import Callable

TARGETS = ("android", "linux", "windows", "macos", "ios")

# Which host can build which target. Apple targets need Xcode, Windows needs
# MSVC, and a Linux bundle links against the host's GTK — only Android travels.
HOSTS = {
    "android": ("Darwin", "Linux", "Windows"),
    "linux": ("Linux",),
    "windows": ("Windows",),
    "macos": ("Darwin",),
    "ios": ("Darwin",),
}

HOST_DEFAULT = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IS_WINDOWS = platform.system() == "Windows"


class Abort(SystemExit):
    """A refusal with a reason the reader can act on."""

    def __init__(self, message: str) -> None:
        super().__init__(2)
        self.message = message


@dataclass
class Step:
    """One unit of work, with why it is here.

    Either a command (`argv`) or a Python callable (`call`) — installing a
    toolchain is sometimes a download and an unzip, which is a poor fit for a
    subprocess and a good fit for a function.

    `optional` marks a step whose absence costs a feature rather than the
    build. `skip_if` carries the reason a step is already satisfied, so a
    second run explains itself instead of going quiet.
    """

    title: str
    argv: list[str] = field(default_factory=list)
    call: Callable[[], None] | None = None
    optional: bool = False
    env: dict[str, str] = field(default_factory=dict)
    skip_if: str = ""


def host() -> str:
    return platform.system()


def default_target() -> str:
    system = host()
    if system not in HOST_DEFAULT:
        raise Abort(f"unsupported host {system!r}; pass a target explicitly")
    return HOST_DEFAULT[system]


def resolve_target(argument: str | None, *, dry_run: bool = False) -> str:
    target = (argument or default_target()).lower()
    if target not in TARGETS:
        raise Abort(f"unknown target {target!r}; pick one of {', '.join(TARGETS)}")
    if host() not in HOSTS[target]:
        message = (
            f"a {target} build needs a {' or '.join(HOSTS[target])} host, "
            f"this is {host()}"
        )
        # A dry run executes nothing, so printing another host's plan is
        # harmless and is the only way to review it from here.
        if not dry_run:
            raise Abort(message)
        print(f"note: {message} — showing the plan anyway (dry run)")
    return target


def have(tool: str) -> bool:
    return shutil.which(tool) is not None


def resolve(tool: str) -> str:
    """The path to run `tool` by, which on Windows is not `tool`.

    CreateProcess appends only `.exe`, so a bare `flutter` never finds
    flutter.bat and dies as `[WinError 2] The system cannot find the file
    specified` — while have() says the tool is present, because which() honours
    PATHEXT. The check and the call have to agree, or the plan passes its own
    prerequisites and then fails on the first step that uses one.

    `bash` needs more than a path. Windows ships C:\\Windows\\System32\\bash.exe
    — the WSL launcher — and System32 usually comes first. With no distro
    installed it prints "Windows Subsystem for Linux has no installed
    distributions" and exits 1, so a build script appears to fail for reasons
    of its own. Git for Windows carries the bash that is actually meant here,
    next to git.exe.
    """
    if os.name != "nt":
        return tool
    found = shutil.which(tool)
    if tool == "bash" and (found is None or "system32" in found.lower()):
        git = shutil.which("git")
        if git:
            git_bash = os.path.join(os.path.dirname(os.path.dirname(git)), "bin", "bash.exe")
            if os.path.exists(git_bash):
                return git_bash
    return found or tool


def sh(script_path: str, *args: str) -> list[str]:
    """A POSIX shell script from the repo, plus its arguments, as an argv.

    `script_path` is repo-relative and may contain separators; everything
    after it is passed to the script, NOT joined into the path. (Joining them
    produced `scripts/build-mobile.sh/android`, which fails as a mysterious
    "no such file".)

    Invoked through bash explicitly rather than relying on the executable bit,
    which does not survive every checkout.
    """
    return ["bash", os.path.join(ROOT, script_path), *args]


# Suffixes that decide whether a Rust artifact is current. Cargo relinks when a
# source is newer than what it produced, so these are the same files cargo
# already weighs.
SOURCE_SUFFIXES = (".rs", ".toml", ".lock")

# Directories that are SEPARATE cargo targets when they sit beside a
# Cargo.toml: nothing in them is compiled into the library, so a test-only edit
# must not condemn a current .so. A gate that cries wolf is a gate people learn
# to pass with a flag.
NON_LIBRARY_DIRS = ("tests", "benches", "examples", "fuzz")


def newer_source(artifact: str, roots: list[str]) -> str | None:
    """The first source under `roots` newer than `artifact`, or None.

    The one question worth asking of a native library before packaging it: was
    it built from the tree it is about to ship with? Cargo answers it by this
    exact comparison, so after a build that actually ran, nothing under `roots`
    can be newer than the artifact. Something that IS newer means the build did
    not run — the file on disk was made by an earlier one, possibly days ago,
    possibly against a different on-disk format.

    That is not hypothetical: between 2026-08-02 and 2026-08-05 every APK
    carried a hidden-volume library older than the Dart bindings calling it,
    because the only step that builds it was not on the path the build took.
    Every gate stayed green — none of them looks at a built artifact.

    `roots` may name files as well as directories. `target/` is skipped: it
    holds output rather than source, and walking it costs seconds.
    """
    if not os.path.isfile(artifact):
        return None
    stamp = os.path.getmtime(artifact)
    for root in roots:
        if os.path.isfile(root):
            if os.path.getmtime(root) > stamp:
                return root
            continue
        for directory, subdirs, files in os.walk(root):
            pruned = ["target", ".git"]
            if os.path.isfile(os.path.join(directory, "Cargo.toml")):
                pruned += list(NON_LIBRARY_DIRS)
            subdirs[:] = [d for d in subdirs if d not in pruned]
            for name in files:
                if not name.endswith(SOURCE_SUFFIXES):
                    continue
                path = os.path.join(directory, name)
                try:
                    if os.path.getmtime(path) > stamp:
                        return path
                except OSError:
                    # Raced away between listing and stat; it cannot be what
                    # the artifact was built from either way.
                    continue
    return None


def package_manager() -> tuple[str, list[str]] | None:
    """The system package manager and its non-interactive install prefix.

    Returns None when there is nothing to drive — a Linux without any of the
    four, or a Windows without winget. The caller then prints what to install
    rather than pretending it can.
    """
    if host() == "Darwin":
        return ("brew", ["brew", "install"]) if have("brew") else None
    if host() == "Windows":
        if have("winget"):
            return ("winget", ["winget", "install", "--accept-package-agreements",
                               "--accept-source-agreements", "-e", "--id"])
        return ("choco", ["choco", "install", "-y"]) if have("choco") else None
    for name, argv in (
        ("apt-get", ["sudo", "apt-get", "install", "-y"]),
        ("dnf", ["sudo", "dnf", "install", "-y"]),
        ("pacman", ["sudo", "pacman", "-S", "--noconfirm"]),
        ("zypper", ["sudo", "zypper", "install", "-y"]),
    ):
        if have(name):
            return (name, argv)
    return None


def download(url: str, destination: str) -> None:
    """Fetch a file, reporting progress, and only then give it its name.

    The partial file gets a different name until it is complete, so an
    interrupted download can never be mistaken for a finished one — the same
    reason the speech-model download does it.
    """
    partial = destination + ".part"
    os.makedirs(os.path.dirname(destination) or ".", exist_ok=True)
    print(f"    fetching {url}")

    def report(block: int, size: int, total: int) -> None:
        if total > 0 and block % 200 == 0:
            print(f"      {min(block * size * 100 // total, 100)}%", end="\r")

    urllib.request.urlretrieve(url, partial, reporthook=report)
    os.replace(partial, destination)
    print(f"    saved {destination}")


def run(steps: list[Step], *, dry_run: bool) -> None:
    """Execute the plan, or print it.

    --dry-run exists because no single machine can host all five targets:
    printing the plan is the only way to check the tooling is right for a
    target this host cannot build.
    """
    width = len(str(len(steps)))
    for index, step in enumerate(steps, start=1):
        prefix = f"[{index:>{width}}/{len(steps)}]"
        if step.skip_if:
            print(f"{prefix} SKIP {step.title} — {step.skip_if}")
            continue
        print(f"{prefix} {step.title}")
        if step.argv:
            print(f"{' ' * (len(prefix) + 1)}$ {' '.join(step.argv)}")
        if dry_run:
            continue
        try:
            if step.call is not None:
                step.call()
                continue
            env = {**os.environ, **step.env}
            argv = [resolve(step.argv[0]), *step.argv[1:]]
            result = subprocess.run(argv, cwd=ROOT, env=env, check=False)
            if result.returncode == 0:
                continue
            raise RuntimeError(f"rc={result.returncode}")
        except Exception as error:  # noqa: BLE001 — the message is the point
            if step.optional:
                print(
                    f"{prefix} optional step failed ({error}) — continuing without it",
                    file=sys.stderr,
                )
                continue
            raise Abort(f"{step.title} failed: {error}") from None


def main(build_plan, description: str) -> None:
    """Argument handling shared by both entry points."""
    args = sys.argv[1:]
    dry_run = False
    release = None
    positional: list[str] = []
    for arg in args:
        if arg in ("-h", "--help"):
            print(
                f"{description}\n\n"
                f"usage: {os.path.basename(sys.argv[0])} [target] "
                f"[--debug|--release] [--dry-run]\n\n"
                f"  target     defaults to this machine's own system\n"
                f"             one of: {', '.join(TARGETS)}\n"
                f"  --dry-run  print the plan and execute nothing\n"
            )
            return
        if arg == "--dry-run":
            dry_run = True
        elif arg == "--release":
            release = True
        elif arg == "--debug":
            release = False
        elif arg.startswith("-"):
            raise Abort(f"unknown option {arg!r}")
        else:
            positional.append(arg)
    if len(positional) > 1:
        raise Abort(f"expected at most one target, got: {' '.join(positional)}")

    target = resolve_target(
        positional[0] if positional else None, dry_run=dry_run
    )
    print(f"target: {target} (host {host()})")
    steps = build_plan(target, release=True if release is None else release)
    run(steps, dry_run=dry_run)
    print("dry run — nothing was executed" if dry_run else "done")


def guard(entry) -> None:
    """Turn an Abort into a message rather than a traceback."""
    try:
        entry()
    except Abort as abort:
        print(f"error: {abort.message}", file=sys.stderr)
        raise SystemExit(2) from None
