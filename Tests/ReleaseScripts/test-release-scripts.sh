#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 SPARKLE_BIN" >&2
  exit 2
fi

sparkle_bin=$1
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT
cd "$repo_root"

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    echo "Expected command to fail: $*" >&2
    exit 1
  fi
}

write_appcast() {
  local path=$1
  local url=$2
  local minimum=$3
  local signature=$4
  local duplicate=${5:-false}
  local item
  item="<item><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><sparkle:version>45</sparkle:version><sparkle:minimumSystemVersion>${minimum}</sparkle:minimumSystemVersion><enclosure url=\"${url}\" length=\"4\" sparkle:edSignature=\"${signature}\" /></item>"
  if [[ $duplicate == true ]]; then
    item+=$item
  fi
  printf '%s\n' \
    "<?xml version=\"1.0\"?><rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>${item}</channel></rss>" \
    > "$path"
}

dmg="$workspace/Dictator-1.2.3-universal.dmg"
key="$workspace/test-private-key"
feed="$workspace/appcast.xml"
url=https://example.com/Dictator-1.2.3-universal.dmg
printf test > "$dmg"
openssl rand -base64 32 > "$key"
signature_output=$("$sparkle_bin/sign_update" --ed-key-file "$key" "$dmg")
signature=$(sed -n 's/.*edSignature="\([^"]*\)".*/\1/p' <<<"$signature_output")
test -n "$signature"

write_appcast "$feed" "$url" 14.0 "$signature"
actual_signature=$(scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url")
"$sparkle_bin/sign_update" --verify --ed-key-file "$key" "$dmg" "$actual_signature"

write_appcast "$feed" https://example.com/wrong.dmg 14.0 "$signature"
assert_fails scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url"

write_appcast "$feed" "$url" 13.0 "$signature"
assert_fails scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url"

write_appcast "$feed" "$url" 14.0 ""
assert_fails scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url"

write_appcast "$feed" "$url" 14.0 "$signature" true
assert_fails scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url"

corrupt_prefix=A
[[ ${signature:0:1} == A ]] && corrupt_prefix=B
corrupt_signature="$corrupt_prefix${signature:1}"
write_appcast "$feed" "$url" 14.0 "$corrupt_signature"
structurally_valid=$(scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url")
assert_fails "$sparkle_bin/sign_update" --verify --ed-key-file "$key" "$dmg" "$structurally_valid"

write_appcast "$feed" https://example.com/old.dmg 14.0 "$signature"
notes="$workspace/notes.md"
printf '# Notes\n' > "$notes"
assert_fails scripts/release/update-appcast.sh \
  "$sparkle_bin" "$workspace" "$dmg" 1.2.3 45 "$url" \
  https://example.com/ https://example.com "$notes" < "$key"

scripts/release/version-greater-than.sh 1.2.3 1.2.4
scripts/release/version-greater-than.sh 1.2.3 1.3.0
scripts/release/version-greater-than.sh 1.2.3 2.0.0
assert_fails scripts/release/version-greater-than.sh 1.2.3 1.2.3
assert_fails scripts/release/version-greater-than.sh 1.2.3 1.2.2
