#!/usr/bin/env python3
"""Build xVeil for a target, native libraries included.

    ./builder.py [target] [--debug|--release] [--dry-run]

`target` defaults to this machine's own system and may be android, linux,
windows, macos or ios. Release unless you say `--debug`. Runs on Windows,
Linux and macOS.

Run `prepare.py` first on a machine that has not built this before.

Where a shell script already exists it is called rather than reimplemented:
those carry deployment targets, staging paths, entitlements and signing
workarounds that were expensive to learn. Windows has no such scripts, so its
commands are spelled out here, mirroring BUILDING.md.
"""

from __future__ import annotations

import os
import shutil
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts"))

from xveil_build_support import (  # noqa: E402
    ROOT,
    Step,
    guard,
    have,
    host,
    main,
    newer_source,
    sh,
)

VEIL = os.path.join("third_party", "veil")
HV = os.path.join("third_party", "hidden-volume")


def _apple_signing_available() -> bool:
    """Whether a normal signed Apple build can even be attempted.

    A provisioning profile is what the restricted VPN entitlement needs, and
    without an Apple account none can be minted — so the plain
    `flutter build macos` fails at signing after compiling everything. Better
    to notice here and take the ad-hoc path than to spend the compile first.
    """
    profiles = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
    return os.path.isdir(profiles) and bool(os.listdir(profiles))


def _whisper_script(target: str) -> str | None:
    name = {
        "android": "build_veil_whisper_android.sh",
        "linux": "build_veil_whisper_linux.sh",
        "macos": "build_veil_whisper_macos.sh",
        "windows": "build_veil_whisper_windows.sh",
    }.get(target)
    if not name:
        return None
    path = os.path.join(ROOT, "native", "whisper", name)
    return path if os.path.isfile(path) else None


def _copy(source: str, destination_dir: str) -> None:
    os.makedirs(os.path.join(ROOT, destination_dir), exist_ok=True)
    shutil.copy2(os.path.join(ROOT, source), os.path.join(ROOT, destination_dir))
    print(f"    staged {os.path.basename(source)} -> {destination_dir}")


def _path_remap_env() -> dict[str, str]:
    """Keep the builder's absolute paths out of the shipped binaries.

    rustc bakes the source path of every panic site into the library — for
    dependencies that is `$HOME/.cargo/registry/...`, so a release APK carried
    the builder's account name 186 times. Nothing reads those strings at
    runtime; they exist for backtraces, and a remapped prefix serves that
    purpose just as well while making the build reproducible across machines.

    `CARGO_BUILD_RUSTFLAGS` rather than `RUSTFLAGS` so an operator who sets
    RUSTFLAGS for their own reasons still wins. The .so is produced by each
    plugin's gradle cargo-ndk task during `flutter build`, several processes
    below this one, which is why this is an environment variable and not a
    command-line flag.
    """
    home = os.path.expanduser("~")
    # Longest prefix first: cargo lives under home, and rustc applies the
    # mappings in order.
    remaps = [
        f"--remap-path-prefix={os.path.join(home, '.cargo')}=/cargo",
        f"--remap-path-prefix={ROOT}=/xveil",
        f"--remap-path-prefix={home}=/build",
    ]
    existing = os.environ.get("CARGO_BUILD_RUSTFLAGS", "").strip()
    # `--remap-path-prefix` is a rustc flag and stops there. Crates that
    # compile C through cc-rs (aws-lc-sys is the big one) embed their own
    # __FILE__ strings, so the C and C++ compilers need the equivalent or the
    # account name simply moves from the Rust frames to the C ones.
    cmap = f"-ffile-prefix-map={home}=/build"
    env = {"CARGO_BUILD_RUSTFLAGS": " ".join(filter(None, [existing, *remaps]))}
    for var in ("CFLAGS", "CXXFLAGS"):
        env[var] = " ".join(filter(None, [os.environ.get(var, "").strip(), cmap]))
    return env


def _pubspec_version() -> str:
    """The version the error report will name.

    Read here rather than passed by hand: a report saying "dev" cannot be tied
    to anything a tester actually has, and a literal in the source goes stale
    the first time someone forgets to bump it.
    """
    with open(os.path.join(ROOT, "pubspec.yaml"), encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("version:"):
                return line.split(":", 1)[1].strip()
    from xveil_build_support import Abort

    raise Abort("cannot read 'version:' from pubspec.yaml")


def _check_android_signing() -> None:
    """Refuse to call a debug-signed APK a release.

    Gradle now refuses this itself (audit X-13): a release build without
    android/key.properties fails outright unless -PxveilAllowDebugSigning=true
    was passed on purpose. This check stays as the backstop for exactly that
    case — the escape hatch can be left behind in android/gradle.properties,
    and then gradle is doing what it was told while the result is still not
    distributable.

    Without android/key.properties gradle used to fall back to the debug key.
    It did warn, but a warning in the middle of a two-minute build is not one
    anyone reads — this is checked at the END, where it cannot scroll past.

    Two consequences, both permanent: an update can never be shipped over it
    (Android treats a different signing key as a different app, so testers
    would have to uninstall and lose their identity and history), and anyone
    can build an APK that installs over yours.
    """
    if os.path.isfile(os.path.join(ROOT, "android", "key.properties")):
        print("    signed with the key from android/key.properties")
        return
    raise RuntimeError(
        "DEBUG-SIGNED — do not hand this out.\n"
        "    android/key.properties is missing, so gradle used the debug key.\n"
        "    Create the keystore once and keep it safe; it is the app's\n"
        "    identity for as long as the app exists:\n"
        "      keytool -genkey -v -keystore ~/xveil-release.jks \\\n"
        "        -keyalg RSA -keysize 4096 -validity 10000 -alias xveil\n"
        "    then write android/key.properties with storeFile, storePassword,\n"
        "    keyPassword and keyAlias. Both files are gitignored."
    )


# libveil_media.so is NOT built by any gradle task: it is a prebuilt staged
# into android/app/src/main/jniLibs/<abi>/ by veil_media/android/
# build_veil_media_so.sh, which needs a from-source WebRTC checkout on an
# x86_64 Linux host. That script builds arm64 ONLY, so arm64-v8a is the one ABI
# whose APK can carry the media engine at all.
_MEDIA_ABI = "arm64-v8a"
_MEDIA_SO = "libveil_media.so"
_MEDIA_STAGE_DIR = os.path.join("android", "app", "src", "main", "jniLibs")
_MEDIA_BUILD_SCRIPT = os.path.join(
    VEIL, "flutter", "veil_media", "android", "build_veil_media_so.sh"
)
# Listed because their absence is exactly as silent and exactly as fatal: no
# network, no store. Only ONE of the two is produced by a gradle cargo-ndk task
# (see _ANDROID_NATIVE).
_REQUIRED_EVERY_ABI = ("libveilclient_ffi.so", "libhidden_volume_ffi.so")

# The Rust trees each native library is built from. Used to ask the only
# question that matters about a built artifact: is it older than the code it
# claims to be?
_HV_SOURCES = [
    os.path.join(ROOT, HV, "crates"),
    os.path.join(ROOT, HV, "Cargo.toml"),
    os.path.join(ROOT, HV, "Cargo.lock"),
]
_VEIL_SOURCES = [
    os.path.join(ROOT, VEIL, "crates"),
    os.path.join(ROOT, VEIL, "veilclient"),
    os.path.join(ROOT, VEIL, "veilcore"),
    os.path.join(ROOT, VEIL, "Cargo.toml"),
    os.path.join(ROOT, VEIL, "Cargo.lock"),
]

# (library, staging dir, its sources, what rebuilds it).
#
# The two plugins are NOT symmetric and the asymmetry is the whole defect.
# veil_flutter's gradle module runs cargo-ndk on every `flutter build apk`;
# hidden_volume's module has no cargo step at all and simply bundles whatever
# already sits in its gitignored jniLibs/. So for one of them "gradle ran"
# means "the library is current" and for the other it means nothing.
_ANDROID_NATIVE = (
    (
        "libhidden_volume_ffi.so",
        os.path.join(
            HV, "experimental", "flutter_plugin", "hidden_volume",
            "android", "src", "main", "jniLibs",
        ),
        _HV_SOURCES,
        "scripts/build-mobile.sh android   (needs bash + cargo-ndk + ANDROID_NDK_HOME)",
    ),
    (
        "libveilclient_ffi.so",
        os.path.join(VEIL, "flutter", "veil_flutter", "android", "src", "main", "jniLibs"),
        _VEIL_SOURCES,
        "flutter build apk   (its gradle module runs cargo-ndk; unset VEIL_SKIP_CARGO)",
    ),
)


def _check_android_native_fresh() -> None:
    """Refuse to package a native library older than the code it stands for.

    Existence was already checked; that is not the same question. A .so from
    2026-08-02 exists just as convincingly as one built a minute ago, and the
    APK that shipped it was honestly green — the storage format had moved
    underneath it and the runtime checksum guard refused to open the container,
    which a device shows as onboarding simply failing.

    Run AFTER the flutter build: gradle produces veil_flutter's .so during it,
    and hidden_volume's is produced by the step at the top of this plan or by
    nothing at all.
    """
    problems: list[str] = []
    for soname, stage_dir, sources, cure in _ANDROID_NATIVE:
        stage = os.path.join(ROOT, stage_dir)
        staged = []
        if os.path.isdir(stage):
            for abi in sorted(os.listdir(stage)):
                path = os.path.join(stage, abi, soname)
                if os.path.isfile(path):
                    staged.append((abi, path))
        if not staged:
            problems.append(f"{soname}: nothing staged under {stage_dir}\n      fix: {cure}")
            continue
        stale = []
        for abi, path in staged:
            newer = newer_source(path, sources)
            if newer:
                stale.append(f"{abi} is older than {os.path.relpath(newer, ROOT)}")
        if stale:
            problems.append(
                f"{soname}: " + "; ".join(stale) + f"\n      fix: {cure}"
            )
        else:
            print(f"    {soname}: {len(staged)} ABI(s), each newer than its Rust source")
    if problems:
        raise RuntimeError(
            "NATIVE LIBRARIES ARE STALE — this APK would ship code that was not\n"
            "    built from this tree.\n    "
            + "\n    ".join(problems)
        )


def _check_linux_native_fresh(release: bool) -> None:
    """The same question for the Linux bundle.

    veil_flutter's linux CMakeLists copies both .so straight out of each
    submodule's target/<profile>/ and only checks that they EXIST, so a bundle
    built without running build-native.sh first carries whatever was there.
    """
    profile = "release" if release else "debug"
    problems: list[str] = []
    for soname, submodule, sources in (
        ("libhidden_volume_ffi.so", HV, _HV_SOURCES),
        ("libveilclient_ffi.so", VEIL, _VEIL_SOURCES),
    ):
        path = os.path.join(ROOT, submodule, "target", profile, soname)
        if not os.path.isfile(path):
            problems.append(f"{soname}: not built at {os.path.relpath(path, ROOT)}")
            continue
        newer = newer_source(path, sources)
        if newer:
            problems.append(
                f"{soname}: older than {os.path.relpath(newer, ROOT)}"
            )
        else:
            print(f"    {soname}: newer than its Rust source")
    if problems:
        raise RuntimeError(
            "NATIVE LIBRARIES ARE STALE — the bundle copies these straight out\n"
            "    of each submodule's target/, so it would ship code that was not\n"
            "    compiled from this tree.\n    "
            + "\n    ".join(problems)
            + "\n    fix: scripts/build-native.sh"
            + (" --release" if release else "")
        )
# arm64-v8a ONLY, deliberately. armeabi-v7a and x86_64 built fine and were
# published through v0.9.1, but neither can carry the media engine, so voice
# messages, video notes, calls and speech-to-text are dead in them. Shipping an
# APK that looks like the app and quietly cannot do half of it is worse than
# not shipping one: every phone the project has seen is arm64 anyway.
_RELEASE_APK_ABIS = ("arm64-v8a",)


def _staged_media_so() -> str:
    return os.path.join(ROOT, _MEDIA_STAGE_DIR, _MEDIA_ABI, _MEDIA_SO)


def _check_media_staged() -> None:
    """Refuse to start a release build that would ship without call media.

    The prebuilt is gitignored, so a FRESH CLONE has nothing here and nothing
    downstream notices: gradle packages whatever ABI directories exist, the
    build goes green, and the APK installs and runs right up until someone
    records a voice message. v0.9.1 shipped exactly this way.

    Checked before the build rather than only after it because the build costs
    minutes and this costs a stat call.
    """
    if os.path.isfile(_staged_media_so()):
        print(f"    {_MEDIA_ABI}/{_MEDIA_SO} staged")
        return
    raise RuntimeError(
        f"MISSING {_MEDIA_SO} — this build would ship without call media.\n"
        f"    Expected at {_MEDIA_STAGE_DIR}/{_MEDIA_ABI}/{_MEDIA_SO}\n"
        "    It is gitignored, so a fresh clone never has it. Voice messages,\n"
        "    video notes, in-chat video, calls and speech-to-text all load it;\n"
        "    without it each one throws 'library libveil_media.so not found'.\n"
        "    Restore it by copying the .so from a checkout that has one, or\n"
        "    rebuild it on an x86_64 Linux host with a WebRTC checkout:\n"
        f"      WEBRTC_BUILD=~/webrtc-android {_MEDIA_BUILD_SCRIPT}"
    )


def _check_android_native_libs() -> None:
    """Verify the ARTIFACT, not the exit status.

    The build being green says gradle ran, not that what it produced can do
    its job — the APK that shipped as v0.9.1 was honestly green and could not
    load its media engine. So open each APK and read what is actually in it.
    """
    import zipfile

    apk_dir = os.path.join(ROOT, "build", "app", "outputs", "flutter-apk")
    problems: list[str] = []
    for abi in _RELEASE_APK_ABIS:
        apk = os.path.join(apk_dir, f"app-{abi}-release.apk")
        if not os.path.isfile(apk):
            problems.append(f"{abi}: no APK at {apk}")
            continue
        with zipfile.ZipFile(apk) as bundle:
            names = {
                entry.rsplit("/", 1)[-1]
                for entry in bundle.namelist()
                if entry.startswith(f"lib/{abi}/")
            }
        required = list(_REQUIRED_EVERY_ABI)
        if abi == _MEDIA_ABI:
            required.append(_MEDIA_SO)
        missing = [so for so in required if so not in names]
        if missing:
            problems.append(f"{abi}: missing {', '.join(missing)}")
        else:
            print(f"    {abi}: {len(names)} native libs, all required ones present")
        stray = [
            entry
            for entry in os.listdir(apk_dir)
            if entry.endswith("-release.apk")
            and entry != f"app-{abi}-release.apk"
        ]
        if stray:
            # A leftover from a build before the ABI list narrowed. Left in
            # place it gets uploaded beside the good one and installed by
            # whoever reads the filename as a choice.
            problems.append(
                "these are not published and must not be handed out "
                f"(stale from an earlier build): {', '.join(sorted(stray))}"
            )
    if problems:
        raise RuntimeError(
            "APK CONTENTS ARE WRONG — do not publish these.\n    "
            + "\n    ".join(problems)
        )


def _android(release: bool) -> list[Step]:
    # NOT optional, and the previous comment here ("gradle builds the .so
    # anyway") was false: gradle builds ONE of the two. This step is the only
    # thing in an APK build that produces libhidden_volume_ffi.so, so a failure
    # that is shrugged off leaves the previous one in place — which is exactly
    # what shipped for three days. A host without bash cannot run it at all;
    # there the freshness gate after the build is what refuses the leftovers.
    steps = [
        Step(
            "native libraries (hidden_volume has no gradle cargo step)",
            argv=sh("scripts/build-mobile.sh", "android") if have("bash") else [],
            skip_if=(
                "" if have("bash") else "needs bash — the freshness gate below decides"
            ),
        )
    ]
    whisper = _whisper_script("android")
    steps.append(
        Step(
            "whisper wrapper (transcription)",
            argv=["bash", whisper] if whisper and have("bash") else [],
            optional=True,
            skip_if=(
                ""
                if whisper and have("bash")
                else "no build script for this host"
            ),
        )
    )
    if release:
        steps.append(Step("call media staged", call=_check_media_staged))
        # Done here rather than in a shell script so a Windows host can also
        # produce release APKs — and so the signing check cannot drift from
        # the build it guards. scripts/build-android-release.sh calls this.
        steps.append(
            Step(
                "release APK (arm64 only)",
                argv=[
                    "flutter", "build", "apk", "--release", "--split-per-abi",
                    # arm64 only — see _RELEASE_APK_ABIS. Kept as split-per-abi
                    # rather than a plain build so the file kept the name
                    # people already have links to.
                    "--target-platform", "android-arm64",
                    f"--dart-define=XVEIL_VERSION={_pubspec_version()}",
                ],
                env=_path_remap_env(),
            )
        )
        steps.append(
            Step("native libraries are current", call=_check_android_native_fresh)
        )
        steps.append(
            Step("native libraries in the APKs", call=_check_android_native_libs)
        )
        steps.append(Step("signing check", call=_check_android_signing))
    else:
        steps.append(
            Step(
                "debug APK",
                argv=["flutter", "build", "apk", "--debug"],
                env=_path_remap_env(),
            )
        )
        # A debug APK goes on a phone too, and a stale storage library fails
        # there the same way. The check costs a walk of two source trees.
        steps.append(
            Step("native libraries are current", call=_check_android_native_fresh)
        )
    return steps


def _linux(release: bool) -> list[Step]:
    steps = [
        Step(
            "native libraries",
            argv=sh("scripts/build-native.sh") + (["--release"] if release else []),
        ),
        Step(
            "native libraries are current",
            call=lambda: _check_linux_native_fresh(release),
        ),
    ]
    whisper = _whisper_script("linux")
    steps.append(
        Step(
            "whisper wrapper (transcription)",
            argv=["bash", whisper] if whisper else [],
            optional=True,
            skip_if="" if whisper else "no build script for this platform",
        )
    )
    steps.append(
        Step(
            "flutter bundle",
            argv=["flutter", "build", "linux", "--release" if release else "--debug"],
        )
    )
    return steps


def _macos(release: bool) -> list[Step]:
    config = "release" if release else "debug"
    whisper = _whisper_script("macos")
    steps = [
        Step(
            "native libraries",
            argv=sh("scripts/build-native.sh") + (["--release"] if release else []),
        ),
        Step(
            "whisper wrapper (transcription)",
            argv=["bash", whisper] if whisper else [],
            optional=True,
            skip_if="" if whisper else "no build script for this platform",
        ),
    ]
    if _apple_signing_available():
        steps.append(
            Step(
                "flutter bundle (signed)",
                argv=["flutter", "build", "macos", f"--{config}"],
            )
        )
        steps.append(
            Step("bundle native dylibs", argv=sh("scripts/bundle-macos-dylibs.sh", config))
        )
    else:
        # No provisioning profile on this machine, so the restricted VPN
        # entitlement cannot be signed. The ad-hoc script drops the tunnel
        # extension, bundles, re-signs, and checks the result is not stale.
        steps.append(
            Step(
                "app bundle, ad-hoc (no Apple account here — VPN dropped)",
                argv=sh("scripts/build-macos-adhoc.sh", config),
            )
        )
    return steps


def _ios(release: bool) -> list[Step]:
    steps = [
        Step("native libraries for iOS", argv=sh("scripts/build-mobile.sh", "ios")),
    ]
    if _apple_signing_available():
        steps.append(
            Step(
                "flutter build ios",
                argv=["flutter", "build", "ios", "--release" if release else "--debug"],
            )
        )
    else:
        steps.append(
            Step(
                "flutter build ios (unsigned — no provisioning profile here)",
                argv=[
                    "flutter", "build", "ios",
                    "--release" if release else "--debug", "--no-codesign",
                ],
            )
        )
    return steps


_WINDOWS_ENGINE_DLL = "veil_media.dll"
_WINDOWS_ENGINE_STAGE = os.path.join(
    VEIL, "flutter", "veil_media", "windows", _WINDOWS_ENGINE_DLL
)


def _check_windows_engine(runner: str) -> None:
    """Refuse a Windows bundle with no call media, the way linux already does.

    Windows had no engine at all until the veil_media windows/ port: every zip
    through v0.9.1 started, looked healthy, and threw at the first voice
    message. The plugin CMake fails the build when the prebuilt is absent, so
    reaching here without it means the bundle was assembled some other way —
    check the artifact rather than trusting that.
    """
    found = None
    for directory, _, files in os.walk(os.path.join(ROOT, runner)):
        if _WINDOWS_ENGINE_DLL in files:
            found = os.path.join(directory, _WINDOWS_ENGINE_DLL)
            break
    if found is not None:
        print(f"    {os.path.relpath(found, ROOT)}")
        return
    raise RuntimeError(
        f"MISSING {_WINDOWS_ENGINE_DLL} — this bundle has no call media.\n"
        f"    Expected it bundled from {_WINDOWS_ENGINE_STAGE}\n"
        "    It is gitignored, so a fresh clone never has it. Voice messages,\n"
        "    video notes, in-chat video, calls and speech-to-text all load it.\n"
        "    Build it on a Windows host with a from-source win-x64 WebRTC:\n"
        "      veil_media/windows/build_veil_media_dll_windows.ps1\n"
        "    or download the artifact the webrtc-windows workflow produces."
    )


def _windows(release: bool) -> list[Step]:
    profile = "--release" if release else ""
    out = "release" if release else "debug"
    hv_dll = os.path.join(HV, "target", out, "hidden_volume_ffi.dll")
    veil_dll = os.path.join(VEIL, "target", out, "veilclient_ffi.dll")
    hv_stage = os.path.join(
        HV, "experimental", "flutter_plugin", "hidden_volume", "windows", "lib"
    )
    runner = os.path.join("build", "windows", "x64", "runner", "Release" if release else "Debug")
    cargo_hv = ["cargo", "build", "--manifest-path", os.path.join(HV, "Cargo.toml"),
                "-p", "hidden-volume-ffi"]
    cargo_veil = ["cargo", "build", "--manifest-path", os.path.join(VEIL, "Cargo.toml"),
                  "-p", "veilclient-ffi", "--features", "node-embedded,production-seeds"]
    whisper_win = _whisper_script("windows")
    whisper_dll = os.path.join(ROOT, "native", "whisper", "windows", "veil_whisper.dll")
    if profile:
        cargo_hv.append(profile)
        cargo_veil.append(profile)
    return [
        Step("hidden-volume FFI", argv=cargo_hv),
        # The plugin's CMake picks the DLL up from windows/lib; without this
        # the app builds and then cannot open its own container at runtime.
        Step(
            f"stage hidden_volume_ffi.dll -> {hv_stage}",
            call=lambda: _copy(hv_dll, hv_stage),
        ),
        Step("veil client FFI", argv=cargo_veil),
        # Optional like every other platform's: without it the app still
        # builds and runs, and `WhisperFfi.nativeReady()` reports transcription
        # as unavailable rather than offering a 57 MiB model download that
        # could not help.
        Step(
            "whisper wrapper (transcription)",
            argv=["bash", whisper_win] if whisper_win and have("bash") else [],
            optional=True,
            skip_if=(
                ""
                if whisper_win and have("bash")
                else "no build script for this host"
            ),
        ),
        Step(
            "flutter bundle",
            argv=["flutter", "build", "windows", "--release" if release else "--debug"],
        ),
        # Staged after the Flutter build, which creates the runner directory.
        Step(
            f"stage veilclient_ffi.dll -> {runner}",
            call=lambda: _copy(veil_dll, runner),
        ),
        Step(
            f"stage veil_whisper.dll -> {runner}",
            call=lambda: _copy(whisper_dll, runner),
            optional=True,
            skip_if="" if os.path.isfile(whisper_dll) else "whisper not built",
        ),
        Step(
            "call engine in the bundle",
            call=lambda: _check_windows_engine(runner),
        ),
        Step(
            "reminder: what must travel with xveil.exe",
            call=lambda: print(
                "    keep veilclient_ffi.dll, veil_vpn_helper.dll, wintun.dll, the\n"
                "    hidden-volume DLL and WINTUN-LICENSE.txt beside xveil.exe"
            ),
        ),
    ]


def plan(target: str, *, release: bool) -> list[Step]:
    if not have("flutter"):
        from xveil_build_support import Abort

        raise Abort("flutter is not on PATH — run prepare.py first")
    builders = {
        "android": _android,
        "linux": _linux,
        "macos": _macos,
        "ios": _ios,
        "windows": _windows,
    }
    print(f"profile: {'release' if release else 'debug'}")
    return builders[target](release)


if __name__ == "__main__":
    guard(lambda: main(plan, "Build xVeil for a target."))
