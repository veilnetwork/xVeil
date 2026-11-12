#!/usr/bin/env python3
"""Remap package roots inside an already isolated, neutral AOT workspace.

Run after locked pub setup, before Flutter compilation. Source files and the
original package configuration remain untouched. Package identities, language
versions and dependencies do not change; only compilation source locations do.
This prepares package roots, not a complete release or source-copy workflow.
"""
from __future__ import annotations

import argparse
import base64
from copy import deepcopy
import json
import os
from pathlib import Path
import posixpath
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote, unquote, urljoin, urlsplit, urlunsplit
from urllib.request import url2pathname

from check_aot_source_paths import source_home_uri_count


def _directory_uri(uri: str) -> str:
    parts = urlsplit(uri)
    if parts.scheme != "file" or parts.query or parts.fragment:
        raise ValueError("unsupported package directory URI")
    path = posixpath.normpath(unquote(parts.path).replace("\\", "/"))
    return urlunsplit(("file", parts.netloc, quote(path.rstrip("/") + "/", safe="/:"), "", ""))


def _relative_directory(uri: str, base: str) -> str | None:
    child, root = urlsplit(uri), urlsplit(base)
    if child.netloc.lower() != root.netloc.lower():
        return None
    path, prefix = unquote(child.path), unquote(root.path)
    # File URI drive letters and Windows path components are case-insensitive.
    windows = re.match(r"^/[a-z]:/", prefix, re.IGNORECASE) is not None
    test, boundary = (path.lower(), prefix.lower()) if windows else (path, prefix)
    if not test.startswith(boundary):
        return None
    return path[len(prefix):]


def plan_package_roots(config: dict, *, config_uri: str, source_uri: str,
                       staged_uri: str, aliases_uri: str) -> tuple[dict, list[tuple[str, str]]]:
    """Return a new config and (alias URI, original root URI) pairs.

    URI arithmetic is independent of the host OS so Windows configurations
    can be verified on other hosts as well. No known user names are required.
    """
    source = _directory_uri(source_uri)
    staged = _directory_uri(staged_uri)
    aliases = _directory_uri(aliases_uri)
    for neutral in (staged, aliases):
        if source_home_uri_count(neutral.encode()):
            raise ValueError("workspace is not neutral")
        if (_relative_directory(neutral, source) is not None
                or _relative_directory(source, neutral) is not None):
            raise ValueError("workspace overlaps original source")
    if (not isinstance(config, dict) or config.get("configVersion") != 2
            or not isinstance(config.get("packages"), list)):
        raise ValueError("unsupported package configuration")
    result = deepcopy(config)
    links = []
    seen = set()
    for package in result["packages"]:
        if not isinstance(package, dict):
            raise ValueError("invalid package entry")
        name = package.get("name")
        root = package.get("rootUri")
        if (not isinstance(name, str) or not re.fullmatch(r"[a-zA-Z0-9_]+", name)
                or name in seen or not isinstance(root, str)):
            raise ValueError("invalid package entry")
        seen.add(name)
        origin = _directory_uri(urljoin(config_uri, root))
        alias = urljoin(aliases, name + "/")
        relative = _relative_directory(origin, source)
        if relative is not None:
            mapped = urljoin(staged, quote(relative, safe="/:"))
        elif _relative_directory(origin, staged) is not None or origin == alias:
            mapped = origin
        else:
            mapped = alias
            links.append((alias, origin))
        package["rootUri"] = mapped
    return result, links


def _uri_path(uri: str) -> Path:
    parts = urlsplit(uri)
    if parts.netloc:
        raise ValueError("network package aliases require explicit staging")
    return Path(url2pathname(parts.path))


def _ps_literal(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def _directory_alias(alias: Path, target: Path) -> None:
    if not target.is_dir():
        raise ValueError("package source directory unavailable")
    if alias.exists() or alias.is_symlink():
        if alias.resolve(strict=True) != target.resolve(strict=True):
            raise ValueError("package alias destination already exists")
        return
    alias.parent.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        # Junctions work without enabling Developer Mode. Literal PowerShell
        # arguments do not expand command substitutions or environment syntax.
        command = ("$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path "
                   + _ps_literal(str(alias)) + " -Target " + _ps_literal(str(target))
                   + " | Out-Null")
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive",
                                 "-EncodedCommand", encoded], capture_output=True)
        if result.returncode:
            raise OSError("package alias creation failed")
    else:
        alias.symlink_to(target, target_is_directory=True)


def remap_workspace(source: Path, staged: Path, aliases: Path) -> dict[str, int]:
    """Rewrite only staged/.dart_tool/package_config.json; fail before publish.

    The caller creates/protects the neutral workspace and materializes local
    source roots. External roots are read through directory aliases. Keep the
    original workspace untouched, including when validation or a link fails.
    """
    source = source.resolve(strict=True)
    staged = staged.resolve(strict=True)
    aliases = aliases.resolve(strict=False)
    if staged == source or staged.is_relative_to(source):
        raise ValueError("workspace overlaps original source")
    config_path = staged / ".dart_tool/package_config.json"
    if not config_path.resolve(strict=True).is_relative_to(staged):
        raise ValueError("staged configuration points outside workspace")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    mapped, links = plan_package_roots(
        config, config_uri=config_path.as_uri(), source_uri=source.as_uri() + "/",
        staged_uri=staged.as_uri() + "/", aliases_uri=aliases.absolute().as_uri() + "/")
    for index, (alias, target) in enumerate(links, start=1):
        _directory_alias(_uri_path(alias), _uri_path(target))
        if index % 25 == 0 or index == len(links):
            print(f"neutral AOT: package aliases {index}/{len(links)}", flush=True)
    if not all(_uri_path(p["rootUri"]).is_dir() for p in mapped["packages"]):
        raise ValueError("staged package source directory unavailable")
    # Replacement is atomic; a failed plan/link cannot leave a partial config.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False,
                                         dir=config_path.parent, prefix="package_config.xveil-") as output:
            temporary = Path(output.name)
            json.dump(mapped, output, indent=2)
            output.write("\n")
        temporary.replace(config_path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return {"packages": len(mapped["packages"]), "external_aliases": len(links)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-project", required=True, type=Path)
    parser.add_argument("--staged-project", required=True, type=Path)
    parser.add_argument("--aliases-root", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        result = remap_workspace(args.source_project, args.staged_project, args.aliases_root)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        print(json.dumps({"complete": False, "error_type": type(error).__name__}))
        return 2
    print(json.dumps({"complete": True, **result}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
