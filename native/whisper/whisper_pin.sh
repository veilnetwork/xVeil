# The whisper.cpp revision these builds are known good against.
#
# Sourced by all four build_veil_whisper_*.sh scripts, so there is one place to
# change it. A second copy would be one more thing to update and forget, which
# is the drift this repository keeps paying for.
#
# ## Why a pin and not a fork
#
# The call engine pins WebRTC (WEBRTC_PIN) and the translation engine is a
# fork, because upstream CTranslate2 does not support the platforms we need and
# would not answer about it. Neither reason applies here: whisper.cpp supports
# every platform we ship, first-class, and we carry no patches against it. A
# fork with no patches is a maintenance obligation with no payment.
#
# What was genuinely missing is this: nothing recorded WHICH revision the
# prebuilts came from. Every script took whatever happened to be in
# $WHISPER_SRC, so two machines could produce different engines from the same
# commit of xVeil, and neither would say so. That is the same family of defect
# as the stale libveil_media.so and the stale libhidden_volume_ffi.so — a
# prebuilt whose provenance nobody records.
#
# If a patch ever becomes necessary, fork then, and the pin becomes the fork's
# base. Not before.
WHISPER_PIN="7695a5331230c585f5ce92291c4256973985ae5a"

# Refuse to build from an unknown revision. Refuse rather than fix: checking
# out over someone's working tree can throw away work they have not committed,
# and a build script is not the place to make that decision for them.
require_whisper_pin() {
  local src="$1"
  if [ "${WHISPER_ALLOW_UNPINNED:-0}" = "1" ]; then
    echo "==> WHISPER PIN NOT CHECKED (WHISPER_ALLOW_UNPINNED=1)" >&2
    echo "    whatever is in $src will be built and shipped as the engine." >&2
    return 0
  fi
  if [ ! -d "$src/.git" ]; then
    echo "::error::$src is not a git checkout, so its revision cannot be" >&2
    echo "    established. Clone whisper.cpp and check out $WHISPER_PIN, or" >&2
    echo "    set WHISPER_ALLOW_UNPINNED=1 to build from it anyway." >&2
    return 1
  fi
  local head
  head="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ "$head" != "$WHISPER_PIN" ]; then
    echo "::error::whisper.cpp is at $head" >&2
    echo "    but this build is pinned to $WHISPER_PIN." >&2
    echo "    An engine built from an unrecorded revision is a prebuilt nobody" >&2
    echo "    can reproduce. Either:" >&2
    echo "      git -C $src fetch origin $WHISPER_PIN && git -C $src checkout $WHISPER_PIN" >&2
    echo "    or, if you are moving the pin ON PURPOSE, edit WHISPER_PIN in" >&2
    echo "    native/whisper/whisper_pin.sh and say so in the commit." >&2
    return 1
  fi
  echo "==> whisper.cpp at $WHISPER_PIN"
}
