#!/usr/bin/env bash
# Build veil_whisper.dll for windows-x64: the veil_whisper wrapper statically
# linked against a CPU whisper.cpp. Runs ON a Windows host under Git Bash, with
# the MSVC environment already set (a Developer Command Prompt, or
# `ilammy/msvc-dev-cmd` in CI) — `cl.exe` must be on PATH.
#
# Drop the result next to the Flutter runner, the same place
# veilclient_ffi.dll goes; builder.py's windows target does that staging.
#
# Portability: GGML_NATIVE=OFF plus an explicit AVX/AVX2/FMA/F16C baseline, so
# the artifact runs on any 2013+ x86-64 CPU rather than only on the machine
# that built it. GGML_OPENMP=OFF keeps the runtime free of a libomp
# dependency, matching the Linux and Android builds.
#
# Prereq: a whisper.cpp checkout at WHISPER_SRC (this script configures and
# builds the static CPU libs itself when they are missing):
#   git clone https://github.com/ggml-org/whisper.cpp
#
# Usage: WHISPER_SRC=/c/src/whisper.cpp ./build_veil_whisper_windows.sh [dest]
set -euo pipefail

WHISPER_SRC="${WHISPER_SRC:-$HOME/whisper.cpp}"
BUILD="${WHISPER_BUILD_DIR:-$WHISPER_SRC/build-windows}"
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$SRCDIR/windows}"
mkdir -p "$DEST"

[ -d "$WHISPER_SRC" ] || { echo "no whisper.cpp checkout at $WHISPER_SRC" >&2; exit 1; }
command -v cl.exe >/dev/null 2>&1 || {
  echo "cl.exe not on PATH — run this from a Developer Command Prompt or after msvc-dev-cmd" >&2
  exit 1
}

# Git Bash puts its own /usr/bin first, and Git ships a coreutils `link.exe`
# (the hard-link utility). Anything that resolves a linker through PATH — cmake
# configuring whisper.cpp, or cl.exe's /link — finds that one and fails on an
# "extra operand" complaint that names no compiler. cl.exe has no such twin, so
# its directory is the way back to the real toolchain.
MSVC_BIN="$(dirname "$(command -v cl.exe)")"
export PATH="$MSVC_BIN:$PATH"
if [ "$(dirname "$(command -v link.exe)")" != "$MSVC_BIN" ]; then
  echo "link.exe resolves to $(command -v link.exe), not the MSVC one in $MSVC_BIN" >&2
  exit 1
fi

# cl.exe does not understand /c/src paths. Convert when cygpath is available
# (Git Bash ships it); fall back to the value as-is elsewhere.
win() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }

if [ ! -f "$BUILD/src/Release/whisper.lib" ]; then
  echo "==> building whisper.cpp static CPU libs ($BUILD)"
  cmake -S "$WHISPER_SRC" -B "$BUILD" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON \
    -DGGML_F16C=ON -DGGML_OPENMP=OFF
  cmake --build "$BUILD" --config Release -j
fi

# whisper + the split ggml archives. MSVC resolves an archive set in one pass,
# so ordering does not need the --start-group dance the ELF link uses.
LIBS=()
while IFS= read -r lib; do LIBS+=("$(win "$lib")"); done < <(find "$BUILD" -name '*.lib' 2>/dev/null)
[ "${#LIBS[@]}" -gt 0 ] || { echo "no static libs under $BUILD" >&2; exit 1; }
echo "==> linking with ${#LIBS[@]} archives"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# MSVC ignores `#pragma GCC visibility`, which is what veil_whisper.h uses, so
# without an explicit export list the DLL builds happily and exports NOTHING —
# and the failure only shows up at runtime, as a Dart symbol lookup that finds
# nothing. A .def keeps the export set explicit and leaves the header alone
# for the three platforms where the pragma already works.
cat > "$TMP/veil_whisper.def" <<'DEF'
EXPORTS
veil_whisper_transcribe
veil_whisper_free_string
veil_whisper_version
DEF

cl.exe /nologo /std:c++17 /O2 /EHsc /MD /LD \
  "$(win "$SRCDIR/veil_whisper.cc")" \
  /I"$(win "$WHISPER_SRC/include")" \
  /I"$(win "$WHISPER_SRC/ggml/include")" \
  /Fe:"$(win "$DEST/veil_whisper.dll")" \
  /Fo:"$(win "$TMP/")" \
  /link /DEF:"$(win "$TMP/veil_whisper.def")" "${LIBS[@]}" \
  advapi32.lib

[ -f "$DEST/veil_whisper.dll" ] || { echo "cl.exe produced no dll" >&2; exit 1; }
echo "==> done: $DEST/veil_whisper.dll"

# Prove the three symbols are actually exported. Building a DLL that exports
# nothing is the failure mode this script exists to avoid, and it is silent
# without a check.
if command -v dumpbin.exe >/dev/null 2>&1; then
  n="$(dumpbin.exe /exports "$(win "$DEST/veil_whisper.dll")" | grep -c "veil_whisper_" || true)"
  echo "exported veil_whisper_* symbols: $n"
  [ "$n" -ge 3 ] || { echo "expected 3 exports, found $n" >&2; exit 1; }
fi
