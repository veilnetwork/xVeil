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

set -euo pipefail

DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

python3 - "$DEFAULT_BRANCH" <<'PY'
import re
import sys
from pathlib import Path

default = sys.argv[1]
root = Path(".github/workflows")
if not root.is_dir():
    print("run from the repo root: .github/workflows not found", file=sys.stderr)
    sys.exit(2)

lists = []
for path in sorted(root.glob("*.yml")):
    text = path.read_text(encoding="utf-8", errors="replace")
    for match in re.finditer(r"^\s*branches(?:-ignore)?:\s*(.+)$", text, re.M):
        raw = match.group(1)
        # `branches: [a, b]` and the block form that follows on later lines.
        names = re.findall(r"[A-Za-z0-9_./*-]+", raw)
        if not names:
            block = text[match.end():]
            for line in block.splitlines():
                stripped = line.strip()
                if stripped.startswith("- "):
                    names.append(stripped[2:].strip().strip("'\""))
                elif stripped and not stripped.startswith("#"):
                    break
        line_no = text.count("\n", 0, match.start()) + 1
        ignore = "branches-ignore" in match.group(0)
        lists.append((path, line_no, names, ignore))

# Vacuity guard: the checks below pass on an empty list.
if not lists:
    print(
        "no `branches:` lists found under .github/workflows — either the "
        "workflows changed shape or this guard is checking nothing.",
        file=sys.stderr,
    )
    sys.exit(1)

problems = []
targets = [entry for entry in lists if not entry[3]]
for path, line_no, names, _ in lists:
    for name in names:
        if name == "master":
            problems.append(
                f"{path}:{line_no}: names `master`, and the default branch is "
                f"`{default}` — this trigger cannot fire"
            )

if targets and not any(default in names for _, _, names, _ in targets):
    problems.append(
        f"no workflow triggers on `{default}` — nothing here runs on a push to "
        "the branch the work lands on"
    )

if problems:
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    sys.exit(1)

print(f"workflow branch triggers: OK ({len(lists)} list(s), all reachable)")
PY
