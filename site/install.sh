#!/bin/bash
# Installs the latest release of Sandboxes into /Applications.
#
#   curl -fsSL https://geofflamrock.github.io/Sandboxes/install.sh | bash
#
# Running it again updates an existing install. Downloading with curl doesn't
# set macOS's quarantine flag, so the app opens without the Gatekeeper prompt
# that a browser download gets.
#
# The DMG name must match what .github/workflows/build.yml attaches to a
# release: tag v1.2.3 gives Sandboxes-1.2.3.dmg.

set -euo pipefail

# Everything runs from main, called on the last line, so a partly downloaded
# script does nothing.
main() {
  local repo="geofflamrock/Sandboxes"
  local app="/Applications/Sandboxes.app"

  if [ "$(uname -s)" != Darwin ]; then
    fail "Sandboxes is a macOS app."
  fi
  local major
  major=$(sw_vers -productVersion | cut -d. -f1)
  if [ "$major" -lt 26 ]; then
    fail "Sandboxes needs macOS 26 or later. This Mac has macOS $(sw_vers -productVersion)."
  fi

  # The latest release page redirects to the release's tag, which avoids the
  # API's rate limit and parsing JSON without jq.
  local tag
  tag=$(curl -fsSI "https://github.com/$repo/releases/latest" \
    | awk -F/ 'tolower($1) ~ /^location:/ { print $NF }' \
    | tr -d '\r')
  if [ -z "$tag" ] || [ "$tag" = latest ] || [ "$tag" = releases ]; then
    fail "Couldn't find the latest release of Sandboxes."
  fi
  local version="${tag#v}"
  local url="https://github.com/$repo/releases/download/$tag/Sandboxes-$version.dmg"

  tmp=$(mktemp -d)
  trap cleanup EXIT

  echo "Downloading Sandboxes $tag…"
  curl -fL --progress-bar -o "$tmp/Sandboxes.dmg" "$url"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$tmp/mnt" "$tmp/Sandboxes.dmg"
  if [ ! -d "$tmp/mnt/Sandboxes.app" ]; then
    fail "The download doesn't contain Sandboxes.app."
  fi

  # Replacing the app while it runs would leave the old version running.
  if pgrep -xq Sandboxes; then
    echo "Quitting Sandboxes…"
    osascript -e 'quit app "Sandboxes"' || true
    local i
    for i in $(seq 1 20); do
      pgrep -xq Sandboxes || break
      sleep 0.5
    done
  fi

  # Admin users can write to /Applications; others need sudo.
  local sudo=""
  if [ ! -w /Applications ] || { [ -e "$app" ] && [ ! -w "$app" ]; }; then
    echo "Your password is needed to install into /Applications."
    sudo="sudo"
  fi
  $sudo rm -rf "$app"
  $sudo ditto "$tmp/mnt/Sandboxes.app" "$app"

  echo "Installed Sandboxes $tag in /Applications."
  echo "Open it from Applications, or run: open -a Sandboxes"
}

tmp=""

cleanup() {
  if [ -n "$tmp" ]; then
    hdiutil detach -quiet "$tmp/mnt" 2>/dev/null || true
    rm -rf "$tmp"
  fi
}

fail() {
  echo "Error: $1" >&2
  exit 1
}

main "$@"
