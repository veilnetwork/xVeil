#!/usr/bin/env python3
"""Get every native dependency this host can have, and say what it cannot.

    ./fetch-deps.py [target] [--with-translate] [--dry-run]

`target` defaults to this machine's own system and may be android, linux,
windows, macos or ios.

Three native pieces are not in the checkout and each arrives differently — the
WebRTC call engine as a prebuilt from CI, whisper.cpp as a pinned upstream
checkout, CTranslate2 and SentencePiece as two out-of-repo source trees. Until
this existed, a newcomer found that out by reading a CI workflow and four shell
scripts, and the cost of missing one is invisible: the app builds, starts,
looks healthy, and has no voice messages.

`./prepare.py` runs this for you as its last step, so there is one command to
learn rather than two. This one exists for the times you want only the
dependencies — after an expired pin, on a machine whose toolchains are already
in place, or in CI.

What it will NOT do: build CTranslate2 or SentencePiece, which is hours; move a
submodule, which is pinned at a release tag; or check out over an existing
whisper.cpp working tree, which can throw away work you have not committed. Any
of those is reported with the exact command instead.

Everything is idempotent. A second run reports what is already satisfied.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts"))

from xveil_build_support import guard, main  # noqa: E402
from xveil_native_deps import plan  # noqa: E402

if __name__ == "__main__":
    guard(
        lambda: main(
            plan,
            "Get every native dependency this host can have.",
            flags=(
                (
                    "--with-translate",
                    "also clone CTranslate2 and SentencePiece (large; not built)",
                ),
            ),
        )
    )
