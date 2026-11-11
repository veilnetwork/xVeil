#!/usr/bin/env python3
"""Materialize a private, neutral source workspace before Flutter pub/build.

Copies source/platform inputs and staged native libraries, never existing build
caches or Git metadata. Does not compile or publish artifacts. Pair with
aot_package_roots after locked pub setup, then verify the resulting artifact.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from aot_package_roots import _ps_literal
from check_aot_source_paths import source_home_uri_count, directory_alias


SOURCE_TREES = (
    "lib", "assets", "android", "ios", "linux", "macos", "windows", "native", "scripts",
    "third_party/veil", "third_party/hidden-volume",
)
ROOT_FILES = (
    "pubspec.yaml", "pubspec.lock", "pubspec_overrides.yaml", "l10n.yaml",
    "analysis_options.yaml", ".metadata", "builder.py", "prepare.py",
)
CACHE_DIRECTORIES = frozenset({
    ".git", ".dart_tool", "build", "target", ".gradle", ".cxx", "Pods",
    ".symlinks", "ephemeral", "xcuserdata", "node_modules", "__pycache__", ".codegraph", "graphify-out",
})
MAX_SOURCE_BYTES = 4 * 1024**3


def _walk_error(error):
    raise error


def _file_digest(path: Path) -> bytes:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.digest()


def _input_files(source: Path):
    for name in ROOT_FILES:
        path = source / name
        if path.exists():
            yield path
    for name in SOURCE_TREES:
        tree = source / name
        if not tree.exists():
            continue
        if directory_alias(tree):
            raise ValueError("source tree must be materialized")
        for directory, directories, filenames in os.walk(tree, followlinks=False,
                                                         onerror=_walk_error):
            base = Path(directory)
            directories.sort()
            for child in list(directories):
                path = base / child
                # An old Cargo cache exists at this exact nonstandard location.
                cargo_cache = base == source / "third_party/veil" and child in {"debug", "release"}
                if child in CACHE_DIRECTORIES or cargo_cache:
                    directories.remove(child)
                elif directory_alias(path):
                    raise ValueError("source directory alias requires explicit materialization")
            for child in sorted(filenames):
                if child != ".git" and child != ".DS_Store":
                    yield base / child


def _protect_workspace(path: Path) -> None:
    if os.name != "nt":
        path.chmod(0o700)
        return
    # Protect before copying signing keys or local network configuration.
    command = (
        "$ErrorActionPreference='Stop'; $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User; "
        "$acl=[Security.AccessControl.DirectorySecurity]::new(); $acl.SetOwner($sid); "
        "$acl.SetAccessRuleProtection($true,$false); "
        "$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new("
        "$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')); "
        "Set-Acl -LiteralPath " + _ps_literal(str(path)) + " -AclObject $acl"
    )
    encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
    result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive",
                             "-EncodedCommand", encoded], capture_output=True)
    if result.returncode:
        raise OSError("workspace access protection failed")


def prepare_workspace(source: Path, base: Path | None = None, *,
                      byte_limit: int = MAX_SOURCE_BYTES) -> dict:
    """Return a new workspace and an exact content fingerprint of its inputs.

    The caller owns successful workspaces and decides their retention. Failed
    workspaces are removed. No hard links: builds cannot mutate original inputs.
    """
    source = source.resolve(strict=True)
    if not (source / "pubspec.yaml").is_file() or byte_limit <= 0:
        raise ValueError("invalid source workspace or copy budget")
    if base is None:
        base = Path(os.environ["ProgramData"]) if os.name == "nt" else Path(
            "/private/tmp" if Path("/private/tmp").is_dir() else "/tmp")
    base = base.resolve(strict=True)
    if source_home_uri_count(base.as_uri().encode()) or base.is_relative_to(source):
        raise ValueError("workspace base must be neutral and outside source")
    workspace = Path(tempfile.mkdtemp(prefix="xveil-aot-", dir=base))
    try:
        _protect_workspace(workspace)
        staged = workspace / "source"
        staged.mkdir()
        total = count = 0
        digest = hashlib.sha256()
        for path in _input_files(source):
            relative = path.relative_to(source)
            if not path.is_file():
                raise ValueError("source input is not a regular file")
            if total + path.stat().st_size > byte_limit:
                raise ValueError("source workspace copy budget exceeded")
            output = staged / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, output, follow_symlinks=True)
            total += output.stat().st_size
            if total > byte_limit:
                raise ValueError("source workspace copy budget exceeded")
            payload_digest = _file_digest(output)
            if payload_digest != _file_digest(path):
                raise ValueError("source changed while materializing workspace")
            digest.update(relative.as_posix().encode() + b"\0")
            digest.update(payload_digest)
            count += 1
        return {"workspace": str(workspace), "source": str(staged), "files": count,
                "bytes": total, "input_sha256": digest.hexdigest()}
    except BaseException:
        shutil.rmtree(workspace)
        raise


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-project", type=Path, required=True)
    parser.add_argument("--workspace-base", type=Path)
    args = parser.parse_args(argv)
    try:
        result = prepare_workspace(args.source_project, args.workspace_base)
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        print(json.dumps({"complete": False, "error_type": type(error).__name__}))
        return 2
    print(json.dumps({"complete": True, **result}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
