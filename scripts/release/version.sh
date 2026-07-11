#!/bin/bash
set -euo pipefail

spec=${1:-project.yml}
version=$(awk '/^[[:space:]]+MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "$spec")

if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid or missing MARKETING_VERSION in $spec: ${version:-<empty>}" >&2
  exit 1
fi

printf '%s\n' "$version"
