#!/usr/bin/env python3
"""Build or refresh a translation file against the English template.

Adding a language is 1751 strings, and doing it by hand in one sitting is how
a file ends up with a dropped key, a reordered map nobody can diff, or a
truncated JSON. This does the mechanical part:

  * every key from the template, IN TEMPLATE ORDER, so two languages diff
    line-for-line against each other and against English;
  * `@key` metadata copied verbatim — gen-l10n reads placeholder types from it,
    and a translation that loses them loses its arguments;
  * anything already translated is KEPT, so this is safe to re-run as the
    template grows;
  * whatever is still untranslated stays English and is listed, so "how far
    along is this language" is a number and not a feeling.

Work in progress belongs OUTSIDE lib/l10n: Flutter falls back per key, so a
half-finished file would quietly ship screens in two languages. Move it in when
`--report` says it is complete — test/arb_translations_test.dart is the gate.

    scripts/l10n_scaffold.py es --out artifacts/l10n-wip/app_es.arb
    scripts/l10n_scaffold.py es --out artifacts/l10n-wip/app_es.arb --report
"""

import argparse
import collections
import json
import pathlib
import sys

TEMPLATE = pathlib.Path("lib/l10n/app_en.arb")

# Strings that are the same in EVERY language — the product's own name.
IDENTICAL = {"appName"}


def same_as_english(out_path):
    """Keys this language deliberately leaves in English.

    Some words simply coincide: "Chats" is already Spanish. Without somewhere
    to say so they count as untranslated forever and the language never reads
    as finished, which makes the progress number useless exactly when it starts
    to matter. Per language, because the coincidence is per language — beside
    the translation, as `<locale>.same.txt`, one key per line.
    """
    beside = out_path.with_suffix(".same.txt")
    if not beside.exists():
        return set()
    with open(beside, encoding="utf-8") as f:
        return {
            line.strip()
            for line in f
            if line.strip() and not line.startswith("#")
        }


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=collections.OrderedDict)


def build(locale, out_path):
    template = load(TEMPLATE)
    existing = load(out_path) if out_path.exists() else {}
    deliberate = IDENTICAL | same_as_english(out_path)

    result = collections.OrderedDict()
    result["@@locale"] = locale

    translated = 0
    todo = []
    for key, value in template.items():
        if key == "@@locale":
            continue
        if key.startswith("@"):
            # Metadata is the template's, always: it types the placeholders and
            # a translator has no reason to touch it.
            result[key] = value
            continue
        prior = existing.get(key)
        if key in deliberate:
            result[key] = value
            translated += 1
            continue
        if isinstance(prior, str) and prior != value:
            result[key] = prior
            translated += 1
        else:
            # Untranslated: keep the English so the file is always valid and
            # always renderable. It counts as untranslated precisely because it
            # still equals the template.
            result[key] = value
            todo.append(key)
    return result, translated, todo


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("locale", help="language tag, e.g. es or zh-Hans")
    ap.add_argument("--out", required=True, help="target .arb path")
    ap.add_argument(
        "--report",
        action="store_true",
        help="print progress and the first untranslated keys; write nothing",
    )
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    result, translated, todo = build(args.locale, out)
    total = translated + len(todo)

    if args.report:
        pct = (translated / total * 100) if total else 0.0
        print(f"{args.locale}: {translated}/{total} translated ({pct:.1f}%)")
        if todo:
            print("next:", ", ".join(todo[:12]))
        # A non-zero exit is what makes this usable from a script: "is this
        # language done?" has to be answerable without reading prose.
        return 0 if not todo else 1

    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"{out}: {total} keys, {translated} translated, {len(todo)} to go")
    return 0


if __name__ == "__main__":
    sys.exit(main())
