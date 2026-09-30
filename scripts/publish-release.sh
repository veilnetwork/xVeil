#!/usr/bin/env bash
set -euo pipefail

if (( $# != 4 )); then
  echo "usage: $0 TAG OWNER/REPO NOTES_FILE ARTIFACT_DIR" >&2
  exit 2
fi

tag=$1
repo=$2
notes=$3
artifact_dir=$4
title="xVeil $tag"

[[ -s $notes ]] || { echo "release notes are empty" >&2; exit 1; }
mapfile -d '' files < <(find "$artifact_dir" -type f -print0 | sort -z)
(( ${#files[@]} > 0 )) || { echo "no release artifacts" >&2; exit 1; }

release_exists() {
  gh release view "$tag" --repo "$repo" --json isDraft >/dev/null 2>&1
}

if ! release_exists; then
  for attempt in 1 2 3 4 5; do
    # A create call can return HTTP 500 after GitHub actually created a draft.
    # Check by tag before each retry so we never intentionally create another.
    if release_exists; then break; fi
    if gh release create "$tag" --repo "$repo" --verify-tag --draft \
      --title "$title" --notes-file "$notes"; then
      break
    fi
    sleep "$attempt"
  done
fi
for attempt in 1 2 3 4 5; do
  if release_exists; then break; fi
  sleep "$attempt"
done
release_exists || { echo "could not create or find release $tag" >&2; exit 1; }

asset_size() {
  gh release view "$tag" --repo "$repo" --json assets \
    | jq -r --arg name "$1" '[.assets[] | select(.name == $name) | .size][0] // empty'
}

declare -A seen_names=()
for file in "${files[@]}"; do
  name=${file##*/}
  if [[ -n ${seen_names[$name]:-} ]]; then
    echo "duplicate release asset name: $name" >&2
    exit 1
  fi
  seen_names[$name]=1
  expected=$(wc -c < "$file" | tr -d '[:space:]')
  (( expected > 0 )) || { echo "empty release artifact: $file" >&2; exit 1; }

  for attempt in 1 2 3 4 5; do
    actual=$(asset_size "$name") || actual=
    if [[ $actual == "$expected" ]]; then break; fi
    if [[ -n $actual ]]; then
      sleep "$attempt"
      continue
    fi
    if gh release upload "$tag" "$file" --repo "$repo"; then break; fi
    sleep "$attempt"
  done
  for attempt in 1 2 3 4 5; do
    actual=$(asset_size "$name") || actual=
    if [[ $actual == "$expected" ]]; then break; fi
    sleep "$attempt"
  done
  [[ $actual == "$expected" ]] || {
    echo "asset $name is missing or incomplete: ${actual:-missing}, expected $expected" >&2
    exit 1
  }
  echo "verified $name ($expected bytes)"
done

# Keep the release private until every asset is verified. Retrying edit is
# safe: a 500 can arrive after GitHub has already published it.
for attempt in 1 2 3 4 5; do
  if gh release edit "$tag" --repo "$repo" --draft=false \
    --title "$title" --notes-file "$notes"; then
    break
  fi
  published=$(gh release view "$tag" --repo "$repo" --json isDraft --jq '.isDraft' 2>/dev/null) || published=
  [[ $published == false ]] && break
  sleep "$attempt"
done
for attempt in 1 2 3 4 5; do
  published=$(gh release view "$tag" --repo "$repo" --json isDraft --jq '.isDraft' 2>/dev/null) || published=
  if [[ $published == false ]]; then break; fi
  sleep "$attempt"
done
[[ $published == false ]] || { echo "release $tag is still a draft" >&2; exit 1; }
