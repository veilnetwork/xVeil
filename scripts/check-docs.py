#!/usr/bin/env python3
"""Keep the documentation honest about itself.

Three checks, each of which has caught real drift in this tree:

  links   every relative markdown link resolves to something on disk
  index   every document under docs/<lang>/ is named by docs/<lang>/index.md
  parity  every English document has a counterpart in the other language

None of them reads prose. They check the claims a reader can follow — a link,
a table of contents, a translation — because those rot silently and nothing
else notices. On 2026-09-19 a sweep found 46 dead links, two indexes that had
stopped naming a third of their tree, and a Russian document a full version
behind its English half.

Run `--self-test` to prove the checker still fails on a defect: it builds a
fixture tree with one of each and requires all three to be reported.
"""
from __future__ import annotations

import os
import re
import sys
import tempfile
from pathlib import Path

# --- what this repository looks like -------------------------------------
# Tailored per repo; everything below is generic.
CONFIG = {
    # Directories never walked, wherever they appear.
    "skip_dirs": {
        ".git", "build", "target", "node_modules", ".dart_tool",
        "graphify-out", "artifacts", "third_party", "Pods", "ephemeral",
        ".symlinks", "fuzz", "__pycache__",
    },
    # Files whose links are historical and must not be rewritten to keep a
    # linter quiet.
    "skip_files": {"TASKS_ARCHIVE.md"},
    # Link targets that are SUPPOSED not to resolve, each with its reason.
    # A dangling link not listed here fails the gate.
    "allowed_dangling": {},
    # No docs/<lang> tree here: the root documents and doc/ are single-language,
    # and lib/l10n holds app strings, not documentation.
    "index_langs": [],
    "parity_pairs": [],
    "parity_exempt": set(),
}

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
INDEX_LINK_RE = re.compile(r"\(([A-Za-z0-9_./-]+\.md)\)")


def md_files(root: Path, cfg: dict):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in cfg["skip_dirs"]]
        for name in filenames:
            if name.endswith(".md") and name not in cfg["skip_files"]:
                yield Path(dirpath) / name


def check_links(root: Path, cfg: dict) -> list[str]:
    problems = []
    for path in sorted(md_files(root, cfg)):
        rel = path.relative_to(root).as_posix()
        allowed = cfg["allowed_dangling"].get(rel, set())
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            problems.append(f"{rel}: unreadable ({exc})")
            continue
        for match in LINK_RE.finditer(text):
            target = match.group(1)
            if target.startswith(("http://", "https://", "mailto:", "#", "<")):
                continue
            target = target.split("#", 1)[0]
            target = re.sub(r":\d+(?:[-–]\d+)?$", "", target)  # drop :42 anchors
            if not target or target.startswith("$") or "*" in target or "<" in target:
                continue
            if target in allowed:
                continue
            if not (path.parent / target).exists():
                problems.append(f"{rel} -> {target}")
    return problems


def check_index(root: Path, cfg: dict) -> list[str]:
    problems = []
    for lang_dir in cfg["index_langs"]:
        base = root / lang_dir
        index = base / "index.md"
        if not index.exists():
            problems.append(f"{lang_dir}: no index.md")
            continue
        listed = set(INDEX_LINK_RE.findall(index.read_text(encoding="utf-8")))
        actual = {
            p.name for p in base.iterdir()
            if p.is_file() and p.suffix == ".md" and p.name != "index.md"
        }
        for missing in sorted(actual - listed):
            problems.append(f"{lang_dir}/index.md does not name {missing}")
    return problems


def check_parity(root: Path, cfg: dict) -> list[str]:
    problems = []
    for src_dir, dst_dir in cfg["parity_pairs"]:
        src, dst = root / src_dir, root / dst_dir
        if not src.is_dir():
            continue
        for path in sorted(md_files(src, cfg)):
            rel = path.relative_to(src).as_posix()
            if f"{src_dir}/{rel}" in cfg["parity_exempt"]:
                continue
            if not (dst / rel).exists():
                problems.append(f"{src_dir}/{rel} has no {dst_dir} counterpart")
    return problems


CHECKS = (("links", check_links), ("index", check_index), ("parity", check_parity))


def run(root: Path, cfg: dict) -> int:
    failed = 0
    for name, fn in CHECKS:
        problems = fn(root, cfg)
        if problems:
            failed += len(problems)
            print(f"==> {name}: {len(problems)} problem(s)")
            for p in problems:
                print(f"    {p}")
        else:
            print(f"==> {name}: clean")
    if failed:
        print(f"\ndocumentation gate FAILED with {failed} problem(s)")
    return 1 if failed else 0


def self_test() -> int:
    """Plant one defect of each kind; require the checker to report all three."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "docs/en").mkdir(parents=True)
        (root / "docs/ru").mkdir(parents=True)
        # a link that goes nowhere
        (root / "docs/en/broken.md").write_text("see [gone](nowhere.md)\n", encoding="utf-8")
        # a document the index does not name
        (root / "docs/en/orphan.md").write_text("# orphan\n", encoding="utf-8")
        (root / "docs/en/index.md").write_text("- [broken](broken.md)\n", encoding="utf-8")
        # ru counterparts for everything except orphan.md
        for name in ("broken.md", "index.md"):
            (root / "docs/ru" / name).write_text("# ru\n", encoding="utf-8")
        cfg = dict(CONFIG)
        cfg["index_langs"] = ["docs/en"]
        cfg["parity_pairs"] = [("docs/en", "docs/ru")]
        cfg["allowed_dangling"] = {}
        cfg["parity_exempt"] = set()
        found = {name: fn(root, cfg) for name, fn in CHECKS}
        ok = True
        for name in ("links", "index", "parity"):
            if not found[name]:
                print(f"SELF-TEST FAILED: {name} reported nothing on a planted defect")
                ok = False
            else:
                print(f"self-test {name}: caught {found[name][0]}")
        # and it must be quiet on a clean tree
        (root / "docs/en/nowhere.md").write_text("# there\n", encoding="utf-8")
        (root / "docs/ru/nowhere.md").write_text("# ru\n", encoding="utf-8")
        (root / "docs/ru/orphan.md").write_text("# ru\n", encoding="utf-8")
        (root / "docs/en/index.md").write_text(
            "- [broken](broken.md)\n- [orphan](orphan.md)\n- [nowhere](nowhere.md)\n",
            encoding="utf-8",
        )
        residue = {n: fn(root, cfg) for n, fn in CHECKS}
        for name, problems in residue.items():
            if problems:
                print(f"SELF-TEST FAILED: {name} still complains about a clean tree: {problems}")
                ok = False
        if ok:
            print("self-test: the gate catches all three and passes a clean tree")
        return 0 if ok else 1


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        raise SystemExit(self_test())
    raise SystemExit(run(Path(__file__).resolve().parent.parent, CONFIG))
