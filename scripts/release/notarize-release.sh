#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 ASSET_DIR VERSION" >&2
  exit 2
fi

for variable in \
  APPLE_ID \
  APPLE_APP_SPECIFIC_PASSWORD \
  APPLE_SIGNING_IDENTITY \
  APPLE_TEAM_ID; do
  if [[ -z ${!variable:-} ]]; then
    echo "$variable must be set" >&2
    exit 1
  fi
done

asset_dir=$1
version=$2
dmg="$asset_dir/Dictator-${version}-universal.dmg"
test -f "$dmg"

codesign \
  --force \
  --timestamp \
  --sign "$APPLE_SIGNING_IDENTITY" \
  "$dmg"
codesign --verify --strict --verbose=2 "$dmg"

submission=$(
  xcrun notarytool submit "$dmg" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait \
    --timeout 30m \
    --output-format json
)
if ! jq -e '.status == "Accepted"' >/dev/null <<<"$submission"; then
  jq -r '"Notarization failed: \(.status) (submission \(.id // "unknown"))"' \
    <<<"$submission" >&2
  submission_id=$(jq -r '.id // empty' <<<"$submission")
  if [[ -n $submission_id ]]; then
    xcrun notarytool log "$submission_id" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" >&2 || true
  fi
  exit 1
fi

xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=2 \
  "$dmg"
hdiutil verify "$dmg"

(
  cd "$asset_dir"
  shasum -a 256 "$(basename "$dmg")" > SHA256SUMS.txt
)
