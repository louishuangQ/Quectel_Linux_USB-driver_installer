#!/bin/bash
###############################################################################
# make_source_assets.sh
# =====================
# Packages each sources/vX.Y.Z/ tree into  quectel-src-vX.Y.Z.tar.gz  for upload
# to a GitHub release, so the lightweight installer can download source on demand.
#
# Usage:
#   ./make_source_assets.sh                      # just build the .tar.gz files
#   ./make_source_assets.sh owner/repo [tag]     # also upload via `gh` CLI
#
# Output: release-assets/quectel-src-vX.Y.Z.tar.gz   (one per kernel version)
#
# Run this BEFORE deleting local sources/ from the repository, then upload the
# assets to: https://github.com/<owner>/<repo>/releases   (tag: quectel-usb-2.0)
###############################################################################
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

OUT="release-assets"
REPO="${1:-}"
TAG="${2:-quectel-usb-2.0}"

[[ -d sources ]] || { echo "sources/ not found (run this before deleting local sources)." >&2; exit 1; }

mkdir -p "$OUT"
count=0
for dir in sources/v*; do
    [[ -d "$dir" ]] || continue
    ver="$(basename "$dir")"
    asset="$OUT/quectel-src-${ver}.tar.gz"
    tar -C "$dir" -czf "$asset" .
    count=$((count+1))
done
echo "[OK] Packaged $count source assets into $OUT/"

if [[ -n "$REPO" ]]; then
    command -v gh >/dev/null 2>&1 || { echo "gh CLI not found; skipping upload." >&2; exit 1; }
    gh release upload "$TAG" "$OUT"/quectel-src-*.tar.gz --repo "$REPO" --clobber
    echo "[OK] Uploaded to $REPO (tag $TAG)"
fi
