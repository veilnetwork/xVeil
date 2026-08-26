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
    resolve,
    sh,
)

VEIL = os.path.join("third_party", "veil")
HV = os.path.join("third_party", "hidden-volume")


def seed_feature(release: bool) -> str:
    """The veil cargo feature naming this build's network.

    One rule, four build paths: `scripts/veil-network.sh` is the shell half and
    `lib/data/node/network_flavor.dart` the Dart half, and all of them read the
    same environment variable. A debug build without a seed feature is not
    neutral — veil hands `debug_assertions` the production list — so every path
    states its posture rather than leaving it to a default.
    """
    network = os.environ.get("XVEIL_NETWORK") or ("prod" if release else "testnet")
    try:
        return {"prod": "production-seeds", "testnet": "testnet-seeds"}[network]
    except KeyError:
        raise SystemExit(f"unknown XVEIL_NETWORK={network} (want prod|testnet)")


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


def _build_env(**extra: str) -> dict[str, str]:
    """The path remap, plus whatever else this particular step needs.

    Every step that compiles anything gets the remap; the platform variables
    ride along rather than replacing it. This exists because they were spelled
    separately: the linux and windows flutter steps carried
    `env=_engine_policy_env(release)` and therefore carried no remap, and
    nothing about `env=` at a call site says which of the two was meant.
    """
    return {**_path_remap_env(), **extra}


def _debug_hook_define() -> list[str]:
    """The stand hook, passed through from the environment. Empty unless asked.

    The hook is COMPILE-time: soak_hook.dart reads a `bool.fromEnvironment`, so
    a build made without the define has no hook and no way to gain one. What
    that looks like from outside is a node that never bootstrapped — no port
    answers, no runtime key is written — which is where the search then goes.

    A function rather than the same six lines per platform, because those six
    lines were copied and the copy was missed three times over: Android came up
    mute until 948adbb, Linux until the comment in `_linux` was written, and
    macOS was mute for every build on a machine with an Apple account the whole
    time — the SIGNED branch never had it, while the comments in the other two
    asserted that macOS already did. Passed through rather than always on: a
    debug build is still an ordinary build unless someone asks for a stand.
    """
    if os.environ.get("XVEIL_DEBUG_HOOK", "").lower() not in ("1", "true", "yes"):
        return []
    defines = ["--dart-define=XVEIL_DEBUG_HOOK=true"]
    # The port is a COMPILE-TIME define (int.fromEnvironment), so a stand that
    # needs two instances on ONE machine cannot separate them at launch — both
    # bind the platform default and the second one silently loses. Passing it
    # through here is what makes a second desktop build addressable at all.
    port = os.environ.get("XVEIL_DEBUG_HOOK_PORT", "").strip()
    if port:
        if not port.isdigit():
            raise SystemExit(f"XVEIL_DEBUG_HOOK_PORT must be a number, got {port!r}")
        defines.append(f"--dart-define=XVEIL_DEBUG_HOOK_PORT={port}")
    return defines


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
        # Only the ABIs this build actually PACKAGES. The release APK is
        # arm64-only (`_RELEASE_APK_ABIS`), and gradle rebuilds only that
        # slice, so an armeabi-v7a left over from before the ABI list narrowed
        # is permanently older than the tree and would fail this check for
        # ever. A gate that blocks correct builds is a gate somebody switches
        # off, and then it protects nothing — so it asks about what ships, and
        # names the leftovers separately instead of failing on them.
        shipped = [(abi, path) for abi, path in staged if abi in _RELEASE_APK_ABIS]
        leftover = [abi for abi, _ in staged if abi not in _RELEASE_APK_ABIS]
        if not shipped:
            problems.append(
                f"{soname}: nothing staged for {', '.join(_RELEASE_APK_ABIS)}"
                f"\n      fix: {cure}"
            )
            continue
        stale = []
        for abi, path in shipped:
            newer = newer_source(path, sources)
            if newer:
                stale.append(f"{abi} is older than {os.path.relpath(newer, ROOT)}")
        if stale:
            problems.append(
                f"{soname}: " + "; ".join(stale) + f"\n      fix: {cure}"
            )
        else:
            print(
                f"    {soname}: {len(shipped)} shipped ABI(s), each newer than "
                "its Rust source"
                + (
                    f" (not packaged, not checked: {', '.join(sorted(leftover))})"
                    if leftover
                    else ""
                )
            )
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


def _symbol_check_argv(path: str) -> list[str]:
    """How to invoke the symbol check, resolved the way every other step is.

    Not a bare "bash". On Windows that is C:\\Windows\\System32\\bash.exe — the
    WSL launcher — which with no distro installed prints "Windows Subsystem for
    Linux has no installed distributions" and exits 1.

    Exit 1 is the code the caller reads as "the engine is missing symbols". So
    the unresolved spelling does not merely skip the check on Windows: it fails
    an Android release there, accusing a perfectly good engine, in a message
    that would name symbols nobody ever looked at. resolve() finds the bash
    that Git for Windows ships, which is the one meant here.
    """
    argv = sh("scripts/check-media-symbols.sh", path)
    return [resolve(argv[0]), *argv[1:]]


def _media_symbols_verdict(path: str, *, label: str) -> list[str]:
    """Run the symbol check over one engine and turn its answer into problems.

    Three answers, deliberately not two — scripts/check-media-symbols.sh
    separates "symbols are missing" (1) from "I could not read this file" (2),
    and so does this. A host whose nm cannot open an aarch64 ELF has told us
    nothing about the engine, and reporting that as a clean bill of health is
    how a check earns being switched off. It prints NOT CHECKED instead, in the
    spelling used for every other unasked question in this build.

    The script reads ELF, Mach-O and Mach-O static archives, which is why the
    same function serves the .so out of an APK and the .a staged for iOS.
    """
    import subprocess

    script = os.path.join(ROOT, "scripts", "check-media-symbols.sh")
    if not os.path.isfile(script) or not have("bash"):
        print(f"    {label}: symbols NOT CHECKED — needs bash and {script}")
        return []

    done = subprocess.run(
        _symbol_check_argv(path), capture_output=True, text=True, cwd=ROOT
    )
    said = (done.stdout + done.stderr).strip().replace("\n", "\n      ")
    if done.returncode == 0:
        print(f"    {label}: exports everything Dart looks up")
        return []
    if done.returncode == 2:
        print(f"    {label}: symbols NOT CHECKED — {said}")
        return []
    return [f"{label} is stale or incomplete\n      {said}"]


def _media_symbols_problem(*, bundle_path: str, abi: str) -> list[str]:
    """Ask whether the engine INSIDE the APK exports what Dart looks up.

    Reads the copy that will be installed, not the one in the source tree:
    those differ exactly when it matters, because gradle packages whatever sits
    in jniLibs/ and that directory is gitignored.
    """
    import shutil
    import tempfile
    import zipfile

    with tempfile.TemporaryDirectory() as tmp:
        extracted = os.path.join(tmp, _MEDIA_SO)
        with zipfile.ZipFile(bundle_path) as bundle:
            with bundle.open(f"lib/{abi}/{_MEDIA_SO}") as src:
                with open(extracted, "wb") as dst:
                    shutil.copyfileobj(src, dst)
        return _media_symbols_verdict(extracted, label=f"{abi}: {_MEDIA_SO}")


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
            if abi == _MEDIA_ABI:
                # Present is not the same as current. The media engine is a
                # prebuilt nobody in an APK build rebuilds, so the stale one
                # travels: it is in the APK, the app starts, and the first call
                # into a symbol added since it was built dies at dlsym. That is
                # not hypothetical on either count — the Linux copy in this tree
                # was twelve commits behind (78 exported against 87 looked up),
                # and a stale libhidden_volume_ffi.so shipped in every APK for
                # three days while every gate was green.
                #
                # It survived because hidden_volume's bindings carry a checksum
                # per method and refuse to open the container. The media engine
                # has no such guard: it is plain dlsym, so the only place this
                # can be caught is here, in the artifact.
                problems.extend(_media_symbols_problem(bundle_path=apk, abi=abi))
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
            # THIS is the step libhidden_volume_ffi.so comes out of, and it was
            # the one step in an APK build without the remap. The flutter step
            # below has carried it since the 186-hit APK, which made the
            # environment look handled — but gradle never builds this library
            # (see the comment above), so nothing the flutter step exports can
            # reach it. A release APK built here still named its owner 49 times,
            # one $HOME/.cargo/registry path per panic site in tokio, uniffi,
            # argon2 and the rest.
            env=_path_remap_env(),
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
            # Same reason: it compiles C++ here rather than under gradle.
            env=_path_remap_env(),
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
                argv=[
                    "flutter", "build", "apk", "--debug",
                    f"--dart-define=XVEIL_VERSION={_pubspec_version()}",
                    # See _debug_hook_define: without this an APK comes up mute
                    # and /health answering nothing looks exactly like a node
                    # that failed to bootstrap, which is where the search goes.
                    *_debug_hook_define(),
                ],
                env=_path_remap_env(),
            )
        )
        # A debug APK goes on a phone too, and a stale storage library fails
        # there the same way. The check costs a walk of two source trees.
        steps.append(
            Step("native libraries are current", call=_check_android_native_fresh)
        )
    return steps


def _engine_policy_env(release: bool) -> dict[str, str]:
    """Tell the veil_media plugin CMake whether a missing engine is fatal.

    The plugin used to answer that itself, with a FATAL_ERROR, for everyone —
    so a clean clone could not START a linux or windows build. It now decides
    from VEIL_MEDIA_REQUIRE_ENGINE, defaulting to permissive off a CI runner
    (see veil_media/cmake/veil_media_engine_policy.cmake), and this is where a
    release says which build it is.

    An environment variable and not a -D because `flutter build linux` drives
    cmake itself and forwards no cmake arguments; the environment is the only
    channel that reaches it.

    Only set for a release. A debug build that says nothing gets the permissive
    path — which is the whole point, and the same answer the plugin would reach
    on its own.
    """
    return {"VEIL_MEDIA_REQUIRE_ENGINE": "1"} if release else {}


_LINUX_ENGINE_SO = "libveil_media.so"


def _check_linux_engine(bundle: str) -> None:
    """Refuse a linux bundle with no call media, the way windows already does.

    Linux had no such check: the plugin's FATAL_ERROR was the only thing
    standing between a clean clone and a bundle with no engine, and that gate
    is now conditional. release.yml greps the bundle for the same file after
    this runs — two artifact checks, because an artifact check is the only kind
    a forgotten flag cannot satisfy.
    """
    for directory, _, files in os.walk(os.path.join(ROOT, bundle)):
        if _LINUX_ENGINE_SO in files:
            found = os.path.join(directory, _LINUX_ENGINE_SO)
            print(f"    {os.path.relpath(found, ROOT)}")
            return
    raise RuntimeError(
        f"MISSING {_LINUX_ENGINE_SO} — this bundle has no call media.\n"
        f"    Expected it bundled from {_LINUX_ENGINE_STAGE}\n"
        "    It is gitignored, so a fresh clone never has it. Voice messages,\n"
        "    video notes, in-chat video, calls and speech-to-text all load it.\n"
        "    Build it on an x86_64 Linux host with a from-source WebRTC:\n"
        "      veil_media/linux/build_veil_media_so_linux.sh\n"
        "    or download the artifact the webrtc-linux workflow produces."
    )


_LINUX_ENGINE_STAGE = os.path.join(
    VEIL, "flutter", "veil_media", "linux", _LINUX_ENGINE_SO
)


def _linux(release: bool) -> list[Step]:
    steps = [
        Step(
            "native libraries",
            argv=sh("scripts/build-native.sh") + (["--release"] if release else []),
            env=_build_env(),
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
            env=_build_env(),
        )
    )
    steps.append(
        Step(
            "flutter bundle",
            argv=[
                "flutter",
                "build",
                "linux",
                "--release" if release else "--debug",
                f"--dart-define=XVEIL_VERSION={_pubspec_version()}",
                # See _debug_hook_define. This was called "the third host and
                # the last one that was missing it" — it was not: the SIGNED
                # macOS branch had never had it, and the ad-hoc script that
                # does is only reached on a machine with no Apple account.
                *_debug_hook_define(),
            ],
            env=_build_env(**_engine_policy_env(release)),
        )
    )
    if release:
        steps.append(
            Step(
                "call engine in the bundle",
                call=lambda: _check_linux_engine(
                    os.path.join("build", "linux", "x64", "release", "bundle")
                ),
            )
        )
    return steps


# What a macOS bundle must carry, and what it may.
#
# The two REQUIRED ones are the app itself: without them it cannot open a
# container or reach the network. The rest are features that degrade — but they
# are REPORTED, because "the build carries no translation" is a thing to learn
# here rather than from a person tapping a button that does nothing.
_MACOS_REQUIRED_DYLIBS = (
    'libhidden_volume_ffi.dylib',
    'libveilclient_ffi.dylib',
)
_MACOS_OPTIONAL_DYLIBS = (
    'libveil_media.dylib',
    'libveil_whisper.dylib',
    'libveil_translate.dylib',
)


def _check_macos_bundle(config: str) -> None:
    """Verify the ARTIFACT, not that the bundling script exited 0.

    The bundler copies what it knows about, and what it knows about is a list
    somebody maintains. libveil_translate.dylib was built, verified and absent
    from every .app for as long as it existed, because nothing in that list
    mentioned it and nothing afterwards looked. Android had the same shape at
    the same time; this is the macOS half of that lesson.
    """
    subdir = 'Release' if config == 'release' else 'Debug'
    frameworks = os.path.join(
        ROOT, 'build', 'macos', 'Build', 'Products', subdir,
        'xveil.app', 'Contents', 'Frameworks',
    )
    if not os.path.isdir(frameworks):
        raise RuntimeError(
            f'no Frameworks directory at {frameworks}\n'
            '    The bundle was not produced, or was produced somewhere else.'
        )

    present = set(os.listdir(frameworks))
    missing = [name for name in _MACOS_REQUIRED_DYLIBS if name not in present]
    if missing:
        raise RuntimeError(
            'THE macOS BUNDLE IS INCOMPLETE — do not hand this out.\n'
            f'    missing: {", ".join(missing)}\n'
            f'    in {frameworks}'
        )
    print(f'    {len(present)} items in Frameworks, both required dylibs present')
    for name in _MACOS_OPTIONAL_DYLIBS:
        feature = {
            'libveil_media.dylib': 'calls and voice messages',
            'libveil_whisper.dylib': 'speech to text',
            'libveil_translate.dylib': 'message translation',
        }[name]
        if name in present:
            print(f'    {name}: {feature}')
        else:
            print(f'    {name} ABSENT — this build has no {feature}')


def _macos(release: bool) -> list[Step]:
    config = "release" if release else "debug"
    whisper = _whisper_script("macos")
    steps = [
        Step(
            "native libraries",
            argv=sh("scripts/build-native.sh") + (["--release"] if release else []),
            # The macOS twin of the android defect: this is where all three
            # host libraries are compiled, and it ran with a bare environment.
            env=_build_env(),
        ),
        Step(
            "whisper wrapper (transcription)",
            argv=["bash", whisper] if whisper else [],
            optional=True,
            skip_if="" if whisper else "no build script for this platform",
            # CXXFLAGS reaches the clang++ that builds the wrapper. It does NOT
            # reach the whisper.cpp archives it links: those are built by hand
            # in a separate checkout, the same shape as CTranslate2, and what
            # survives from them has to be measured rather than assumed.
            env=_build_env(),
        ),
    ]
    if _apple_signing_available():
        steps.append(
            Step(
                "flutter bundle (signed)",
                argv=[
                    "flutter", "build", "macos", f"--{config}",
                    # Both defines were on the AD-HOC path only — the script
                    # taken when this machine has NO Apple account. So the
                    # better-equipped machine produced the worse build: a stand
                    # asked for with XVEIL_DEBUG_HOOK=true came up mute, and
                    # every error report from a signed bundle named no version.
                    # The other two platforms carried comments asserting macOS
                    # already had this.
                    f"--dart-define=XVEIL_VERSION={_pubspec_version()}",
                    *_debug_hook_define(),
                ],
                # The Xcode build runs build-packet-tunnel-macos.sh, which is a
                # cargo build several processes down. The environment is the
                # only channel that reaches it.
                env=_build_env(),
            )
        )
        steps.append(
            Step(
                "bundle native dylibs",
                argv=sh("scripts/bundle-macos-dylibs.sh", config),
                env=_build_env(),
            )
        )
        steps.append(
            Step(
                "native libraries in the bundle",
                call=lambda: _check_macos_bundle(config),
            )
        )
    else:
        # No provisioning profile on this machine, so the restricted VPN
        # entitlement cannot be signed. The ad-hoc script drops the tunnel
        # extension, bundles, re-signs, and checks the result is not stale.
        steps.append(
            Step(
                "app bundle, ad-hoc (no Apple account here — VPN dropped)",
                argv=sh("scripts/build-macos-adhoc.sh", config),
                # Same reason as the signed branch: this script reaches
                # xcodebuild, and xcodebuild reaches cargo.
                env=_build_env(),
            )
        )
        # The ad-hoc script bundles too, so the same question applies to what
        # it produced.
        steps.append(
            Step(
                "native libraries in the bundle",
                call=lambda: _check_macos_bundle(config),
            )
        )
    return steps


_MEDIA_IOS_A = os.path.join(
    VEIL, "flutter", "veil_media", "ios", "Frameworks", "libveil_media.a"
)


def _check_ios_engine() -> None:
    """iOS had no engine check at all — neither presence nor contents.

    It is the same gitignored prebuilt as everywhere else, staged by
    build-mobile.sh into ios/Frameworks/, and on iOS the failure is quieter
    than on Android: the archive is linked INTO Runner, so a stale one links
    cleanly and the Dart lookup through DynamicLibrary.process() throws at the
    first call to whatever the archive predates.

    Two things are asked, because they can disagree:

    - the staged archive, always. This is the input, it is what the build
      consumed, and the check reads Mach-O archives directly.
    - the linked Runner, when a build left one behind. This is the only place a
      symbol dropped by dead-stripping would show up, which the archive cannot
      tell us. A release Runner may be stripped, and then the check answers
      "cannot read a symbol table" — reported as NOT CHECKED, never as a
      failure, so stripping can produce no false alarm here.
    """
    problems: list[str] = []
    if os.path.isfile(_MEDIA_IOS_A):
        problems += _media_symbols_verdict(
            _MEDIA_IOS_A, label=f"staged {os.path.basename(_MEDIA_IOS_A)}"
        )
    else:
        raise RuntimeError(
            f"MISSING {os.path.basename(_MEDIA_IOS_A)} — this build has no call media.\n"
            f"    Expected it staged at {_MEDIA_IOS_A}\n"
            "    It is gitignored, so a fresh clone never has it. Voice messages,\n"
            "    video notes, in-chat video, calls and speech-to-text all load it.\n"
            "      scripts/build-mobile.sh ios"
        )

    for directory, _, files in os.walk(os.path.join(ROOT, "build", "ios")):
        if directory.endswith("Runner.app") and "Runner" in files:
            runner = os.path.join(directory, "Runner")
            problems += _media_symbols_verdict(
                runner, label=os.path.relpath(runner, ROOT)
            )
            break

    if problems:
        raise RuntimeError(
            "THE iOS BUILD'S CALL ENGINE IS WRONG — do not hand this out.\n    "
            + "\n    ".join(problems)
        )


def _ios(release: bool) -> list[Step]:
    steps = [
        Step(
            "native libraries for iOS",
            argv=sh("scripts/build-mobile.sh", "ios"),
            # iOS is the one platform where the paths go into a STATIC archive
            # rather than a shared object, so they are carried through the link
            # into Runner instead of being resolved away.
            env=_build_env(),
        ),
    ]
    if _apple_signing_available():
        steps.append(
            Step(
                "flutter build ios",
                argv=[
                    "flutter", "build", "ios",
                    "--release" if release else "--debug",
                    f"--dart-define=XVEIL_VERSION={_pubspec_version()}",
                ],
                env=_build_env(),
            )
        )
    else:
        steps.append(
            Step(
                "flutter build ios (unsigned — no provisioning profile here)",
                argv=[
                    "flutter", "build", "ios",
                    "--release" if release else "--debug", "--no-codesign",
                    f"--dart-define=XVEIL_VERSION={_pubspec_version()}",
                ],
                env=_build_env(),
            )
        )
    # Release only, for the same reason as windows above: this refused a plain
    # `builder.py ios --debug` on a clean checkout, which is the build someone
    # runs to find out whether the project compiles at all.
    steps.append(
        Step(
            "call engine in the iOS build",
            call=_check_ios_engine,
            optional=not release,
            skip_if="" if release else "debug build — calls may be absent",
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
    # Which network this binary belongs to — the same rule every other build
    # path applies. Hardcoding "production-seeds" here meant a Windows DEBUG
    # build dialled the production seeds whatever the rest of the build was
    # told, and nothing in the app could see it.
    cargo_veil = ["cargo", "build", "--manifest-path", os.path.join(VEIL, "Cargo.toml"),
                  "-p", "veilclient-ffi",
                  "--features", f"node-embedded,{seed_feature(release)}"]
    whisper_win = _whisper_script("windows")
    whisper_dll = os.path.join(ROOT, "native", "whisper", "windows", "veil_whisper.dll")
    # Written before the Windows build script exists, deliberately. Every other
    # platform learned the same lesson in one week: Android built its library
    # into a directory the APK never reads, macOS never copied its dylib, and
    # iOS linked nothing at all -- three libraries that were built, verified and
    # unreachable. The skip_if below keeps this inert until there is a DLL, and
    # present the moment there is one.
    translate_dll = os.path.join(ROOT, "native", "translate", "windows", "veil_translate.dll")
    if profile:
        cargo_hv.append(profile)
        cargo_veil.append(profile)
    return [
        Step("hidden-volume FFI", argv=cargo_hv, env=_build_env()),
        # The plugin's CMake picks the DLL up from windows/lib; without this
        # the app builds and then cannot open its own container at runtime.
        Step(
            f"stage hidden_volume_ffi.dll -> {hv_stage}",
            call=lambda: _copy(hv_dll, hv_stage),
        ),
        Step("veil client FFI", argv=cargo_veil, env=_build_env()),
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
            env=_build_env(),
        ),
        Step(
            "flutter bundle",
            argv=[
                "flutter", "build", "windows",
                "--release" if release else "--debug",
                f"--dart-define=XVEIL_VERSION={_pubspec_version()}",
            ],
            env=_build_env(**_engine_policy_env(release)),
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
            f"stage veil_translate.dll -> {runner}",
            call=lambda: _copy(translate_dll, runner),
            optional=True,
            skip_if=(
                "" if os.path.isfile(translate_dll) else "translation not built"
            ),
        ),
        # Release only. A debug bundle without an engine is now a supported
        # thing to have — the plugin CMake warns and the app reports calls,
        # voice messages, video notes and speech-to-text as unavailable. What
        # must not exist is a RELEASE without one.
        Step(
            "call engine in the bundle",
            call=lambda: _check_windows_engine(runner),
            optional=not release,
            skip_if="" if release else "debug build — calls may be absent",
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
