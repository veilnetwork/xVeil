#!/usr/bin/env python3
"""Bring a clean machine to the point where `builder.py` can run.

    ./prepare.py [target] [--dry-run]

`target` defaults to this machine's own system and may be android, linux,
windows, macos or ios. Runs on Windows, Linux and macOS.

What it will do for you: install Rust, add the cross-compilation targets,
install cargo-ndk, fetch the Android command-line tools and the NDK, pull the
git submodules the native libraries live in, fetch Dart packages, and install
CocoaPods where Apple needs them.

What it will NOT do quietly: install Xcode, Visual Studio, or anything else
that wants a license agreement, a reboot, or tens of gigabytes. Those are
detected and reported with the exact command, because a bootstrapper that
starts a 40-minute unattended download because you typed a word is worse than
one that asks.

Everything is idempotent: a second run reports what is already satisfied
rather than doing it again.
"""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts"))

from xveil_build_support import (  # noqa: E402
    ROOT,
    Abort,
    Step,
    download,
    guard,
    have,
    host,
    main,
    package_manager,
    sh,
)

# Rust targets per platform, from BUILDING.md's per-platform sections.
RUST_TARGETS = {
    "android": [
        "aarch64-linux-android",
        "armv7-linux-androideabi",
        "x86_64-linux-android",
    ],
    "ios": ["aarch64-apple-ios", "aarch64-apple-ios-sim", "x86_64-apple-ios"],
    "macos": [],
    "linux": [],
    "windows": [],
}

# System packages a Linux build needs beyond a Flutter install: the GTK
# headers the desktop embedder links against, plus the C/C++ toolchain the
# Rust crates' build scripts shell out to.
LINUX_PACKAGES = {
    "apt-get": [
        "clang", "cmake", "ninja-build", "pkg-config",
        "libgtk-3-dev", "liblzma-dev", "libstdc++-12-dev", "unzip", "curl", "git",
    ],
    "dnf": [
        "clang", "cmake", "ninja-build", "pkgconf-pkg-config",
        "gtk3-devel", "xz-devel", "unzip", "curl", "git",
    ],
    "pacman": ["clang", "cmake", "ninja", "pkgconf", "gtk3", "xz", "unzip", "curl", "git"],
    "zypper": [
        "clang", "cmake", "ninja", "pkg-config",
        "gtk3-devel", "xz-devel", "unzip", "curl", "git",
    ],
}

# sdkmanager and gradle are both JVM programs: without a JDK the Android steps
# fail with a Java error rather than anything about Android, which is a poor
# first experience on a clean machine. 17 is what the Android Gradle Plugin
# expects.
JDK_PACKAGE = {
    "apt-get": "openjdk-17-jdk",
    "dnf": "java-17-openjdk-devel",
    "pacman": "jdk17-openjdk",
    "zypper": "java-17-openjdk-devel",
    "brew": "openjdk@17",
    "winget": "Microsoft.OpenJDK.17",
    "choco": "openjdk17",
}

ANDROID_SDK_ROOT = os.environ.get(
    "ANDROID_SDK_ROOT",
    os.environ.get(
        "ANDROID_HOME",
        os.path.expanduser(
            "~/Library/Android/sdk" if host() == "Darwin" else "~/Android/Sdk"
        ),
    ),
)

# Pinned so a prepared machine is reproducible rather than "whatever was
# newest that afternoon". Bump deliberately.
CMDLINE_TOOLS = {
    "Darwin": "https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip",
    "Linux": "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip",
    "Windows": "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip",
}
NDK_VERSION = "27.0.12077973"


def _sdkmanager() -> str:
    exe = "sdkmanager.bat" if host() == "Windows" else "sdkmanager"
    return os.path.join(ANDROID_SDK_ROOT, "cmdline-tools", "latest", "bin", exe)


def _install_rustup() -> None:
    """rustup, the way rustup itself documents.

    Not through a package manager: distro Rust is routinely too old for the
    crates here, and rustup is what manages the cross targets anyway.
    """
    if host() == "Windows":
        installer = os.path.join(ROOT, "build", "rustup-init.exe")
        download("https://win.rustup.rs/x86_64", installer)
        subprocess.run([installer, "-y", "--no-modify-path"], check=True)
    else:
        installer = os.path.join(ROOT, "build", "rustup-init.sh")
        download("https://sh.rustup.rs", installer)
        os.chmod(installer, os.stat(installer).st_mode | stat.S_IEXEC)
        subprocess.run(["sh", installer, "-y", "--no-modify-path"], check=True)
    print("    rustup installed — add ~/.cargo/bin to PATH for this shell:")
    print('      export PATH="$HOME/.cargo/bin:$PATH"'
          if host() != "Windows"
          else '      set PATH=%USERPROFILE%\\.cargo\\bin;%PATH%')


def _install_android_cmdline_tools() -> None:
    """The command-line tools, which is all the SDK needs to bootstrap itself.

    Android Studio is not required to build; sdkmanager fetches the platform,
    build-tools and NDK. Layout matters: the tools insist on living in
    cmdline-tools/latest/, and unzipping elsewhere produces an sdkmanager that
    refuses to run.
    """
    url = CMDLINE_TOOLS[host()]
    archive = os.path.join(ROOT, "build", "android-cmdline-tools.zip")
    download(url, archive)
    staging = os.path.join(ROOT, "build", "android-cmdline-tools")
    with zipfile.ZipFile(archive) as zf:
        zf.extractall(staging)
    target = os.path.join(ANDROID_SDK_ROOT, "cmdline-tools", "latest")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if os.path.isdir(target):
        raise Abort(f"{target} already exists — remove it or set ANDROID_SDK_ROOT")
    os.replace(os.path.join(staging, "cmdline-tools"), target)
    for name in os.listdir(os.path.join(target, "bin")):
        path = os.path.join(target, "bin", name)
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
    print(f"    Android SDK at {ANDROID_SDK_ROOT}")


def _flutter_missing_note() -> None:
    raise Abort(
        "flutter is not on PATH.\n"
        "  macOS/Linux: git clone -b stable https://github.com/flutter/flutter.git "
        "~/flutter && export PATH=\"$HOME/flutter/bin:$PATH\"\n"
        "  Windows:     winget install -e --id Google.Flutter\n"
        "Then run prepare.py again. It is not installed automatically because "
        "the SDK is several gigabytes and its location is a decision, not a "
        "detail."
    )


def plan(target: str, *, release: bool) -> list[Step]:
    del release  # preparation is the same either way
    steps: list[Step] = []
    manager = package_manager()

    if not have("flutter"):
        steps.append(Step("flutter SDK", call=_flutter_missing_note))
    else:
        steps.append(
            Step(
                "flutter SDK",
                skip_if=f"already on PATH ({os.path.dirname(str(_which('flutter')))})",
            )
        )

    # System packages first: the Rust crates' build scripts need a C compiler,
    # and finding that out after a long download is a poor trade.
    if host() == "Linux":
        if manager and manager[0] in LINUX_PACKAGES:
            steps.append(
                Step(
                    f"system packages via {manager[0]}",
                    argv=manager[1] + LINUX_PACKAGES[manager[0]],
                )
            )
        else:
            steps.append(
                Step(
                    "system packages",
                    call=lambda: print(
                        "    no supported package manager found — install by hand: "
                        + ", ".join(LINUX_PACKAGES["apt-get"])
                    ),
                    optional=True,
                )
            )
    elif host() == "Darwin":
        steps.append(
            Step(
                "Xcode command line tools",
                argv=["xcode-select", "--install"],
                optional=True,
                skip_if="already installed" if _xcode_clt_present() else "",
            )
        )
    elif host() == "Windows" and target == "windows":
        steps.append(
            Step(
                "Visual Studio with the C++ desktop workload",
                call=lambda: print(
                    "    required for a Windows build; install once:\n"
                    "      winget install -e --id Microsoft.VisualStudio.2022.BuildTools"
                ),
                optional=True,
                skip_if="cl.exe on PATH" if have("cl") else "",
            )
        )

    steps.append(
        Step(
            "Rust toolchain",
            call=_install_rustup,
            skip_if="rustup already installed" if have("rustup") else "",
        )
    )

    for triple in RUST_TARGETS[target]:
        steps.append(Step(f"rust target {triple}", argv=["rustup", "target", "add", triple]))

    if target == "android":
        if not have("java"):
            if manager and manager[0] in JDK_PACKAGE:
                steps.append(
                    Step(
                        f"JDK 17 via {manager[0]}",
                        argv=manager[1] + [JDK_PACKAGE[manager[0]]],
                    )
                )
            else:
                steps.append(
                    Step(
                        "JDK 17",
                        call=lambda: print(
                            "    sdkmanager and gradle need a JDK — install one "
                            "(17) and re-run"
                        ),
                    )
                )
        else:
            steps.append(Step("JDK", skip_if="java already on PATH"))
        steps.append(
            Step(
                "cargo-ndk",
                argv=["cargo", "install", "cargo-ndk", "--locked"],
                skip_if="already installed" if have("cargo-ndk") else "",
            )
        )
        steps.append(
            Step(
                "Android command-line tools",
                call=_install_android_cmdline_tools,
                skip_if=(
                    f"sdkmanager already at {ANDROID_SDK_ROOT}"
                    if os.path.isfile(_sdkmanager())
                    else ""
                ),
            )
        )
        steps.append(
            Step(
                "Android platform, build-tools and NDK",
                argv=[
                    _sdkmanager(),
                    f"--sdk_root={ANDROID_SDK_ROOT}",
                    "platform-tools",
                    "platforms;android-35",
                    "build-tools;35.0.0",
                    f"ndk;{NDK_VERSION}",
                ],
                env={"ANDROID_SDK_ROOT": ANDROID_SDK_ROOT},
            )
        )
        steps.append(
            Step(
                "point ANDROID_NDK_HOME at the NDK",
                call=lambda: print(
                    "    add to your shell profile:\n"
                    f"      export ANDROID_NDK_HOME="
                    f"{os.path.join(ANDROID_SDK_ROOT, 'ndk', NDK_VERSION)}"
                ),
            )
        )

    if target in ("macos", "ios"):
        steps.append(
            Step(
                "CocoaPods",
                argv=["gem", "install", "cocoapods", "--user-install"],
                skip_if="already installed" if have("pod") else "",
            )
        )

    # The native libraries live in submodules; without them the Rust build has
    # nothing to compile and the failure is a confusing "no such directory".
    steps.append(
        Step(
            "git submodules (veil, hidden-volume)",
            argv=["git", "submodule", "update", "--init", "--recursive"],
        )
    )
    steps.append(Step("Dart packages", argv=["flutter", "pub", "get"]))

    if target in ("macos", "ios") and have("pod"):
        pod_dir = "macos" if target == "macos" else "ios"
        steps.append(
            Step(
                f"CocoaPods dependencies ({pod_dir})",
                argv=["pod", "install", "--project-directory=" + pod_dir],
                optional=True,
            )
        )

    steps.append(
        Step(
            "flutter doctor (report only)",
            argv=["flutter", "doctor", "-v"],
            optional=True,
        )
    )
    return steps


def _which(tool: str) -> str | None:
    import shutil

    return shutil.which(tool)


def _xcode_clt_present() -> bool:
    try:
        subprocess.run(
            ["xcode-select", "-p"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except Exception:  # noqa: BLE001
        return False


if __name__ == "__main__":
    guard(lambda: main(plan, "Prepare this machine to build xVeil."))
