#!/bin/bash
###############################################################################
# make_release_asset.sh
# =====================
# Builds the three Quectel USB serial modules for the RUNNING kernel and packages
# them into a GitHub release asset named:
#
#     quectel-usb-<uname -r>-<uname -m>.tar.gz
#
# containing option.ko / usb_wwan.ko / qcserial.ko. The installer
# (quectel_auto_install.sh) downloads this asset for the EXACT running kernel,
# so the target machine needs no compiler/toolchain.
#
# The matching source tree is resolved from sources-manifest.txt and either:
#   - reused from sources/<version>/ if present, or
#   - downloaded on demand from SOURCE_REPO (or PREBUILT_REPO).
#
# IMPORTANT: a .ko is tied to one kernel version + architecture + build config.
# Run this script ONCE PER TARGET KERNEL VERSION, then upload the tarball.
#
# Usage:
#   sudo ./make_release_asset.sh                        # for the running kernel
#   sudo ./make_release_asset.sh /path/to/kernel/build  # specific build tree
#
# Upload to: https://github.com/<owner>/<repo>/releases   (tag: quectel-usb-2.0)
###############################################################################
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

KERNELDIR="${1:-/lib/modules/$(uname -r)/build}"
MM="$(uname -r | grep -oE '^[0-9]+\.[0-9]+')"
KPATCH="$(uname -r | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | cut -d. -f3 || true)"
ASSET="quectel-usb-$(uname -r)-$(uname -m).tar.gz"
REPO="${SOURCE_REPO:-${PREBUILT_REPO:-}}"
TAG="${SOURCE_TAG:-${PREBUILT_TAG:-quectel-usb-2.0}}"

# Resolve the source version matching the running kernel from the manifest.
VERSION=""
if [[ -f sources-manifest.txt ]]; then
    grep -qx "v${MM}.${KPATCH}" sources-manifest.txt && VERSION="v${MM}.${KPATCH}" || true
    [[ -z "$VERSION" ]] && grep -qx "v${MM}.1" sources-manifest.txt && VERSION="v${MM}.1" || true
    [[ -z "$VERSION" ]] && VERSION="$(grep -oE "^v${MM}\.[0-9]+" sources-manifest.txt | head -1 || true)"
fi
[[ -n "$VERSION" ]] || { echo "No source version for kernel ${MM} in sources-manifest.txt" >&2; exit 1; }

# Pick a local tree, else download on demand.
SRC=""
for c in "sources/${VERSION}" "${VERSION}" "sources/v${MM}.1" "sources/v${MM}"; do
    [[ -f "$c/Makefile" ]] && { SRC="$c"; break; }
done
if [[ -z "$SRC" ]]; then
    [[ -n "$REPO" ]] || { echo "No local source tree and no SOURCE_REPO set." >&2; exit 1; }
    url="https://github.com/${REPO}/releases/download/${TAG}/quectel-src-${VERSION}.tar.gz"
    echo "[*] Downloading $url"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/src.tar.gz" "$url" || { echo "download failed" >&2; exit 1; }
    mkdir -p "sources/${VERSION}"
    tar -C "sources/${VERSION}" -xzf "$tmp/src.tar.gz"
    rm -rf "$tmp"
    SRC="sources/${VERSION}"
fi

[[ -d "$KERNELDIR" ]] || { echo "Kernel build dir not found: $KERNELDIR" >&2; exit 1; }

echo "[*] Building modules from $SRC against $KERNELDIR"
make -C "$SRC" KERNELDIR="$KERNELDIR" modules

echo "[*] Packaging $ASSET"
tar -C "$SRC/drivers/usb/serial" -czf "$ASSET" option.ko usb_wwan.ko qcserial.ko

echo "[OK] Created $ASSET"
echo "     Upload it to: https://github.com/<owner>/<repo>/releases (tag: quectel-usb-2.0)"
