#!/usr/bin/env bash
# Build libveil_translate.so for Linux x86_64 and prove it translates.
#
#   native/translate/build_veil_translate_linux.sh [dest_dir]
#
# One file, like every other platform: CTranslate2 and SentencePiece are folded
# in statically, because a translation feature that ships as an engine plus a
# tokeniser plus their transitive halves is three chances to arrive incomplete.
#
# Prereqs, both built where this script expects them:
#   CTranslate2 (static):   CT2_SRC/build-linux-static/libctranslate2.a
#     cmake -DBUILD_SHARED_LIBS=OFF -DWITH_MKL=OFF -DWITH_RUY=ON \
#           -DOPENMP_RUNTIME=NONE -DCMAKE_POSITION_INDEPENDENT_CODE=ON
#   SentencePiece (static): SPM_SRC/build-linux-x64/src/libsentencepiece.a
#     cmake -DSPM_ENABLE_SHARED=OFF -DSPM_BUILD_TEST=OFF \
#           -DSPM_ENABLE_TCMALLOC=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
#
# The default destination is native/translate/linux, which is exactly where
# linux/CMakeLists.txt looks. That guard was written before this script existed
# and is inert until this produces something — the "built, verified and
# unreachable" failure that cost this repository four defects in one week on
# the other platforms.
set -euo pipefail

# Honoured, not assumed. abseil -- which SentencePiece pulls in -- refuses to
# compile on anything below GCC 10, and the distribution default is older than
# that on exactly the long-term releases this is most likely to be built on
# (Ubuntu 20.04 ships 9.4). The dependencies must be built with the same
# compiler, so the choice belongs to whoever builds them, not to this script.
CXX="${CXX:-g++}"
CC="${CC:-gcc}"

SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT2_SRC="${CT2_SRC:-$HOME/Projects/veilnetwork/CTranslate2}"
SPM_SRC="${SPM_SRC:-$HOME/Projects/veilnetwork/sentencepiece}"
CT2_BUILD="${CT2_BUILD:-$CT2_SRC/build-linux-static}"
SPM_BUILD="${SPM_BUILD:-$SPM_SRC/build-linux-x64}"
DEST="${1:-$SRCDIR/linux}"

CT2_LIB="$CT2_BUILD/libctranslate2.a"
SPM_LIB="$SPM_BUILD/src/libsentencepiece.a"
[ -f "$CT2_LIB" ] || { echo "no $CT2_LIB — build CTranslate2 static first" >&2; exit 1; }
[ -f "$SPM_LIB" ] || { echo "no $SPM_LIB — build SentencePiece static first" >&2; exit 1; }

ABSL_INC="$SPM_BUILD/_deps/abseil-cpp-src"
[ -d "$ABSL_INC" ] || { echo "no abseil sources at $ABSL_INC — SentencePiece fetches them at configure time" >&2; exit 1; }

CT2_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$CT2_SRC/python/ctranslate2/version.py" | head -1)"
CT2_VERSION="${CT2_VERSION:-unknown}"
echo "==> ctranslate2 $CT2_VERSION"

SPM_LIBS="$(find "$SPM_BUILD" -name '*.a' ! -name '*train*' ! -name 'libprotoc*' | tr '\n' ' ')"
[ -n "$SPM_LIBS" ] || { echo "no static libraries under $SPM_BUILD" >&2; exit 1; }

# Ruy, cpuinfo and friends are separate archives in a static CTranslate2 build.
# A shared build hides this: linking libctranslate2.a alone fails on
# ruy::Allocator with no hint that the fix is "collect the rest of the tree".
CT2_DEP_LIBS="$(find "$CT2_BUILD" -name '*.a' ! -name 'libctranslate2.a' | tr '\n' ' ')"

mkdir -p "$DEST"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The one place this genuinely differs from macOS, and it is not cosmetic.
#
# ld on Linux puts every symbol from a --whole-archive into the DYNAMIC symbol
# table by default, so all of CTranslate2, SentencePiece, abseil and protobuf
# would be globally visible from this .so. Two libraries in one process that
# each carry their own protobuf then interpose on each other through the global
# namespace, and the failure lands somewhere else entirely — the app links
# veilclient_ffi and veil_media into the same process, so this is a real
# neighbour, not a hypothetical one. Mach-O has two-level namespaces and does
# not have the problem, which is exactly why the macOS script does not mention
# it.
#
# Hidden by default plus the export list below means the .so offers the entry
# points the app looks up and nothing else.

# DERIVED from the header, not hand-written. A list typed here goes stale the
# moment an entry point is added, and the failure is silent in the worst
# direction: the symbol exists in the object, the version script does not name
# it, and the app fails at dlsym on a library that built and linked cleanly. I
# guessed this list once while writing the script and put a `veil_translate_batch`
# in it that does not exist.
grep -oE 'veil_translate[a-z_]*\(' "$SRCDIR/veil_translate.h" \
  | tr -d '(' | sort -u > "$TMP/wanted"
[ -s "$TMP/wanted" ] || { echo "no entry points found in veil_translate.h" >&2; exit 1; }
{
  echo '{'
  echo '  global:'
  sed 's/^/    /; s/$/;/' "$TMP/wanted"
  echo '  local:'
  echo '    *;'
  echo '};'
} > "$TMP/exports.map"

# NOT -fvisibility=hidden. It applies to THIS translation unit and marks the
# entry points hidden in the object file, and a version script cannot promote a
# hidden symbol back: hidden symbols are local before the linker ever reads the
# script, so the .so came out exporting nothing at all. The check below caught
# it -- "built, 8.4 MB, exports 0 entry points" -- which is the whole reason it
# compares sets instead of trusting the build's exit code.
#
# The version script alone does the job anyway: `local: *` makes every symbol
# not named in it local in the output, including the ones inside the static
# archives, which is where the protobuf and abseil collision risk lives.
"$CXX" -std=c++17 -O2 -fPIC \
  -c "$SRCDIR/veil_translate.cc" \
  -I"$SRCDIR" -I"$CT2_SRC/include" -I"$SPM_SRC/src" -I"$SPM_SRC" -I"$ABSL_INC" \
  -DVEIL_TRANSLATE_CT2_VERSION="\"$CT2_VERSION\"" \
  -o "$TMP/veil_translate.o"

"$CXX" -std=c++17 -shared -o "$DEST/libveil_translate.so" \
  "$TMP/veil_translate.o" \
  -Wl,--whole-archive "$CT2_LIB" -Wl,--no-whole-archive \
  `# Grouped, because GNU ld resolves static archives in the order given and` \
  `# takes ONE pass: ruy is referenced by CTranslate2 objects and references` \
  `# abseil back, and any single ordering of two dozen archives leaves some` \
  `# edge pointing backwards. The first attempt failed on ruy::TrMul and a` \
  `# dozen absl symbols that were sitting in archives already on the command` \
  `# line. Apple's linker iterates by default, which is why the macOS script` \
  `# has no equivalent.` \
  -Wl,--start-group $CT2_DEP_LIBS $SPM_LIBS -Wl,--end-group \
  -Wl,--version-script,"$TMP/exports.map" \
  -Wl,-soname,libveil_translate.so \
  -Wl,-z,relro,-z,now \
  -lpthread -ldl -lm

echo "==> $DEST/libveil_translate.so"
ls -la "$DEST/libveil_translate.so"

# What the app will actually be able to reach. `nm -D` reads the DYNAMIC table,
# which is the question dlsym answers -- a symbol present but not exported is
# not there as far as the app is concerned.
nm -D --defined-only "$DEST/libveil_translate.so" \
  | awk '{print $NF}' | { grep '^veil_translate' || true; } | sort -u > "$TMP/exported"
echo "exports $(wc -l < "$TMP/exported" | tr -d ' ') veil_translate_* entry points"

# Set EQUALITY, not a count. A count passes when a symbol the app looks up is
# missing and an unrelated one took its place, which is the shape a rename
# produces.
if ! diff -u "$TMP/wanted" "$TMP/exported" >"$TMP/diff"; then
  echo "::error::the header and the built library disagree about entry points:" >&2
  sed 's/^/  /' "$TMP/diff" >&2
  exit 1
fi

# And what it must NOT reach. A leaked protobuf or abseil symbol is the whole
# reason the version script exists, so the check is here rather than in a
# comment saying it was considered.
leaked="$(nm -D --defined-only "$DEST/libveil_translate.so" \
  | awk '{print $NF}' | grep -cE '^(google|absl|sentencepiece|ctranslate2)' || true)"
if [ "$leaked" -ne 0 ]; then
  echo "::error::$leaked protobuf/abseil/engine symbols are globally visible —" \
       "they can interpose on another library in the same process" >&2
  exit 1
fi

# Built against the finished library, the same way the app uses it: through
# dlopen'able exports rather than the objects.
"$CC" "$SRCDIR/selftest.c" -I"$SRCDIR" -L"$DEST" -lveil_translate \
  -Wl,-rpath,"$DEST" -o "$TMP/selftest"

MODEL="${VEIL_TRANSLATE_TEST_MODEL:-$HOME/Projects/veilnetwork/ct2-model}"
if [ -d "$MODEL" ]; then
  echo "==> selftest against $MODEL"
  "$TMP/selftest" "$MODEL"
else
  echo "==> selftest NOT RUN: no model at $MODEL"
  echo "    set VEIL_TRANSLATE_TEST_MODEL to a CTranslate2 model directory"
  echo "    containing source.spm and target.spm. The library is built but"
  echo "    nothing has checked that it translates."
fi
