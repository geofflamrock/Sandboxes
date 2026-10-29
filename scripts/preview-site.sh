#!/usr/bin/env bash
# Previews the website at http://localhost:8000 (or the port given).
#
# Assembles _site/ the way .github/workflows/pages.yml does, but with symlinks
# instead of copies, so edits to site/ and the icon SVGs in Design/ show up
# without running this again. With Node installed, it serves _site/ with
# Browsersync, which reloads the page when a file changes. Otherwise it falls
# back to Python's web server, and you reload yourself.
#
# The release button isn't filled in, so it says "Latest release".

set -euo pipefail

port="${1:-8000}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/_site"

rm -rf "$out"
mkdir "$out"
for path in "$root"/site/* "$root/Design/AppIcon.svg" "$root/Design/AppIconArtwork.svg"; do
  ln -s "$path" "$out/"
done

if command -v npx >/dev/null; then
  echo "Serving _site/ at http://localhost:$port, reloading when files change. Press Ctrl-C to stop."
  exec npx --yes browser-sync@3 start --server "$out" --files "$out" \
    --port "$port" --listen localhost --no-open --no-notify --no-ui --logLevel silent
else
  echo "Serving _site/ at http://localhost:$port. Install Node for live reload. Press Ctrl-C to stop."
  exec python3 -m http.server "$port" --bind 127.0.0.1 --directory "$out"
fi
