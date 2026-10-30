#!/bin/bash
# Installs the latest successful test build of Sandboxes from CI into
# /Applications and opens it.
#
# Usage:
#   scripts/install-test-build.sh          # latest main build
#   scripts/install-test-build.sh main     # same
#   scripts/install-test-build.sh 66       # latest build of PR #66
#
# Needs macOS and the GitHub CLI (gh), signed in.

set -euo pipefail

target=${1:-main}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = Darwin ] || fail "This script installs a macOS app, so it only runs on macOS."
command -v gh >/dev/null || fail "Install the GitHub CLI (brew install gh) and sign in with gh auth login."

# The repo this script is checked out from, so it also works from a fork.
repo=$(cd "$(dirname "$0")" && gh repo view --json nameWithOwner -q .nameWithOwner)

if [ "$target" = main ]; then
  branch=main
  log "Using the main branch of $repo"
else
  [[ "$target" =~ ^[0-9]+$ ]] || fail "Expected a PR number or main, got '$target'."
  log "Looking up PR #$target…"
  branch=$(gh pr view "$target" --repo "$repo" --json headRefName -q .headRefName)
  log "Branch: $branch"
fi

log "Finding the latest successful build…"
run=$(gh run list --repo "$repo" --workflow Build --branch "$branch" --status success --limit 1 --json databaseId -q '.[0].databaseId')
[ -n "$run" ] || fail "No successful build for $branch yet."
size=$(gh api "repos/$repo/actions/runs/$run/artifacts" -q '.artifacts[] | select(.name=="Sandboxes") | .size_in_bytes')
log "Run $run: https://github.com/$repo/actions/runs/$run"

dir=$(mktemp -d)
mnt=
cleanup() {
  [ -n "$mnt" ] && hdiutil detach -quiet "$mnt" || true
  rm -rf "$dir"
}
trap cleanup EXIT

log "Downloading the Sandboxes artifact ($((${size:-0} / 1024 / 1024)) MB)…"
gh run download "$run" --repo "$repo" --name Sandboxes --dir "$dir"
dmg=$(ls "$dir"/*.dmg)
log "Downloaded $(basename "$dmg")"

log "Mounting the disk image…"
mnt=$(hdiutil attach -nobrowse -readonly "$dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')

if pgrep -xq Sandboxes; then
  log "Quitting Sandboxes…"
  osascript -e 'quit app "Sandboxes"'
fi

log "Installing to /Applications…"
rm -rf /Applications/Sandboxes.app
cp -R "$mnt/Sandboxes.app" /Applications/

info=/Applications/Sandboxes.app/Contents/Info
version=$(defaults read "$info" CFBundleShortVersionString)
label=$(defaults read "$info" SandboxesBuildLabel 2>/dev/null || true)
log "Opening Sandboxes $version${label:+ ($label)}"
open /Applications/Sandboxes.app
