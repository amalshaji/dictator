#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 VERSION SHA256" >&2
  exit 2
fi

version=$1
sha256=$2

cat <<EOF
cask "dictator" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/amalshaji/dictator/releases/download/v#{version}/Dictator-#{version}-universal.dmg"
  name "Dictator"
  desc "Bring-your-own-key dictation with configurable speech providers"
  homepage "https://github.com/amalshaji/dictator"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Dictator.app"

  postflight do
    system "/usr/bin/xattr", "-dr", "com.apple.quarantine", "#{appdir}/Dictator.app"
  end

  zap trash: [
    "~/Library/Application Support/Dictator",
    "~/Library/Caches/ai.dictator.app",
    "~/Library/Preferences/ai.dictator.app.plist",
    "~/Library/Saved Application State/ai.dictator.app.savedState",
  ]
end
EOF
