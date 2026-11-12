"""Run the Flutter/packaging half of a release in a private neutral workspace.

Native producers run first in the original checkout. Only their library outputs
are copied, never Cargo caches. The child runs the ordinary builder's checks and
packaging against the staged sources. Nothing is exported until all checks pass.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

from aot_package_roots import _directory_alias, remap_workspace
from aot_workspace import prepare_workspace, _protect_workspace
from check_aot_source_paths import scan_artifact, source_home_uri_count, directory_alias
from xveil_build_support import resolve


CHILD_ENV = "XVEIL_AOT_WORKSPACE_CHILD"
MARKER = ".dart_tool/xveil-aot-workspace.json"
NATIVE_CRATES = {"veil": "veilclient_ffi", "hidden-volume": "hidden_volume_ffi"}


def _run_command(argv, *, cwd, env):
    subprocess.run(argv, cwd=cwd, env=env, check=True)


def artifact_directory(target: str, arch: str | None = None) -> Path:
    arch = arch or ("arm64" if platform.machine().lower() in {"arm64", "aarch64"} else "x64")
    paths = {
        "android": "build/app/outputs/flutter-apk",
        "windows": f"build/windows/{arch}/runner/Release",
        "linux": f"build/linux/{arch}/release/bundle",
        "macos": "build/macos/Build/Products/Release/xveil.app",
        "ios": "build/ios/iphoneos/Runner.app",
    }
    return Path(paths[target])


def check_artifact(source: Path, target: str) -> dict:
    artifact = source / artifact_directory(target)
    if not artifact.is_dir():
        raise ValueError("expected release artifact directory is missing")
    result = _check_paths(artifact)
    if target == "macos":
        _check_macos_native_load(artifact)
        result["native_libraries_loadable"] = True
    return result


def _check_macos_native_load(artifact: Path) -> None:
    # A valid signature and a clean source-path scan do not prove that dyld
    # accepts the native libraries (for example, malformed Rust LINKEDIT).
    # Use a fresh process so loaded SDK symbols cannot leak between builds.
    subprocess.run([sys.executable, str(Path(__file__).with_name("check_macos_native_load.py")),
                    str(artifact)], check=True)


def _check_paths(artifact: Path) -> dict:
    result = scan_artifact(artifact, current_home=str(Path.home()), include_roles=True)
    if result["source_home_uri_occurrences"] or result["current_home_path_occurrences"]:
        # Counts and fixed categories identify the producer without reflecting
        # the protected strings or even artifact-controlled filenames in CI.
        raise ValueError("artifact contains source home paths: " + json.dumps({
            "source_home_uris": result["source_home_uri_occurrences"],
            "current_home_paths": result["current_home_path_occurrences"],
            "roles": result["path_roles"],
        }, sort_keys=True))
    return result


def child_marker(source: Path) -> dict:
    source = source.resolve(strict=True)
    if source_home_uri_count(source.as_uri().encode()):
        raise ValueError("AOT child requires a neutral source workspace")
    file = source / MARKER
    if not file.resolve(strict=True).is_relative_to(source):
        raise ValueError("invalid AOT workspace marker")
    marker = json.loads(file.read_text(encoding="utf-8"))
    if marker.get("schema") != 1 or marker.get("source") != str(source):
        raise ValueError("AOT child source does not match workspace")
    if os.environ.get("CARGO_TARGET_DIR") != marker.get("cargo_target"):
        raise ValueError("AOT child Cargo target does not match workspace")
    cargo = Path(marker["cargo_target"]).resolve(strict=True)
    if cargo.parent != source.parent or cargo.name != "cargo-target":
        raise ValueError("AOT child Cargo target must belong to this workspace")
    versions = marker.get("native_versions")
    if not isinstance(versions, dict) or not all(isinstance(versions.get(name), str) for name in (
            "XVEIL_VEIL_VERSION", "XVEIL_HV_VERSION")):
        raise ValueError("AOT native source versions are missing")
    return marker


def _stage_native(source: Path, staged: Path, workspace: Path, environment: dict) -> Path:
    target = workspace / "cargo-target"
    target.mkdir()
    for directory, crate in NATIVE_CRATES.items():
        local = source / "third_party" / directory / "target"
        configured = Path(environment.get("CARGO_TARGET_DIR") or str(local))
        if not configured.is_absolute():
            configured = source / configured
        for original in dict.fromkeys([configured, local]):
            if not original.is_dir():
                continue
            profiles = [original / "release", *original.glob("*/release")]
            for profile in profiles:
                if not profile.is_dir():
                    continue
                for name in (f"lib{crate}.so", f"lib{crate}.dylib", f"lib{crate}.a",
                             f"{crate}.dll", f"{crate}.lib", f"{crate}.dll.lib"):
                    file = profile / name
                    if file.is_file():
                        output = target / profile.relative_to(original) / name
                        output.parent.mkdir(parents=True, exist_ok=True)
                        # A configured target wins over the conventional fallback.
                        if not output.exists():
                            shutil.copy2(file, output)
        alias = staged / "third_party" / directory / "target"
        alias.parent.mkdir(parents=True, exist_ok=True)
        _directory_alias(alias, target)
    return target


def _publish_directory(artifact: Path, destination: Path, *, target: str | None = None) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or (destination.exists() and directory_alias(destination)):
        raise ValueError("artifact destination must not be an alias")
    if destination.exists() and not destination.is_dir():
        raise ValueError("artifact destination must be a directory")
    partial = Path(tempfile.mkdtemp(prefix=".xveil-aot-publish-", dir=destination.parent))
    backup = destination.with_name(".xveil-aot-previous-" + uuid.uuid4().hex)
    moved = False
    try:
        shutil.copytree(artifact, partial, symlinks=True, dirs_exist_ok=True)
        if os.name == "nt":
            # An elevated Windows token can give mkdtemp's mode-0700 directory
            # an Administrators-only ACL. Explicitly grant the actual user SID
            # (also in its non-elevated token) before publishing the artifact.
            _protect_workspace(partial)
        # Check the copied bytes and link portability before replacing an old
        # artifact. An absolute link back into the workspace would break when
        # that workspace is removed, even if it passed the source-side scan.
        _check_paths(partial)
        if target == "macos":
            _check_macos_native_load(partial)
        if destination.exists():
            destination.rename(backup)
            moved = True
        try:
            partial.rename(destination)
        except BaseException:
            if moved:
                backup.rename(destination)
            raise
    finally:
        if partial.exists():
            shutil.rmtree(partial)
    if moved:
        shutil.rmtree(backup)


def _preserve_symbols(staged: Path, source: Path, target: str) -> Path | None:
    if target not in {"macos", "ios"}:
        return None
    sidecars = sorted((staged / "build" / target).rglob("*.dSYM"))
    sidecars = [p for p in sidecars if p.is_dir() and not any(a in p.parents for a in sidecars if a != p)]
    if not sidecars:
        return None
    base = source / "build/private-symbols" / target
    base.mkdir(parents=True, exist_ok=True)
    result = Path(tempfile.mkdtemp(prefix="aot-", dir=base))
    try:
        _protect_workspace(result)
        for sidecar in sidecars:
            shutil.copytree(sidecar, result / sidecar.relative_to(staged / "build" / target), symlinks=True)
    except BaseException:
        shutil.rmtree(result)
        raise
    return result


def run_neutral_build(source: Path, target: str, *, native_versions: dict,
                      workspace_base: Path | None = None) -> dict:
    source = source.resolve(strict=True)
    prepared = prepare_workspace(source, workspace_base)
    workspace, staged = Path(prepared["workspace"]), Path(prepared["source"])
    symbols = None
    published = False
    started = time.monotonic()

    def phase(name: str) -> None:
        # Fixed labels and elapsed time only: build logs must not disclose
        # source paths while still identifying a stalled producer.
        print(f"neutral AOT: {name} ({time.monotonic() - started:.1f}s)", flush=True)

    try:
        phase("stage native outputs")
        environment = dict(os.environ)
        cargo = _stage_native(source, staged, workspace, environment)
        environment.update(CARGO_TARGET_DIR=str(cargo),
                           XVEIL_PACKET_TUNNEL_TARGET_BASE=str(workspace / "packet-tunnel-target"))
        if os.name != "nt":
            environment["TMPDIR"] = "/private/tmp/" if Path("/private/tmp").is_dir() else "/tmp/"
        phase("locked package setup")
        _run_command([resolve("flutter"), "pub", "get", "--enforce-lockfile"],
                     cwd=staged, env=environment)
        phase("map package roots")
        remap_workspace(source, staged, workspace / "deps")
        marker = {"schema": 1, "source": str(staged.resolve()), "cargo_target": str(cargo),
                  "input_sha256": prepared["input_sha256"], "native_versions": native_versions}
        (staged / MARKER).write_text(json.dumps(marker), encoding="utf-8")
        environment[CHILD_ENV] = "1"
        environment["XVEIL_AOT_PACKAGE_ROOTS_READY"] = "1"
        for name in ("XVEIL_VEIL_VERSION", "XVEIL_HV_VERSION"):
            environment[name] = native_versions[name]
        phase("build staged application")
        _run_command([sys.executable, str(staged / "builder.py"), target, "--release"],
                     cwd=staged, env=environment)
        phase("verify staged artifact")
        result = check_artifact(staged, target)
        symbols = _preserve_symbols(staged, source, target)
        phase("export verified artifact")
        _publish_directory(staged / artifact_directory(target), source / artifact_directory(target),
                           target=target)
        published = True
        return {"input_sha256": prepared["input_sha256"], "privacy": result,
                "private_symbols_saved": symbols is not None}
    finally:
        if not published and symbols is not None:
            shutil.rmtree(symbols)
        shutil.rmtree(workspace)
