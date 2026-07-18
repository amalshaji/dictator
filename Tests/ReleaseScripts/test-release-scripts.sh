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
  local channel=${5:-stable}
  local duplicate=${6:-false}
  local channel_element=
  local item
  if [[ $channel == canary ]]; then
    channel_element="<sparkle:channel>canary</sparkle:channel>"
  fi
  item="<item><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><sparkle:version>45</sparkle:version>${channel_element}<sparkle:minimumSystemVersion>${minimum}</sparkle:minimumSystemVersion><enclosure url=\"${url}\" length=\"4\" sparkle:edSignature=\"${signature}\" /></item>"
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

write_appcast "$feed" "$url" 14.0 "$signature" stable
actual_signature=$(scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url" stable)
"$sparkle_bin/sign_update" --verify --ed-key-file "$key" "$dmg" "$actual_signature"

write_appcast "$feed" "$url" 14.0 "$signature" canary
scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url" canary >/dev/null
assert_fails scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url" stable

write_appcast "$feed" "$url" 14.0 "$signature" stable
assert_fails scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url" canary

write_appcast "$feed" https://example.com/wrong.dmg 14.0 "$signature" stable
assert_fails scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url" stable

write_appcast "$feed" "$url" 13.0 "$signature" stable
assert_fails scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url" stable

write_appcast "$feed" "$url" 14.0 "" stable
assert_fails scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url" stable

write_appcast "$feed" "$url" 14.0 "$signature" stable true
assert_fails scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url" stable

corrupt_prefix=A
[[ ${signature:0:1} == A ]] && corrupt_prefix=B
corrupt_signature="$corrupt_prefix${signature:1}"
write_appcast "$feed" "$url" 14.0 "$corrupt_signature" stable
structurally_valid=$(scripts/release/validate-appcast.sh "$feed" "$dmg" 1.2.3 45 "$url" stable)
assert_fails "$sparkle_bin/sign_update" --verify --ed-key-file "$key" "$dmg" "$structurally_valid"

write_appcast "$feed" https://example.com/old.dmg 14.0 "$signature" stable
notes="$workspace/notes.md"
printf '# Notes\n' > "$notes"
assert_fails scripts/release/update-appcast.sh \
  "$sparkle_bin" "$workspace" "$dmg" 1.2.3 45 "$url" \
  https://example.com/ https://example.com "$notes" stable < "$key"

write_appcast "$feed" https://example.com/newer.dmg 14.0 "$signature" stable
"$sparkle_bin/sign_update" --ed-key-file "$key" "$feed"
feed_checksum=$(shasum -a 256 "$feed")
scripts/release/update-appcast.sh \
  "$sparkle_bin" "$workspace" "$dmg" 1.2.2 44 "$url" \
  https://example.com/ https://example.com "$notes" stable < "$key"
test "$(shasum -a 256 "$feed")" = "$feed_checksum"

fake_sparkle_bin="$workspace/fake-sparkle"
mkdir -p "$fake_sparkle_bin"
cat > "$fake_sparkle_bin/generate_appcast" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
channel=
download_url_prefix=
output=
archives=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      channel=$2
      shift 2
      ;;
    --download-url-prefix)
      download_url_prefix=$2
      shift 2
      ;;
    -o)
      output=$2
      shift 2
      ;;
    *)
      archives=$1
      shift
      ;;
  esac
done
dmg=$(find "$archives" -maxdepth 1 -name '*.dmg' -print -quit)
channel_element=
if [[ $channel == canary ]]; then
  channel_element="<sparkle:channel>canary</sparkle:channel>"
fi
printf '%s\n' \
  "<?xml version=\"1.0\"?><rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><sparkle:version>45</sparkle:version>${channel_element}<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url=\"${download_url_prefix}$(basename "$dmg")\" length=\"$(stat -f %z "$dmg")\" sparkle:edSignature=\"test-signature\" /></item></channel></rss>" \
  > "$output"
SCRIPT
cat > "$fake_sparkle_bin/sign_update" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
chmod +x "$fake_sparkle_bin/generate_appcast" "$fake_sparkle_bin/sign_update"

for channel in stable canary; do
  generated_feed="$workspace/generated-$channel"
  scripts/release/update-appcast.sh \
    "$fake_sparkle_bin" "$generated_feed" "$dmg" 1.2.3 45 "$url" \
    https://example.com/ https://example.com "$notes" "$channel" < "$key"
done

scripts/release/version-greater-than.sh 1.2.3 1.2.4
scripts/release/version-greater-than.sh 1.2.3 1.3.0
scripts/release/version-greater-than.sh 1.2.3 2.0.0
assert_fails scripts/release/version-greater-than.sh 1.2.3 1.2.3
assert_fails scripts/release/version-greater-than.sh 1.2.3 1.2.2
