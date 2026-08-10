#!/usr/bin/env bash
# Convert one OPUS-MT language pair into the form the app ships, and print the
# catalogue entry that pins it.
#
#   native/translate/convert-model.sh en ru [out_dir]
#
# ## Why convert at all
#
# There are ready-made CTranslate2 conversions on Hugging Face (the `gaudi`
# account has 814 of them), and they can be used directly. But that catalogue
# is not uniform. Surveying the 28 pairs this app would want found 18 complete
# and 10 not — and the pattern is systematic: every "X to English" direction is
# whole, while most "English to X" repositories contain the tokenisers, the
# config and NO model.bin. A 4 MB directory that looks like a model.
#
# en-ru is one of the empty ones, which makes the third-party catalogue
# unusable for a Russian-speaking reader — the direction they need most is the
# one missing. The originals at Helsinki-NLP are complete for every direction
# and licensed Apache-2.0 or CC-BY-4.0, so converting is both possible and
# permitted.
#
# It is also smaller. The published conversions are float16: 153 MB for a 74M
# parameter model. int8 is 78 MB, and the engine quantises to int8 at load
# anyway, so the float16 file costs twice the disk and twice the read for
# arithmetic that gets thrown away.
#
# ## What it prints
#
# The Dart side pins every file's size and SHA-256 (TranslationModelStore).
# Those numbers can only come from an artifact that exists, which is why there
# is no catalogue committed in this repository — a pinned hash for a file
# nobody has produced is a fiction shaped like a check. This script produces
# the artifact and then prints the entry, so the two cannot disagree.
#
# Needs a Python environment with ctranslate2, transformers and torch.
# Set CT2_PYTHON to point at it; ~870 MB of wheels, host-side only, none of it
# ships.
set -euo pipefail

FROM="${1:?usage: $0 <from> <to> [out_dir]}"
TO="${2:?usage: $0 <from> <to> [out_dir]}"
OUT="${3:-$HOME/Projects/veilnetwork/ct2-models/$FROM-$TO}"
PYTHON="${CT2_PYTHON:-}"

if [ -z "$PYTHON" ]; then
  echo "set CT2_PYTHON to a python that has ctranslate2, transformers and torch:" >&2
  echo "  python3 -m venv ~/.ct2env && ~/.ct2env/bin/pip install ctranslate2 transformers torch sentencepiece" >&2
  echo "  CT2_PYTHON=~/.ct2env/bin/python $0 $FROM $TO" >&2
  exit 1
fi
CONVERTER="$(dirname "$PYTHON")/ct2-transformers-converter"
[ -x "$CONVERTER" ] || { echo "no ct2-transformers-converter beside $PYTHON" >&2; exit 1; }

MODEL="Helsinki-NLP/opus-mt-$FROM-$TO"
echo "==> converting $MODEL to int8"

# --copy_files is what makes the result usable on its own. Without the two
# SentencePiece models the engine has weights it cannot feed: it refuses to
# open, which is the good case, and the bad case is a directory assembled from
# two different pairs, which opens and translates into nonsense.
rm -rf "$OUT"
"$CONVERTER" --model "$MODEL" --output_dir "$OUT" \
  --quantization int8 --copy_files source.spm target.spm

for required in model.bin config.json shared_vocabulary.json source.spm target.spm; do
  [ -f "$OUT/$required" ] || { echo "::error::$required missing from $OUT" >&2; exit 1; }
done

echo
echo "==> $OUT"
ls -la "$OUT"

echo
echo "Catalogue entry (real sizes and hashes, from the files just written):"
echo
echo "TranslationModel("
echo "  pair: const TranslationPair('$FROM', '$TO'),"
echo "  baseUrl: '<where these will be published>/$FROM-$TO',"
echo "  files: ["
for f in model.bin config.json shared_vocabulary.json source.spm target.spm; do
  bytes="$(wc -c < "$OUT/$f" | tr -d ' ')"
  hash="$(shasum -a 256 "$OUT/$f" | cut -d' ' -f1)"
  echo "    TranslationModelFile("
  echo "      name: '$f',"
  echo "      bytes: $bytes,"
  echo "      sha256: '$hash',"
  echo "    ),"
done
echo "  ],"
echo ")"
