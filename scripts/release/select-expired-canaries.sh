#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || ! $1 =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 RETAIN_COUNT" >&2
  exit 2
fi

retain_count=$1
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
rows=$(mktemp)
trap 'rm -f "$rows"' EXIT

while IFS= read -r tag; do
  [[ -z $tag ]] && continue
  if ! metadata=$("$repo_root/scripts/release/release-metadata.sh" from-tag "$tag" true); then
    exit 1
  fi
  IFS=$'\t' read -r channel _ _ build_number _ _ <<<"$metadata"
  [[ $channel == canary ]]
  printf '%020d\t%s\n' "$build_number" "$tag" >> "$rows"
done

sort -t $'\t' -k1,1r "$rows" |
  awk -F $'\t' -v retain_count="$retain_count" \
    'NR > retain_count { print $2 }'
