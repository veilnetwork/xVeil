"""The three native dependencies that are not in the checkout, and how to get them.

`prepare.py` brings a machine to the point where it HAS the toolchains. It does
not bring it to the point where it has everything the app WANTS, because three
native pieces live outside git and each arrives by a different route:

  * libveil_media  — the WebRTC call engine. A prebuilt. This repository cannot
    build it (a from-source WebRTC checkout is hours and ~33 GB), so it is
    downloaded from CI.
  * whisper.cpp    — speech-to-text. An upstream checkout at a pinned revision,
    which the four native/whisper/build_veil_whisper_*.sh scripts compile
    against and REFUSE to build off any other commit.
  * CTranslate2 + SentencePiece — translation. Two out-of-repo checkouts that
    have to be built with specific cmake flags before the wrapper can link
    them.

Before this file, a newcomer discovered all of that by reading scripts and a CI
workflow. That is a poor trade for something every contributor needs on day
one, and the cost of getting it wrong is invisible: the app builds, starts,
looks healthy, and has no voice messages.

## What this will and will not do

It downloads what is small and reports what is large, which is the same line
prepare.py already draws. The engine is 2.4 MB and is fetched. whisper.cpp is a
shallow clone of one commit and is fetched. CTranslate2 and SentencePiece are
hours of compilation, so their checkouts are fetched only when asked
(`--with-translate`) and NEITHER is ever built here.

Nothing is silently skipped. Every item ends in the report at the bottom of the
run with what happened and, when it did not arrive, the sentence that says what
the person loses — "calls, voice messages and video notes will be unavailable",
not "engine missing".

## Everything is stdlib

Same rule as the rest of this directory: a bootstrapper that needs
`pip install` first is not a bootstrapper. That is why the workflow is parsed
with a small state machine below rather than with PyYAML.
"""

from __future__ import annotations

import json
import os
import platform
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone

from xveil_build_support import ROOT, Abort, Step, have, host

# The repository CI publishes from. Not derived from `git remote`: a fork's
# remote points at the fork, whose Actions have never run, and the resulting
# 404 would read as an expired pin rather than as "you are asking the wrong
# repository".
UPSTREAM = "veilnetwork/xVeil"
API = "https://api.github.com"

RELEASE_WORKFLOW = os.path.join(ROOT, ".github", "workflows", "release.yml")
WHISPER_PIN_FILE = os.path.join(ROOT, "native", "whisper", "whisper_pin.sh")
WHISPER_REPO = "https://github.com/ggml-org/whisper.cpp"

# What each feature costs when its library is absent. These are the sentences
# the report prints, and they are about the APP rather than about the build,
# because "libveil_media.so not found" tells a newcomer nothing about what they
# have lost.
COST = {
    "engine": (
        "calls, voice messages, video notes, in-chat video and speech-to-text "
        "will be unavailable"
    ),
    "whisper": (
        "the Transcribe affordance stays hidden; nothing else changes"
    ),
    "translate": (
        "no translation affordance appears; nothing else changes"
    ),
}


@dataclass
class Engine:
    """Where a target's prebuilt call engine comes from and where it goes.

    `artifact` is the run-artifact name uploaded by webrtc-linux.yml or
    webrtc-windows.yml. `asset` is what the same binary would be called as a
    Release asset — see the note on ENGINE_RELEASE in `engine_pins()`.

    `host_arch` is the set of host architectures the download is usable on. It
    is None for android, whose engine is a cross-built .so that any host can
    stage into an APK, and the host's own architecture for linux and windows,
    whose engines run on the host itself.

    `arm64` is the same target built for an AARCH64 host. It exists because
    both those targets now publish one — release.yml's `linux:` matrix has an
    `arch: arm64` leg producing libveil_media-linux-arm64.so, and `windows:`
    one producing veil_media-win-arm64.dll — from the SAME job, so both
    architectures sit on the same ENGINE_RELEASE pin. This script used to tell
    an aarch64 host that "the only published engine is x86_64" and that there
    was no route at all, which stopped being true when those legs were added.
    """

    target: str
    artifact: str
    asset: str
    filename: str
    dest: str
    host_arch: tuple[str, ...] | None
    arm64: tuple[str, str] | None = None

    def for_host(self) -> "Engine":
        """This engine as THIS machine has to download it.

        A no-op where the host does not decide the download (android), and
        where this host is the architecture the base entry names.
        """
        if self.host_arch is None or arch() != "aarch64" or self.arm64 is None:
            return self
        artifact, asset = self.arm64
        return replace(
            self, artifact=artifact, asset=asset, host_arch=("aarch64",)
        )


ENGINES = {
    "linux": Engine(
        target="linux",
        artifact="libveil_media-linux-x64",
        asset="libveil_media-linux-x64.so",
        filename="libveil_media.so",
        dest=os.path.join("third_party", "veil", "flutter", "veil_media", "linux"),
        host_arch=("x86_64",),
        arm64=("libveil_media-linux-arm64", "libveil_media-linux-arm64.so"),
    ),
    # One entry per Android ABI the APK ships. The asset name and the jniLibs
    # directory are the same choice written twice, and letting one be picked
    # without the other is how an arm64 library lands in the x86_64 folder —
    # where nothing notices until a device refuses to load it.
    "android": Engine(
        target="android",
        artifact="libveil_media-android-arm64",
        asset="libveil_media-android-arm64.so",
        filename="libveil_media.so",
        dest=os.path.join("android", "app", "src", "main", "jniLibs", "arm64-v8a"),
        host_arch=None,
    ),
    "android-arm": Engine(
        target="android-arm",
        artifact="libveil_media-android-arm",
        asset="libveil_media-android-arm.so",
        filename="libveil_media.so",
        dest=os.path.join("android", "app", "src", "main", "jniLibs", "armeabi-v7a"),
        host_arch=None,
    ),
    "android-x64": Engine(
        target="android-x64",
        artifact="libveil_media-android-x64",
        asset="libveil_media-android-x64.so",
        filename="libveil_media.so",
        dest=os.path.join("android", "app", "src", "main", "jniLibs", "x86_64"),
        host_arch=None,
    ),
    "windows": Engine(
        target="windows",
        artifact="libveil_media-win-x64",
        asset="veil_media-win-x64.dll",
        filename="veil_media.dll",
        dest=os.path.join("third_party", "veil", "flutter", "veil_media", "windows"),
        host_arch=("x86_64",),
        arm64=("libveil_media-win-arm64", "veil_media-win-arm64.dll"),
    ),
}

# WHISPER_SRC's default is not the same on every platform — linux and windows
# look in ~/whisper.cpp, macOS and android in ~/Projects/veilnetwork/whisper.cpp
# — so the clone has to land where the script for THAT TARGET will look, not
# where the script for this host would.
WHISPER_SRC_DEFAULT = {
    "linux": os.path.join("~", "whisper.cpp"),
    "windows": os.path.join("~", "whisper.cpp"),
    "macos": os.path.join("~", "Projects", "veilnetwork", "whisper.cpp"),
    "ios": os.path.join("~", "Projects", "veilnetwork", "whisper.cpp"),
    "android": os.path.join("~", "Projects", "veilnetwork", "whisper.cpp"),
}

TRANSLATE_SRC = (
    ("CT2_SRC", "CTranslate2", "https://github.com/veilnetwork/CTranslate2"),
    ("SPM_SRC", "sentencepiece", "https://github.com/google/sentencepiece"),
)


@dataclass
class Outcome:
    """One dependency's verdict, for the report at the end of the run.

    `cost` is empty when the item arrived. When it did not, it is the sentence
    naming what the person loses — the whole reason this report exists.
    """

    item: str
    got: bool
    detail: str
    cost: str = ""
    hint: list[str] = field(default_factory=list)


OUTCOMES: list[Outcome] = []


def degrade(item: str, cost: str):
    """Turn a refusal raised deep in a fetch into an entry in the report.

    Abort subclasses SystemExit, and SystemExit is a BaseException — so
    `run()`'s `except Exception` does NOT catch one, and an Abort raised inside
    a step marked `optional` would end the whole run instead of costing that
    one dependency. Every existing Abort in prepare.py happens to sit in a
    required step, so nothing had exercised that gap before these steps
    existed.

    The helpers keep raising Abort, because their messages are worth writing in
    the place that knows what went wrong. This catches them at the one boundary
    where "optional" starts meaning something.
    """

    def wrap(work):
        def run_one() -> None:
            try:
                work()
            except Abort as abort:
                OUTCOMES.append(
                    Outcome(item=item, got=False, detail=abort.message, cost=cost)
                )
            except Exception as error:  # noqa: BLE001 — one item, not the run
                OUTCOMES.append(
                    Outcome(item=item, got=False, detail=f"{type(error).__name__}: {error}", cost=cost)
                )

        return run_one

    return wrap


def arch() -> str:
    """This machine's architecture, in one spelling.

    platform.machine() answers 'arm64' on Apple Silicon, 'aarch64' on Linux
    ARM and 'AMD64' on Windows for the same two families. Comparing those
    against a hard-coded 'x86_64' silently mis-answers on Windows.
    """
    raw = platform.machine().lower()
    if raw in ("amd64", "x86_64", "x64"):
        return "x86_64"
    if raw in ("arm64", "aarch64"):
        return "aarch64"
    return raw


# ---------------------------------------------------------------- the pins ---


def _parse_workflow_env(path: str, key: str) -> dict[str, str]:
    """Every `<key>: value` in release.yml, keyed by the job that carries it.

    Read out of the workflow rather than copied here. A second copy of a pin is
    one more thing to update and forget, and this repository has paid for that
    with a stale prebuilt more than once — which is exactly why
    native/whisper/whisper_pin.sh exists as ONE file that four build scripts
    source.

    A three-line state machine rather than PyYAML, because this whole directory
    is stdlib-only. It tracks the two-space `  jobname:` headers and attributes
    each match to the job it appeared under; a match above the first job header
    lands under 'workflow', which is where the top-level `env:` block sits.
    """
    if not os.path.isfile(path):
        raise Abort(
            f"{path} is missing, so the pinned CI run cannot be read.\n"
            "    Every route to the call engine goes through that pin. If this "
            "checkout is incomplete, re-clone it."
        )
    found: dict[str, str] = {}
    job = "workflow"
    job_header = re.compile(r"^ {2}([A-Za-z0-9_-]+):\s*$")
    entry = re.compile(rf"^\s*{re.escape(key)}:\s*'?\"?([^'\"\s#]+)'?\"?")
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            header = job_header.match(line)
            if header:
                job = header.group(1)
                continue
            match = entry.match(line)
            if match:
                found[job] = match.group(1)
    return found


def engine_pins() -> tuple[dict[str, str], dict[str, str]]:
    """(run ids, release tags) per target, as release.yml pins them.

    `ENGINE_RUN` is what exists today: a GitHub Actions run id, whose artifacts
    expire — see `artifact_state()`. `ENGINE_RELEASE` is the durable
    replacement and is read the same way, so moving the engine onto Release
    assets is a workflow edit and needs no change here: a target that has an
    ENGINE_RELEASE takes the release route, which neither expires nor needs a
    token, and a target that has only ENGINE_RUN keeps the old one.
    """
    runs = _parse_workflow_env(RELEASE_WORKFLOW, "ENGINE_RUN")
    releases = _parse_workflow_env(RELEASE_WORKFLOW, "ENGINE_RELEASE")
    return runs, releases


def whisper_pin() -> str:
    """WHISPER_PIN, from the one file that four build scripts already source.

    Also checked against release.yml's WHISPER_COMMIT. Those are two copies of
    the same fact in two files, and a checkout cloned to one while the CI builds
    the other is a difference nobody would notice until two machines produced
    different engines from the same commit of xVeil — the precise drift
    whisper_pin.sh was written to stop.
    """
    if not os.path.isfile(WHISPER_PIN_FILE):
        raise Abort(f"no {WHISPER_PIN_FILE} — this checkout is incomplete")
    pin = ""
    with open(WHISPER_PIN_FILE, encoding="utf-8") as handle:
        for line in handle:
            match = re.match(r'^WHISPER_PIN="([0-9a-f]{40})"', line.strip())
            if match:
                pin = match.group(1)
                break
    if not pin:
        raise Abort(f"no WHISPER_PIN= line in {WHISPER_PIN_FILE}")
    workflow = _parse_workflow_env(RELEASE_WORKFLOW, "WHISPER_COMMIT").get("workflow")
    if workflow and workflow != pin:
        print(
            f"    warning: whisper_pin.sh pins {pin} but release.yml's\n"
            f"    WHISPER_COMMIT is {workflow}. Two copies of one fact have\n"
            "    drifted; CI and this machine will build different engines.",
            file=sys.stderr,
        )
    return pin


# --------------------------------------------------------------- the token ---


def github_token() -> tuple[str, str] | tuple[None, None]:
    """A token and where it came from, or (None, None).

    Checked EARLY and reported, because the alternative is a 404 halfway
    through a run that has already done work. `gh` is used only as a place a
    token may be sitting — never as the downloader — so a machine with a token
    in the environment and no `gh` installed at all is fully supported. That is
    not hypothetical: the aarch64 Linux box this was tested on has no `gh`.
    """
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return value, f"${name}"
    if have("gh"):
        try:
            result = subprocess.run(
                ["gh", "auth", "token"],
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
            token = result.stdout.strip()
            if result.returncode == 0 and token:
                return token, "gh auth token"
        except Exception:  # noqa: BLE001 — absence is an answer, not a crash
            pass
    return None, None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Stop at the 302 instead of following it.

    The artifact zip endpoint answers 302 to a signed blob URL that carries its
    own credentials in the query string. urllib forwards the Authorization
    header across the redirect, and the storage backend rejects a request with
    two authentication mechanisms — so following the redirect turns a valid
    token into an opaque 400. The redirect is taken by hand below, without the
    header.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        return None


def _get(url: str, token: str | None, *, accept: str = "application/vnd.github+json"):
    request = urllib.request.Request(url, headers={"Accept": accept})
    request.add_header("User-Agent", "xveil-fetch-deps")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    return urllib.request.urlopen(request, timeout=60)


def api_json(path: str, token: str | None = None) -> tuple[int, object]:
    """GET a JSON endpoint, returning (status, body) instead of raising.

    A 404 and a 403 are ANSWERS here — "that run is not in this repository" and
    "the unauthenticated rate limit is spent" — and each needs a different
    sentence. Raising would collapse them into one traceback.
    """
    try:
        with _get(f"{API}/{path}", token) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.loads(error.read().decode("utf-8"))
        except Exception:  # noqa: BLE001
            return error.code, {}
    except urllib.error.URLError as error:
        raise Abort(f"cannot reach {API}: {error.reason}") from None


# -------------------------------------------------------------- the engine ---


def artifact_state(run_id: str, name: str, token: str | None) -> tuple[str, dict]:
    """What the pinned run can still give us, asked WITHOUT a token.

    The artifact LIST endpoint is public on a public repository — verified by
    fetching it with no credentials — while the zip download is 401. That
    split is what makes a good expiry message possible: the state of the pin
    can be established for free, before any auth is demanded, so an expired pin
    is reported as an expired pin rather than as a permissions problem.

    Returns one of:
      ok       — present, not expired; `info` carries size and expires_at
      expired  — the retention window closed; `info` carries expires_at
      absent   — the run exists and never uploaded that artifact
      no-run   — no such run in this repository
      limited  — the unauthenticated rate limit is spent
      error    — anything else, with the API's own message
    """
    status, body = api_json(f"repos/{UPSTREAM}/actions/runs/{run_id}/artifacts", token)
    if status == 404:
        return "no-run", {}
    if status == 401:
        # Only reachable WITH a token, because this endpoint is public without
        # one. So a 401 here is never "you need to log in" — it is "the
        # credential you already have is dead", which is the opposite advice
        # and the difference between a five-second fix and a confused hour.
        return "bad-token", {"message": (body or {}).get("message", "")}
    if status == 403:
        return "limited", {"message": (body or {}).get("message", "")}
    if status != 200 or not isinstance(body, dict):
        return "error", {"status": status, "message": (body or {}).get("message", "")}
    for artifact in body.get("artifacts", []):
        if artifact.get("name") != name:
            continue
        if artifact.get("expired"):
            return "expired", artifact
        return "ok", artifact
    # GitHub deletes the record itself once retention lapses, so a name that is
    # simply not in the list is the SAME event as expired:true — just observed
    # later. Reporting them differently would send someone hunting for a typo.
    return ("absent" if body.get("total_count") else "expired"), {
        "total_count": body.get("total_count", 0)
    }


def _days_left(stamp: str) -> int | None:
    try:
        when = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None
    return (when - datetime.now(timezone.utc)).days


def _expired_message(engine: Engine, run_id: str, state: str, info: dict) -> list[str]:
    """The expired-pin outcome, said in full.

    This WILL happen — the pins in release.yml today lapse on 2026-11-10 — so
    it is a first-class outcome with its own paragraph, not an exception that
    escapes as a stack trace. There is no way to recover an artifact from an
    expired run, and saying that plainly saves the reader from looking.
    """
    if state == "no-run":
        return [
            f"run {run_id} does not exist in {UPSTREAM}.",
            "    The pin in .github/workflows/release.yml is wrong, or it names",
            "    a run in a different repository (a fork's Actions are its own).",
        ]
    if state == "absent":
        return [
            f"run {run_id} exists but has no artifact called {engine.artifact}.",
            f"    It uploaded {info.get('total_count', 0)} artifact(s) under other",
            "    names — the run probably failed before that job, or the pin",
            "    names the wrong workflow.",
        ]
    if state == "limited":
        return [
            "GitHub's unauthenticated API rate limit is spent (60/hour per IP).",
            "    Set GH_TOKEN and re-run; the limit is 5000/hour with one.",
        ]
    if state == "bad-token":
        source = "GH_TOKEN" if os.environ.get("GH_TOKEN") else (
            "GITHUB_TOKEN" if os.environ.get("GITHUB_TOKEN") else "gh auth token"
        )
        return [
            f"GitHub rejected the token from {source}: "
            f"{info.get('message') or 'Bad credentials'}.",
            "    This step reads fine WITHOUT a token, so the token is not",
            "    merely insufficient — it is expired, revoked or mistyped.",
            "",
            "    Either fix it or take it out of the way:",
            f"      unset {source}" if source.startswith("G") else "      gh auth login",
            "    A token is still needed for the download itself; only the",
            "    check above works unauthenticated.",
        ]
    if state == "error":
        return [
            f"the artifact API answered {info.get('status')}: "
            f"{info.get('message') or 'no message'}."
        ]
    workflow = "webrtc-windows" if engine.target == "windows" else "webrtc-linux"
    return [
        f"the artifact {engine.artifact} from run {run_id} HAS EXPIRED.",
        "    GitHub deletes run artifacts after its retention window and there",
        "    is no way to recover one. This is expected — it is the known cost",
        "    of pinning a run id — and not a broken checkout.",
        "",
        "    Three ways out, cheapest first:",
        f"      1. Ask someone who already has {engine.filename} for a copy, and",
        f"         put it in {engine.dest}/.",
        f"      2. Re-run the {workflow} workflow from the Actions tab (about",
        "         3-5 hours), then set ENGINE_RUN in",
        "         .github/workflows/release.yml to the new run id.",
        "      3. Build it from a WebRTC checkout yourself — hours and ~33 GB.",
        f"         {workflow}.yml is the worked example.",
        "",
        "    Whoever does 2 should also attach the result to a GitHub RELEASE:",
        "    release assets neither expire nor need a token, which retires this",
        "    failure permanently. See BUILDING.md, 'Why the pins expire'.",
    ]


def _download_release_asset(tag: str, engine: Engine, into: str) -> str:
    """The durable route: a Release asset, unauthenticated.

    Release assets on a public repository are served without credentials and
    are never garbage-collected. Both facts were checked against this
    organisation's live releases rather than assumed.
    """
    status, body = api_json(f"repos/{UPSTREAM}/releases/tags/{tag}")
    if status != 200 or not isinstance(body, dict):
        raise Abort(
            f"no release tagged {tag} in {UPSTREAM} (API said {status}).\n"
            "    ENGINE_RELEASE in release.yml names a release that is not "
            "there."
        )
    for asset in body.get("assets", []):
        if asset.get("name") != engine.asset:
            continue
        target = os.path.join(into, engine.filename)
        os.makedirs(into, exist_ok=True)
        partial = target + ".part"
        with _get(asset["browser_download_url"], None, accept="*/*") as response:
            with open(partial, "wb") as handle:
                shutil.copyfileobj(response, handle)
        os.replace(partial, target)
        return target
    names = ", ".join(a.get("name", "?") for a in body.get("assets", [])) or "none"
    raise Abort(
        f"release {tag} has no asset called {engine.asset}.\n"
        f"    It carries: {names}"
    )


def _download_artifact(artifact_id: int, engine: Engine, into: str, token: str) -> str:
    """The expiring route: a run artifact, which is a zip and needs a token."""
    url = f"{API}/repos/{UPSTREAM}/actions/artifacts/{artifact_id}/zip"
    opener = urllib.request.build_opener(_NoRedirect)
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "xveil-fetch-deps",
        },
    )
    location = None
    try:
        with opener.open(request, timeout=120) as response:
            payload = response.read()
    except urllib.error.HTTPError as error:
        if error.code in (301, 302, 303, 307) and error.headers.get("Location"):
            location = error.headers["Location"]
        elif error.code == 401:
            raise Abort(
                "GitHub refused the token (401). Artifact downloads need a "
                "token with actions:read on this repository; `gh auth login` "
                "or a classic PAT with `repo` both carry it."
            ) from None
        elif error.code == 403:
            raise Abort(
                "GitHub refused the token (403) — it authenticated but is not "
                "allowed to read this repository's Actions artifacts."
            ) from None
        elif error.code == 410:
            # 410 Gone is what the download endpoint answers for an artifact
            # whose retention window has closed — confirmed against a real
            # expired artifact. Reaching it here means the pin lapsed between
            # the state check above and this request, which is a race that only
            # happens on the day it expires; saying "HTTP 410" instead of
            # "expired" would send someone to debug the wrong thing.
            raise Abort(
                "that artifact has EXPIRED (HTTP 410 Gone) — GitHub has "
                "deleted it and it cannot be recovered. Re-run the webrtc "
                "workflow that produces it and re-pin ENGINE_RUN."
            ) from None
        else:
            raise Abort(f"artifact download failed with HTTP {error.code}") from None
    if location is not None:
        # No Authorization on the redirect: the signed URL carries its own.
        with _get(location, None, accept="*/*") as response:
            payload = response.read()

    os.makedirs(into, exist_ok=True)
    staging = os.path.join(into, ".engine.zip")
    with open(staging, "wb") as handle:
        handle.write(payload)
    try:
        with zipfile.ZipFile(staging) as archive:
            members = [n for n in archive.namelist() if n.endswith(engine.filename)]
            if not members:
                raise Abort(
                    f"the artifact zip has no {engine.filename} in it — it "
                    f"holds {', '.join(archive.namelist()) or 'nothing'}"
                )
            with archive.open(members[0]) as source:
                target = os.path.join(into, engine.filename)
                partial = target + ".part"
                with open(partial, "wb") as handle:
                    shutil.copyfileobj(source, handle)
                os.replace(partial, target)
    finally:
        try:
            os.remove(staging)
        except OSError:
            pass
    return target


def _check_symbols(path: str) -> tuple[bool, str, list[str]]:
    """Ask scripts/check-media-symbols.sh whether this engine is the right one.

    Returns (usable, summary, detail). An engine that is merely PRESENT is not
    what the report should call "have": the copy this repository shipped before
    that script existed was twelve commits behind, linked, bundled and failed
    at dlsym on the first call. A stale engine is a WORSE outcome than an
    absent one, because an absent one is noticed at build time — so it is
    reported as a gap rather than as a success with a caveat.
    """
    checker = os.path.join(ROOT, "scripts", "check-media-symbols.sh")
    if not os.path.isfile(checker):
        return True, "present (no symbol checker in this checkout)", []
    result = subprocess.run(
        ["bash", checker, path], cwd=ROOT, capture_output=True, text=True, check=False
    )
    lines = (result.stdout + result.stderr).strip().splitlines()
    tail = lines[-1].strip() if lines else ""
    if result.returncode == 0:
        return True, f"verified — {tail}", []
    if result.returncode == 2:
        # "this host has no tool to read that format" is the operator's problem
        # and is NOT the same as a stale engine. The script goes out of its way
        # to keep those apart; collapsing them here would undo that.
        return True, "present, but NOT checked on this host", [
            "The symbol checker could not read the file on this machine:",
            f"  {tail}",
            "That is a missing tool, not a bad engine. The library is left in",
            "place unchecked; run scripts/check-media-symbols.sh on a host that",
            "can read that format before trusting it.",
        ]
    return False, "PRESENT BUT STALE — it is missing symbols the app calls", (
        [
            "The engine on disk is not the one this checkout expects. It will",
            "link, bundle and start, and then fail at dlsym the first time",
            "someone makes a call — which is a far worse place to find out.",
            "",
        ]
        + [f"  {line.strip()}" for line in lines[-8:] if line.strip()]
        + ["", "Delete it and re-run this to fetch the pinned one:"]
    )


def fetch_engine(target: str) -> None:
    """Stage the call engine for `target`, or say precisely why it cannot be."""
    engine = ENGINES.get(target)
    if engine is None:
        OUTCOMES.append(
            Outcome(
                item=f"call engine ({target})",
                got=False,
                detail="no published prebuilt exists for Apple platforms",
                cost=COST["engine"],
                hint=[
                    "Neither webrtc workflow builds a macOS or iOS engine, so",
                    "there is nothing to download. The only route is from a",
                    "WebRTC checkout that has already been built with gn/ninja:",
                ]
                + (
                    [
                        "  WEBRTC_ROOT=~/webrtc-checkout \\",
                        "    third_party/veil/flutter/veil_media/ios/"
                        "build_veil_media_ios.sh [--sim]",
                        "(scripts/build-mobile.sh ios calls that for you). It also",
                        "needs depot_tools beside the checkout, and exits at once",
                        "without it.",
                    ]
                    if target == "ios"
                    else [
                        "  WEBRTC_SRC=~/webrtc-checkout/src WEBRTC_OUT=out/mac-arm64 \\",
                        "    third_party/veil/flutter/veil_media/macos/"
                        "build_veil_media_dylib.sh",
                    ]
                )
                + [
                    "That checkout is hours of compilation and ~33 GB; this",
                    "repository does not automate it. See BUILDING.md,",
                    "'Call media engine (WebRTC)'.",
                ],
            )
        )
        return

    # Which build of it THIS machine needs, before anything is named to the
    # user. The engine runs on the host for linux and windows, so an aarch64
    # box and an x86-64 box want different files from the same pin.
    engine = engine.for_host()

    destination = os.path.join(ROOT, engine.dest)
    existing = os.path.join(destination, engine.filename)
    if os.path.isfile(existing):
        usable, summary, detail = _check_symbols(existing)
        OUTCOMES.append(
            Outcome(
                item=f"call engine ({target})",
                got=usable,
                detail=f"at {engine.dest}/{engine.filename} — {summary}",
                cost="" if usable else COST["engine"],
                hint=detail + ([f"  rm {os.path.join(engine.dest, engine.filename)}"]
                               if not usable else []),
            )
        )
        return

    if engine.host_arch is not None and arch() not in engine.host_arch:
        # A host nobody publishes for. This used to be reached by every aarch64
        # machine, with a paragraph explaining that no route existed — written
        # when that was true, and left standing after release.yml grew an
        # `arch: arm64` leg for both linux and windows. `for_host()` above now
        # answers those two; what is left here is a genuinely unpublished host.
        OUTCOMES.append(
            Outcome(
                item=f"call engine ({target})",
                got=False,
                detail=(
                    f"this host is {arch()} and the published {target} engines "
                    f"are {'/'.join(engine.host_arch)}"
                    + (" and aarch64" if engine.arm64 is not None else "")
                ),
                cost=COST["engine"],
                hint=[
                    f"No {target} engine is published for a {arch()} host. The",
                    "engine runs on the host for this target, so a build for",
                    "another architecture is of no use here.",
                    "",
                    "What that costs, concretely: unless your checkout has made",
                    "a missing engine non-fatal, `flutter build` stops at CMake",
                    "configure. Everything else here still works.",
                    "",
                    "Building one needs a WebRTC checkout on a host gn accepts;",
                    "webrtc-linux.yml and webrtc-windows.yml are what CI runs.",
                ],
            )
        )
        return

    runs, releases = engine_pins()
    token, source = github_token()

    tag = releases.get(target) or releases.get("workflow")
    if tag:
        path = _download_release_asset(tag, engine, destination)
        usable, summary, detail = _check_symbols(path)
        OUTCOMES.append(
            Outcome(
                item=f"call engine ({target})",
                got=usable,
                detail=f"from release {tag} (no token needed) — {summary}",
                cost="" if usable else COST["engine"],
                hint=detail,
            )
        )
        return

    run_id = runs.get(target)
    if not run_id:
        OUTCOMES.append(
            Outcome(
                item=f"call engine ({target})",
                got=False,
                detail=f"no ENGINE_RUN pinned for the {target} job in release.yml",
                cost=COST["engine"],
                hint=[
                    "That job has never had an engine pinned to it. Run the",
                    "webrtc workflow that produces "
                    f"{engine.artifact} and set ENGINE_RUN.",
                ],
            )
        )
        return

    state, info = artifact_state(run_id, engine.artifact, token)
    if state != "ok":
        message = _expired_message(engine, run_id, state, info)
        OUTCOMES.append(
            Outcome(
                item=f"call engine ({target})",
                got=False,
                detail=message[0],
                cost=COST["engine"],
                hint=[line.strip() if line.startswith("    ") else line
                      for line in message[1:]],
            )
        )
        return

    left = _days_left(info.get("expires_at", ""))
    if token is None:
        OUTCOMES.append(
            Outcome(
                item=f"call engine ({target})",
                got=False,
                detail=(
                    f"{engine.artifact} is available from run {run_id} "
                    f"({info.get('size_in_bytes', 0)} bytes) but downloading it "
                    "needs a GitHub token"
                ),
                cost=COST["engine"],
                hint=[
                    "A run artifact is not public even on a public repository:",
                    "the API lists it without credentials — which is how the",
                    "line above was established — and answers 401 on the",
                    "download. There is no unauthenticated route.",
                    "",
                    "Any ONE of these is enough:",
                    "  export GH_TOKEN=<a token with actions:read>",
                    "  gh auth login          # then re-run this",
                    "",
                    "`gh` is not otherwise required — it is read only as a place",
                    "a token may already be sitting.",
                ],
            )
        )
        return

    path = _download_artifact(int(info["id"]), engine, destination, token)
    usable, summary, detail = _check_symbols(path)
    line = f"downloaded from run {run_id} via {source} — {summary}"
    hint = list(detail)
    if left is not None:
        line += f"; that pin expires in {left} days"
        # Said on a SUCCESSFUL run, not only on a failed one. The expiry is the
        # durability problem this whole file works around, and the only moment
        # anyone is in a position to fix it cheaply is while it still works.
        if left < 21:
            hint += [
                f"That pin lapses in {left} days. Once it does, this download",
                "stops working for everyone and the only recovery is a 3-5 hour",
                "workflow re-run. Attaching the engine to a GitHub Release",
                "instead would end that cycle — release assets do not expire",
                "and need no token.",
            ]
    OUTCOMES.append(
        Outcome(
            item=f"call engine ({target})",
            got=usable,
            detail=line,
            cost="" if usable else COST["engine"],
            hint=hint,
        )
    )


# ------------------------------------------------------------- whisper.cpp ---


def fetch_whisper(target: str) -> None:
    """A whisper.cpp checkout at the pin, where that target's script will look.

    Fetched as a single commit rather than cloned: the build scripts want one
    revision and refuse every other, so the history is 200 MB nobody reads.

    An existing checkout is never checked out over. `require_whisper_pin`
    refuses rather than moving someone's working tree, for the good reason that
    a build script is not the place to decide whether uncommitted work matters,
    and this follows the same rule — it reports the mismatch and the two ways
    out that whisper_pin.sh itself names.
    """
    pin = whisper_pin()
    src = os.environ.get("WHISPER_SRC") or os.path.expanduser(
        WHISPER_SRC_DEFAULT[target]
    )
    shown = src.replace(os.path.expanduser("~"), "~", 1)

    if os.path.isdir(os.path.join(src, ".git")):
        head = subprocess.run(
            ["git", "-C", src, "rev-parse", "HEAD"],
            capture_output=True, text=True, check=False,
        ).stdout.strip()
        if head == pin:
            OUTCOMES.append(
                Outcome(
                    item="whisper.cpp source",
                    got=True,
                    detail=f"already at the pin in {shown}",
                )
            )
            return
        OUTCOMES.append(
            Outcome(
                item="whisper.cpp source",
                got=False,
                detail=f"{shown} is at {head[:12] or 'an unknown revision'}, "
                f"not the pinned {pin[:12]}",
                cost=COST["whisper"],
                hint=[
                    "Not moved for you: checking out over a working tree can",
                    "throw away uncommitted work, so whisper_pin.sh refuses and",
                    "so does this. Either:",
                    f"  git -C {shown} fetch origin {pin} && \\",
                    f"    git -C {shown} checkout {pin}",
                    "or build from what is there anyway, saying so out loud:",
                    "  WHISPER_ALLOW_UNPINNED=1 "
                    f"native/whisper/build_veil_whisper_{target}.sh",
                    "The second produces an engine whose provenance is not",
                    "recorded, which is the thing the pin exists to prevent.",
                ],
            )
        )
        return

    if os.path.isdir(src) and os.listdir(src):
        OUTCOMES.append(
            Outcome(
                item="whisper.cpp source",
                got=False,
                detail=f"{shown} exists and is not a git checkout",
                cost=COST["whisper"],
                hint=[
                    "Its revision cannot be established, so the build scripts",
                    "will refuse it. Move it aside and re-run, or point",
                    "WHISPER_SRC somewhere else.",
                ],
            )
        )
        return

    os.makedirs(src, exist_ok=True)
    for argv in (
        ["git", "init", "-q", src],
        ["git", "-C", src, "remote", "add", "origin", WHISPER_REPO],
        ["git", "-C", src, "fetch", "-q", "--depth", "1", "origin", pin],
        ["git", "-C", src, "checkout", "-q", "FETCH_HEAD"],
    ):
        result = subprocess.run(argv, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            OUTCOMES.append(
                Outcome(
                    item="whisper.cpp source",
                    got=False,
                    detail=f"{' '.join(argv[:3])} failed: "
                    f"{(result.stderr or '').strip()[:200]}",
                    cost=COST["whisper"],
                    hint=[f"Fetch it by hand into {shown}:",
                          f"  git clone {WHISPER_REPO} {shown}",
                          f"  git -C {shown} checkout {pin}"],
                )
            )
            return
    OUTCOMES.append(
        Outcome(
            item="whisper.cpp source",
            got=True,
            detail=f"fetched {pin[:12]} into {shown} (one commit, no history)",
        )
    )


# --------------------------------------------------------------- translate ---


def fetch_translate(target: str, *, clone: bool) -> None:
    """The two translation checkouts — cloned on request, never built here.

    Building CTranslate2 and SentencePiece is hours of compilation with
    per-platform cmake flags that each build_veil_translate_*.sh script records
    in its own header. Those headers are the reference because they are what
    the script actually checks for, so this does not restate the flags: it
    reports whether the checkouts are there and points at the script that will
    tell you the rest.
    """
    del target
    missing = []
    present = []
    for variable, name, url in TRANSLATE_SRC:
        default = os.path.join(
            "~", name if host() == "Windows" else os.path.join("Projects", "veilnetwork", name)
        )
        src = os.environ.get(variable) or os.path.expanduser(default)
        shown = src.replace(os.path.expanduser("~"), "~", 1)
        if os.path.isdir(os.path.join(src, ".git")):
            present.append(f"{name} at {shown}")
            continue
        if not clone:
            missing.append((variable, name, url, src, shown))
            continue
        result = subprocess.run(
            ["git", "clone", "--depth", "1", url, src],
            capture_output=True, text=True, check=False,
        )
        if result.returncode == 0:
            present.append(f"{name} cloned to {shown}")
        else:
            missing.append((variable, name, url, src, shown))

    if not missing:
        OUTCOMES.append(
            Outcome(
                item="translation checkouts",
                got=True,
                detail="; ".join(present) + " — NEITHER IS BUILT, see the hint",
                hint=[
                    "A checkout is not a library. Each must be built static,",
                    "with the flags in the header of the script that will link",
                    "it, and then:",
                    "  native/translate/build_veil_translate_<platform>.sh",
                    "That build is hours, which is why nothing here starts it.",
                ],
            )
        )
        return

    OUTCOMES.append(
        Outcome(
            item="translation checkouts",
            got=False,
            detail=", ".join(f"no {n}" for _, n, _, _, _ in missing)
            + (f" ({'; '.join(present)} is present)" if present else ""),
            cost=COST["translate"],
            hint=(
                ["Not fetched by default: these are large, and building them is",
                 "hours. Pass --with-translate to clone them, or by hand:"]
                + [f"  git clone {u} {s}" for _, _, u, _, s in missing]
                + ["",
                   "Then build each static — the exact cmake flags are in the",
                   "header of native/translate/build_veil_translate_*.sh for",
                   "your platform, which is where they are kept because that is",
                   "what the script checks for. CT2_SRC, SPM_SRC, CT2_BUILD and",
                   "SPM_BUILD relocate any of it."]
            ),
        )
    )


# ------------------------------------------------------------- the submodules ---


def check_submodules() -> None:
    """The submodules must be populated, and must NOT be moved.

    They are pinned at release tags by the parent repository, and xVeil is only
    tested against those exact commits. So this reports an empty submodule and
    the command that fills it, and never runs anything that could move one.
    """
    empty = []
    for path in (
        os.path.join("third_party", "veil"),
        os.path.join("third_party", "hidden-volume"),
    ):
        full = os.path.join(ROOT, path)
        if not os.path.isdir(full) or not os.listdir(full):
            empty.append(path)
    if empty:
        OUTCOMES.append(
            Outcome(
                item="git submodules",
                got=False,
                detail=f"not populated: {', '.join(empty)}",
                cost="nothing native builds at all — most of the behaviour "
                "lives in those two repositories",
                hint=["  git submodule update --init --recursive",
                      "It checks out the pinned revisions; do not replace them",
                      "with a branch."],
            )
        )
        return
    OUTCOMES.append(
        Outcome(item="git submodules", got=True, detail="populated at the pinned revisions")
    )


# ------------------------------------------------------------------ report ---


def report(target: str) -> None:
    """What this host has, what it does not, and what that costs.

    Printed even when everything succeeded, because "you have all of it" is
    itself the thing a newcomer wants to know and cannot otherwise find out.
    """
    print()
    print(f"  native dependencies for {target} on {host()}/{arch()}")
    print("  " + "-" * 66)
    for outcome in OUTCOMES:
        print(f"  [{'have' if outcome.got else 'MISS'}] {outcome.item}: {outcome.detail}")

    # Every hint, not only the ones attached to a failure. "CTranslate2 is
    # cloned but neither engine is built" is a `have` that still needs the next
    # command said out loud, and printing hints for gaps alone swallowed it.
    print()
    for outcome in OUTCOMES:
        # A gap with no hint still gets its paragraph. Otherwise the one line
        # that says what the person LOSES — the reason this report exists — is
        # dropped for exactly the failures nobody anticipated well enough to
        # write a hint for.
        if outcome.got and not outcome.hint:
            continue
        headline = outcome.cost if (outcome.cost and not outcome.got) else "next"
        print(f"  {outcome.item} — {headline}")
        for line in outcome.hint:
            print(f"      {line}" if line else "")
        print()

    if any(o.item == "git submodules" and not o.got for o in OUTCOMES):
        print("  Fix the submodules before anything else: nothing native builds")
        print("  without them.")
        return
    if all(o.got for o in OUTCOMES):
        print("  Everything this host can have, it has.")
        return

    # What a gap costs the BUILD is per-platform and is not the same as what it
    # costs the app, so it is said separately rather than folded into one
    # reassuring sentence. Only the engine can stop a build; whisper and
    # translate are optional everywhere, by design.
    engine_missing = any(o.item.startswith("call engine") and not o.got for o in OUTCOMES)
    if engine_missing and target in ("linux", "windows"):
        print(f"  Without the engine a {target} build stops at CMake configure,")
        print("  unless this checkout has made that non-fatal. Everything else")
        print("  above is optional: absent, a feature is hidden and nothing else")
        print("  changes.")
    elif engine_missing and target == "ios":
        print("  Without the engine the CocoaPods link fails; builder.py ios")
        print("  refuses earlier with a clearer message. Everything else above")
        print("  is optional.")
    elif engine_missing and target == "android":
        print("  Without the engine a debug APK still builds and throws at the")
        print("  first voice message; builder.py refuses a release build.")
        print("  Everything else above is optional.")
    elif engine_missing:
        print("  A macOS build still succeeds without the engine — the bundling")
        print("  step says it is bundling without calls-media. Everything else")
        print("  above is optional.")
    else:
        print("  Nothing missing above stops a build: each is a feature that")
        print("  stays hidden, and nothing else changes.")


def plan(target: str, *, release: bool = True, with_translate: bool = False) -> list[Step]:
    """The steps, in the order that fails cheapest first.

    Submodules before downloads, and the token check inside the engine step
    rather than after it, so a machine with no credentials learns that before
    the network is touched rather than from a 404 partway through.

    `release` is accepted and ignored: a dependency is the same file either
    way, and taking the argument is what lets this share one entry point with
    prepare.py and builder.py.
    """
    del release
    steps = [Step("git submodules present", call=check_submodules)]
    steps.append(
        Step(
            f"call engine (libveil_media) for {target}",
            call=degrade(f"call engine ({target})", COST["engine"])(
                lambda: fetch_engine(target)
            ),
            optional=True,
        )
    )
    steps.append(
        Step(
            "whisper.cpp at the pinned revision",
            call=degrade("whisper.cpp source", COST["whisper"])(
                lambda: fetch_whisper(target)
            ),
            optional=True,
        )
    )
    steps.append(
        Step(
            "translation checkouts (CTranslate2, SentencePiece)",
            call=degrade("translation checkouts", COST["translate"])(
                lambda: fetch_translate(target, clone=with_translate)
            ),
            optional=True,
        )
    )
    steps.append(Step("what this host has and has not", call=lambda: report(target)))
    return steps
