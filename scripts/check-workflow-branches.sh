#!/usr/bin/env bash
# A workflow aimed at a branch nobody pushes to is a workflow that never runs.
#
# Not a hypothetical, and not one failure mode but two. In hidden-volume the
# per-push gate named `master` while the default branch was `main`, so it fired
# exactly never. In veil the triggers were REMOVED for an Actions-minutes
# budget that stopped applying the day the repository went public. Here it was
# simpler still: until 2026-08-30 nothing ran on a push at all — `analyze` and
# the test suite lived in the release workflow, so the first thing that ever
# looked at a commit was the tag built from it.
#
# All three look the same from outside: a quiet Actions tab.
#
# THE RULE: every `branches:` list under .github/workflows names the default
# branch, and none of them names `master`.
#
# Usage: invoke from the repo root. Exits non-zero on violations.
# `--self-test` runs the parser against fixtures instead of the tree.

set -euo pipefail

DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

python3 - "$DEFAULT_BRANCH" "$@" <<'PY'
import re
import sys
from pathlib import Path


def branch_lists(text: str):
    """Every `branches:` / `branches-ignore:` list, as (line, names, ignore).

    Parsed line by line rather than with one regex. The first version used
    `^\s*branches:\s*(.+)$` with re.MULTILINE, and `\s` matches a newline — so
    on the block form

        branches:
          - main
          - release

    it consumed the line break and captured `- main`, taking the FIRST item and
    calling that the whole list. `[master, main]` and `[main, master]` then gave
    different verdicts, which is how a wrong list hides behind a right one
    (report19 CI19-L1).
    """
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines):
        match = re.match(r"^[^\S\n]*(branches(?:-ignore)?):[^\S\n]*(.*)$", line)
        if not match:
            continue
        ignore = match.group(1).endswith("-ignore")
        inline = match.group(2).strip()
        names = []
        if inline and not inline.startswith("#"):
            names = re.findall(r"[A-Za-z0-9_./*-]+", inline)
        else:
            indent = len(line) - len(line.lstrip())
            for follower in lines[i + 1:]:
                stripped = follower.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                if (len(follower) - len(follower.lstrip())) <= indent:
                    break
                if not stripped.startswith("- "):
                    break
                names.append(stripped[2:].strip().strip("'\""))
        out.append((i + 1, names, ignore))
    return out


def problems_for(default: str, entries):
    """Everything wrong with these lists, said one line each."""
    found = []
    positives = [entry for entry in entries if not entry[2]]
    for path, line_no, names, ignore in entries:
        if ignore:
            # A negative list NAMES what to skip, so naming a branch here is
            # how you exclude it — `branches-ignore: [main]` is correct and
            # deliberate. Only positive lists are claims about what runs.
            continue
        for name in names:
            if name == "master":
                found.append(
                    f"{path}:{line_no}: names `master`, and the default branch "
                    f"is `{default}` — this trigger cannot fire"
                )
    if positives and not any(default in names for _, _, names, _ in positives):
        found.append(
            f"no workflow triggers on `{default}` — nothing here runs on a "
            "push to the branch the work lands on"
        )
    return found


def _self_test() -> int:
    """Fixtures, because a parser nobody exercises is a guess."""
    inline = "on:\n  push:\n    branches: [main, release]\n"
    block = "on:\n  push:\n    branches:\n      - master\n      - main\n"
    ignore = "on:\n  push:\n    branches-ignore:\n      - main\n"
    cases = [
        ("inline list is read whole", branch_lists(inline)[0][1], ["main", "release"]),
        ("block list is read whole", branch_lists(block)[0][1], ["master", "main"]),
        ("ignore list is marked", branch_lists(ignore)[0][2], True),
    ]
    bad = [(name, got, want) for name, got, want in cases if got != want]
    # Order must not change the verdict, and a right list must not hide a
    # wrong one.
    both = [("f", 1, ["master", "main"], False)]
    reversed_both = [("f", 1, ["main", "master"], False)]
    if not problems_for("main", both) or not problems_for("main", reversed_both):
        bad.append(("`master` is caught whichever way round it is written",
                    "no problem reported", "a problem"))
    if problems_for("main", [("f", 1, ["main"], False)]):
        bad.append(("a correct list is left alone", "a problem", "no problem"))
    if problems_for("main", [("f", 1, ["main"], True)]):
        bad.append(("an ignore list naming main is allowed",
                    "a problem", "no problem"))
    for name, got, want in bad:
        print(f"  {name}: got {got!r}, expected {want!r}", file=sys.stderr)
    if bad:
        print("the workflow-trigger parser is wrong", file=sys.stderr)
        return 1
    print(f"workflow-trigger parser: OK ({len(cases) + 3} fixtures)")
    return 0


default = sys.argv[1] if len(sys.argv) > 1 else "main"
if "--self-test" in sys.argv:
    sys.exit(_self_test())

root = Path(".github/workflows")
if not root.is_dir():
    print("run from the repo root: .github/workflows not found", file=sys.stderr)
    sys.exit(2)

entries = []
for path in sorted(list(root.glob("*.yml")) + list(root.glob("*.yaml"))):
    text = path.read_text(encoding="utf-8", errors="replace")
    for line_no, names, ignore in branch_lists(text):
        entries.append((path, line_no, names, ignore))

# Vacuity guard: the checks below pass on an empty list.
if not entries:
    print(
        "no `branches:` lists found under .github/workflows — either the "
        "workflows changed shape or this guard is checking nothing.",
        file=sys.stderr,
    )
    sys.exit(1)

problems = problems_for(default, entries)
if problems:
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    sys.exit(1)

print(f"workflow branch triggers: OK ({len(entries)} list(s), all reachable)")
PY
