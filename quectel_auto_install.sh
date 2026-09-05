#!/bin/bash
###############################################################################
# quectel_auto_install.sh
# =======================
# One-shot automation: for any Quectel module on any Linux host, converge to
# "设备已就绪" (device ready) — detect the module, and install (pre-built download
# or source compile) + load the Linux USB serial drivers automatically, so the
# user can start dialing without the manual driver-compilation dance.
#
#   - If the environment is already OK  ->  print "设备已就绪" and stop.
#   - Otherwise                          ->  keep installing/loading until ready.
#
# The drivers are the Quectel official per-kernel source trees under sources/
# (v2.6.12 ~ v6.17.1; e.g. sources/v4.15.1, sources/v5.18.5):
#   - option.ko    (Quectel VID/PID table + vendor-wide 2c7c match)
#   - usb_wwan.ko  (shared GSM modem core, Quectel ZLP patch)
#   - qcserial.ko  (Qualcomm/Quectel serial driver)
# The script auto-selects the source tree matching the RUNNING kernel
# (sources/v<major.minor>.1 -> sources/v<major.minor>); it never compiles a
# mismatched tree. They are built OUT-OF-TREE against the running kernel
# headers, then installed over the distro's stock option/usb_wwan/qcserial.
#
# OPERATING MODES:
#   1. --first-time   Full install (manual, run once as root):
#                     check -> download-or-compile -> install -> depmod -> load
#                     -> udev rule -> self-install -> DKMS -> converge to ready.
#   2. --quick-load   Fast path used by the udev rule on every insertion:
#                     pre-built download or modprobe, then converge to ready.
#   3. (default)      Auto: ready? -> report; else quick-load / first-time.
#
# Usage:
#   sudo ./quectel_auto_install.sh --first-time     # one-time manual install
#   sudo ./quectel_auto_install.sh                  # auto mode
#   sudo ./quectel_auto_install.sh --quick-load     # hotplug path (udev)
#   sudo ./quectel_auto_install.sh --dry-run        # print actions only
#   sudo ./quectel_auto_install.sh --kernel /path   # override kernel build dir
#   sudo ./quectel_auto_install.sh --source-dir /path  # override driver source tree
#   sudo ./quectel_auto_install.sh --uninstall      # remove driver + udev + DKMS
#
# Requirements:
#   - Root privileges
#   - For the source-compile path: a matching kernel source tree + headers:
#       Debian/Ubuntu:  sudo apt install linux-headers-$(uname -r)
#       RHEL/CentOS :   sudo dnf install kernel-devel kernel-headers
#   - make, gcc, tar, install (coreutils)
#   - dkms (optional, enables auto-rebuild after a kernel upgrade)
#
# The shipped source trees already carry the Quectel patches from the
# "LTE&5G Linux USB Driver User Guide V2.0": VID/PID table, zero-packet,
# reset-resume, interface-4 network guard, and Ch.5 power management
# (USB auto suspend + remote wakeup).
###############################################################################

set -euo pipefail

# udev runs RUN+ with a restricted PATH; make sure sbin tools are reachable.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ---- Paths & configuration --------------------------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

QUECTEL_VID="2c7c"
QUALCOMM_VID="05c6"                 # UC15/UC20/EC20-MDM9215 use Qualcomm's VID

# Optional pre-built .ko fast path (no compiler needed on the target).
# Set PREBUILT_REPO (or --prebuilt-repo) to a GitHub "owner/repo" whose release
# assets are named  quectel-usb-<uname -r>-<uname -m>.tar.gz  and contain
# option.ko / usb_wwan.ko / qcserial.ko  (see make_release_asset.sh).
# Defaults to this project's source repository; override via env or --prebuilt-repo.
PREBUILT_REPO="${PREBUILT_REPO:-louishuangQ/Quectel_Linux_USB-driver_installer}"
PREBUILT_TAG="${PREBUILT_TAG:-quectel-usb-2.0}"

# On-demand SOURCE download (lightweight mode: sources live on GitHub, not here).
# Source assets are named  quectel-src-<vX.Y.Z>.tar.gz  (see make_source_assets.sh).
# SOURCE_REPO/TAG default to PREBUILT_REPO/TAG (derived after arg parsing) so one
# repo can host both prebuilt .ko and source assets.
SOURCE_REPO="${SOURCE_REPO:-}"
SOURCE_TAG="${SOURCE_TAG:-}"
SOURCE_MANIFEST="${SCRIPT_DIR}/sources-manifest.txt"   # available versions
SOURCE_MANIFEST_INSTALLED="/usr/local/share/quectel-usb/sources-manifest.txt"
SOURCE_CACHE="/var/cache/quectel-usb/sources"          # downloaded source trees

DKMS_MODULE_NAME="quectel-usb"
DKMS_MODULE_VERSION="2.0"
INSTALLED_SRC="/usr/src/${DKMS_MODULE_NAME}-${DKMS_MODULE_VERSION}"
INSTALLED_SCRIPT="/usr/local/bin/quectel_auto_install.sh"
UDEV_RULE_SRC="${SCRIPT_DIR}/99-quectel.rules"
UDEV_RULE_DST="/etc/udev/rules.d/99-quectel.rules"
DKMS_CONF_SRC="${SCRIPT_DIR}/dkms.conf"
LOG_FILE="/var/log/quectel-install.log"
MARKER="/lib/modules/$(uname -r)/extra/quectel-usb-${DKMS_MODULE_VERSION}"

KERNEL_BUILD="/lib/modules/$(uname -r)/build"
KERNEL_BUILD_OVERRIDE=""
MODULE_SRC=""                       # resolved driver source tree (per running kernel)
SOURCE_DIR_OVERRIDE=""              # optional --source-dir override
DETECTED_VID=""
DETECTED_PID=""

DRY_RUN=0
NO_DOWNLOAD=0
MODE="auto"                         # auto | first-time | quick-load | uninstall

# ---- Logging helpers ---------------------------------------------------------
log()  { echo -e "\033[1;34m[*]\033[0m $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" | tee -a "$LOG_FILE" >&2; }

usage() {
    cat <<'EOF'
Usage:
  sudo ./quectel_auto_install.sh --first-time     # one-time manual install (download-or-compile+install+load+udev+DKMS)
  sudo ./quectel_auto_install.sh                  # auto mode
  sudo ./quectel_auto_install.sh --quick-load     # hotplug path (udev): prebuilt download or modprobe only
  sudo ./quectel_auto_install.sh --dry-run        # print actions only
  sudo ./quectel_auto_install.sh --kernel /path   # override kernel build dir
  sudo ./quectel_auto_install.sh --source-dir /path  # override driver source tree
  sudo ./quectel_auto_install.sh --uninstall      # remove driver + udev + DKMS

Pre-built .ko / source download (optional, from a GitHub repo):
  --prebuilt-repo OWNER/REPO   GitHub repo hosting quectel-usb-<uname -r>-<arch>.tar.gz assets
  --prebuilt-tag TAG           release tag (default: quectel-usb-2.0)
  --source-repo OWNER/REPO     repo hosting quectel-src-<vX.Y.Z>.tar.gz (defaults to prebuilt-repo)
  --source-tag TAG             tag for source assets (defaults to prebuilt-tag)
  --no-download                skip downloads, always compile from local source
EOF
}

# ---- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel)
            [[ $# -ge 2 ]] || { err "Missing value for --kernel"; exit 1; }
            KERNEL_BUILD_OVERRIDE="$2"; shift 2 ;;
        --source-dir)
            [[ $# -ge 2 ]] || { err "Missing value for --source-dir"; exit 1; }
            SOURCE_DIR_OVERRIDE="$2"; shift 2 ;;
        --prebuilt-repo)
            [[ $# -ge 2 ]] || { err "Missing value for --prebuilt-repo"; exit 1; }
            PREBUILT_REPO="$2"; shift 2 ;;
        --prebuilt-tag)
            [[ $# -ge 2 ]] || { err "Missing value for --prebuilt-tag"; exit 1; }
            PREBUILT_TAG="$2"; shift 2 ;;
        --source-repo)
            [[ $# -ge 2 ]] || { err "Missing value for --source-repo"; exit 1; }
            SOURCE_REPO="$2"; shift 2 ;;
        --source-tag)
            [[ $# -ge 2 ]] || { err "Missing value for --source-tag"; exit 1; }
            SOURCE_TAG="$2"; shift 2 ;;
        --first-time)  MODE="first-time"; shift ;;
        --quick-load)  MODE="quick-load"; shift ;;
        --uninstall)   MODE="uninstall";  shift ;;
        --dry-run)     DRY_RUN=1;         shift ;;
        --no-download) NO_DOWNLOAD=1;     shift ;;
        -h|--help)     usage; exit 0 ;;
        *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root (use sudo)" >&2
    exit 1
fi

# Let --prebuilt-repo/--prebuilt-tag also drive source downloads unless --source-* given.
[[ -z "$SOURCE_REPO" ]] && SOURCE_REPO="$PREBUILT_REPO"
[[ -z "$SOURCE_TAG" ]] && SOURCE_TAG="$PREBUILT_TAG"

mkdir -p "$(dirname "$LOG_FILE")"
echo "=== $(date) mode=$MODE ===" >> "$LOG_FILE"

# ---- Small helpers -----------------------------------------------------------
is_quectel_vid() {
    [[ "$1" == "$QUECTEL_VID" || "$1" == "$QUALCOMM_VID" ]]
}

# ---- Hardware detection ------------------------------------------------------
detect_module() {
    log "Detecting Quectel module (VID ${QUECTEL_VID} / ${QUALCOMM_VID})..."
    DETECTED_VID=""; DETECTED_PID=""
    if ! command -v lsusb >/dev/null 2>&1; then
        warn "lsusb not available (usbutils not installed); skipping hardware detection."
        return 1
    fi
    local lines entry
    lines=$(lsusb 2>/dev/null | grep -Ei "${QUECTEL_VID}:|${QUALCOMM_VID}:" || true)
    if [[ -z "$lines" ]]; then
        warn "No Quectel module detected on the USB bus."
        return 1
    fi
    entry=$(echo "$lines" | head -1 | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' | head -1)
    DETECTED_VID="${entry%%:*}"
    DETECTED_PID="${entry##*:}"
    ok "Detected Quectel module: VID ${DETECTED_VID}, PID ${DETECTED_PID}"
    return 0
}

# ---- Kernel build directory --------------------------------------------------
locate_kernel_build() {
    [[ -n "$KERNEL_BUILD_OVERRIDE" ]] && KERNEL_BUILD="$KERNEL_BUILD_OVERRIDE"
    if [[ ! -d "$KERNEL_BUILD" ]] || { [[ ! -f "$KERNEL_BUILD/Makefile" && ! -f "$KERNEL_BUILD/Kbuild" ]]; }; then
        err "Kernel build directory not found: $KERNEL_BUILD"
        err "Install headers: sudo apt install linux-headers-\$(uname -r)   (Debian/Ubuntu)"
        err "               : sudo dnf install kernel-devel kernel-headers   (RHEL/CentOS)"
        err "Or pass an override: --kernel /path/to/build"
        return 1
    fi
    ok "Kernel build directory: $KERNEL_BUILD"
    return 0
}

# ---- Driver source tree (version-aware) --------------------------------------
kernel_major_minor() {
    uname -r | grep -oE '^[0-9]+\.[0-9]+' || true
}

# Print the kernel version a source tree targets ("" if unknown).
source_tree_version() {
    local dir="$1" v
    if [[ -f "$dir/KERNEL_VERSION" ]]; then
        v=$(grep -oE '^[0-9]+(\.[0-9]+)*' "$dir/KERNEL_VERSION" 2>/dev/null | head -1 || true)
        [[ -n "$v" ]] && { echo "$v"; return 0; }
    fi
    # Fall back to the directory name if it looks like "vX.Y[.Z]".
    v=$(basename "$dir" | grep -oE '^v[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
    [[ -n "$v" ]] && { echo "$v"; return 0; }
    return 1
}

# True when the source tree's kernel version matches the running kernel (major.minor).
source_matches_kernel() {
    local dir="$1" sv kmm
    sv=$(source_tree_version "$dir" || true)
    kmm=$(kernel_major_minor)
    [[ -n "$sv" && -n "$kmm" && "$sv" == "$kmm" ]]
}

# 在 $1 目录下，从匹配前缀 $2（如 v4.15）的 v* 目录里挑一个源码树：
# 优先精确 patch 匹配（v5.18.5 → 内核 5.18.5），否则基础 .1，再否则第一个。
best_tree() {
    local root="$1" prefix="$2" c best="" base="" kpatch
    for c in "$root"/${prefix}.*; do
        [[ -f "$c/Makefile" ]] || continue
        [[ -z "$best" ]] && best="$c"
        [[ "$(basename "$c")" == "${prefix}.1" ]] && base="$c"
    done
    kpatch=$(uname -r | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | cut -d. -f3 || true)
    if [[ -n "$kpatch" && -f "$root/${prefix}.${kpatch}/Makefile" ]]; then
        echo "$root/${prefix}.${kpatch}"; return 0
    fi
    if [[ -n "$base" ]]; then echo "$base"; else echo "$best"; fi
    return 0
}

resolve_source() {
    local kver kmm root candidate
    kver=$(uname -r)
    kmm=$(kernel_major_minor)

    local roots=()
    [[ -n "$SOURCE_DIR_OVERRIDE" ]] && roots+=("$SOURCE_DIR_OVERRIDE")
    roots+=("${SCRIPT_DIR}/sources" "${SCRIPT_DIR}")

    for root in "${roots[@]}"; do
        [[ -d "$root" ]] || continue

        # 1) 精确完整版本目录（自定义，如 v4.15.0-142-generic）
        candidate="$root/v${kver}"
        if [[ -f "$candidate/Makefile" ]] && source_matches_kernel "$candidate"; then
            MODULE_SRC="$candidate"; ok "驱动源码树: $MODULE_SRC（内核 $(source_tree_version "$candidate")）"; return 0
        fi

        # 2) 精确主.次目录（自定义，如 v4.15）
        candidate="$root/v${kmm}"
        if [[ -f "$candidate/Makefile" ]] && source_matches_kernel "$candidate"; then
            MODULE_SRC="$candidate"; ok "驱动源码树: $MODULE_SRC（内核 $(source_tree_version "$candidate")）"; return 0
        fi

        # 3) Quectel 命名 v<主.次>.*（如 v4.15.1 / v4.15.11），优先 .1 基础版
        candidate="$(best_tree "$root" "v${kmm}")"
        if [[ -n "$candidate" ]]; then
            MODULE_SRC="$candidate"; ok "驱动源码树: $MODULE_SRC（内核 $(source_tree_version "$candidate")）"; return 0
        fi
    done

    # 4) 已暂存到 /usr/src 的源码树
    if [[ -f "$INSTALLED_SRC/Makefile" ]] && source_matches_kernel "$INSTALLED_SRC"; then
        MODULE_SRC="$INSTALLED_SRC"; ok "驱动源码树: $MODULE_SRC（内核 $(source_tree_version "$INSTALLED_SRC")）"; return 0
    fi

    err "未找到与内核 ${kver} 匹配的驱动源码树。"
    err "已查找: ${SCRIPT_DIR}/sources/v${kmm}*、${SCRIPT_DIR}/v${kmm}*、$INSTALLED_SRC"
    err "请放入 ${kmm} 对应的源码树（如 sources/v${kmm}.1/），或用 --source-dir 指定，或用 --prebuilt-repo 走预编译包。"
    return 1
}

get_config() {
    # Print "CONFIG_X=y|m|n" for the given key, from the first readable config.
    local key="$1" cfg
    for cfg in "/lib/modules/$(uname -r)/config" "/boot/config-$(uname -r)"; do
        if [[ -r "$cfg" ]]; then
            grep -oE "^${key}=[ymn]" "$cfg" 2>/dev/null | head -1
            return 0
        fi
    done
    if [[ -r /proc/config.gz ]]; then
        zcat /proc/config.gz 2>/dev/null | grep -oE "^${key}=[ymn]" | head -1
    fi
}

check_kernel_config() {
    log "Checking required kernel features (User Guide Ch.3)..."
    local v
    v=$(get_config CONFIG_USB_SERIAL)
    if [[ "$v" == *"=y" || "$v" == *"=m" ]]; then
        ok "CONFIG_USB_SERIAL is enabled (${v##*=})"
    elif [[ -z "$v" ]]; then
        # No readable config file: fall back to a runtime probe.
        if modinfo usbserial >/dev/null 2>&1 || [[ -d /sys/bus/usb-serial ]]; then
            ok "usb-serial core available (runtime probe)"
        else
            err "usb-serial core not found: CONFIG_USB_SERIAL appears disabled."
            err "option/usb_wwan/qcserial cannot load without it. Enable CONFIG_USB_SERIAL."
            return 1
        fi
    else
        err "CONFIG_USB_SERIAL is disabled (${v}). Enable it in the kernel config."
        return 1
    fi

    v=$(get_config CONFIG_USB_NET_QMI_WWAN)
    if [[ "$v" == *"=y" || "$v" == *"=m" ]]; then
        ok "CONFIG_USB_NET_QMI_WWAN enabled (QMI dial-up available)"
    elif [[ -z "$v" ]]; then
        modinfo qmi_wwan >/dev/null 2>&1 && ok "qmi_wwan module available" \
            || warn "qmi_wwan not found; QMI dial-up may be unavailable."
    else
        warn "CONFIG_USB_NET_QMI_WWAN is disabled; QMI dial-up will not work."
    fi

    command -v pppd >/dev/null 2>&1 \
        || warn "pppd not installed (optional; only needed for PPP dial-up)."
    return 0
}

# ---- Pre-built .ko fast path (download from a GitHub release) ----------------
ko_matches_kernel() {
    # A .ko is only safe to load if its vermagic embeds the running kernel version.
    local ko="$1" v
    v=$(modinfo -F vermagic "$ko" 2>/dev/null || true)
    [[ -n "$v" && "$v" == *"$(uname -r)"* ]]
}

install_prebuilt_kos() {
    local dir="$1" ko missing=0
    log "Installing pre-built modules..."
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  (dry-run) would install option.ko/usb_wwan.ko/qcserial.ko from $dir"
        return 0
    fi
    install -d "/lib/modules/$(uname -r)/kernel/drivers/usb/serial"
    for ko in option usb_wwan qcserial; do
        if [[ ! -f "$dir/$ko.ko" ]]; then
            warn "Missing $ko.ko in pre-built package."
            missing=1; break
        fi
        if ! ko_matches_kernel "$dir/$ko.ko"; then
            warn "$ko.ko vermagic does not match $(uname -r); discarding pre-built."
            missing=1; break
        fi
    done
    [[ $missing -eq 0 ]] || return 1
    for ko in option usb_wwan qcserial; do
        install -m 644 "$dir/$ko.ko" "/lib/modules/$(uname -r)/kernel/drivers/usb/serial/$ko.ko"
    done
    depmod -a 2>/dev/null || true
    mkdir -p "/lib/modules/$(uname -r)/extra"
    : > "$MARKER"
    ok "Pre-built modules installed (no compiler needed)."
    return 0
}

try_download_prebuilt() {
    [[ $NO_DOWNLOAD -eq 0 && -n "$PREBUILT_REPO" ]] || return 1
    local base asset url tmp
    base="https://github.com/${PREBUILT_REPO}/releases/download/${PREBUILT_TAG}"
    asset="quectel-usb-$(uname -r)-$(uname -m).tar.gz"
    url="${base}/${asset}"
    log "Looking for a matching pre-built package: ${asset}"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  (dry-run) would download: $url"
        return 1
    fi
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || { warn "curl/wget not available; skipping pre-built download."; return 1; }
    tmp=$(mktemp -d)
    if curl -fsSL --connect-timeout 8 --max-time 30 -o "$tmp/$asset" "$url" 2>/dev/null \
       || wget -q -T 8 -O "$tmp/$asset" "$url" 2>/dev/null; then
        ok "Downloaded ${asset}"
    else
        warn "No pre-built package for kernel $(uname -r) ($(uname -m)) in ${PREBUILT_REPO}."
        rm -rf "$tmp"
        return 1
    fi
    tar -C "$tmp" -xzf "$tmp/$asset" 2>/dev/null \
        || { warn "Failed to extract ${asset}"; rm -rf "$tmp"; return 1; }
    if install_prebuilt_kos "$tmp"; then
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

# ---- On-demand SOURCE download (lightweight mode) -----------------------------
# Pick the best source version (e.g. "v4.15.1") for the running kernel from the
# manifest; prefer exact patch, then ".1" base, then first match.
resolve_source_version() {
    local manifest="$SOURCE_MANIFEST"
    [[ -f "$manifest" ]] || manifest="$SOURCE_MANIFEST_INSTALLED"
    # 本地无清单时，从仓库拉取（保证「只拷一个脚本」也能用）
    if [[ ! -f "$manifest" && -n "$SOURCE_REPO" ]]; then
        local url fetched
        url="https://raw.githubusercontent.com/${SOURCE_REPO}/main/sources-manifest.txt"
        fetched="/var/cache/quectel-usb/sources-manifest.txt"
        install -d "$(dirname "$fetched")"
        if curl -fsSL --connect-timeout 8 --max-time 20 -o "$fetched" "$url" 2>/dev/null \
           || wget -q -T 8 -O "$fetched" "$url" 2>/dev/null; then
            manifest="$fetched"
            # 注意：不要在此用 log/ok（会污染 $(resolve_source_version) 的 stdout 捕获）
            echo -e "\033[1;32m[OK]\033[0m 已从 ${SOURCE_REPO} 拉取源码清单" | tee -a "$LOG_FILE" >&2
        fi
    fi
    [[ -f "$manifest" ]] || return 1

    local kmm kpatch
    kmm=$(kernel_major_minor)
    kpatch=$(uname -r | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | cut -d. -f3 || true)

    grep -qx "v${kmm}.${kpatch}" "$manifest" 2>/dev/null && { echo "v${kmm}.${kpatch}"; return 0; }
    grep -qx "v${kmm}.1" "$manifest" 2>/dev/null && { echo "v${kmm}.1"; return 0; }
    grep -oE "^v${kmm}\.[0-9]+" "$manifest" 2>/dev/null | head -1
}

# Download the matching source tree tarball and point MODULE_SRC at it.
try_download_source() {
    [[ $NO_DOWNLOAD -eq 0 && -n "$SOURCE_REPO" ]] || return 1
    local version
    version=$(resolve_source_version || true)
    [[ -n "$version" ]] || return 1

    local asset url dest
    asset="quectel-src-${version}.tar.gz"
    url="https://github.com/${SOURCE_REPO}/releases/download/${SOURCE_TAG}/${asset}"
    dest="${SOURCE_CACHE}/${version}"

    # Already downloaded? reuse the cache.
    if [[ -f "$dest/Makefile" ]]; then
        MODULE_SRC="$dest"
        ok "使用已缓存源码树: $dest"
        return 0
    fi

    log "按需下载匹配源码包: ${asset}"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  (dry-run) would download $url -> $dest"
        return 1
    fi
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || { warn "curl/wget not available; skipping source download."; return 1; }

    local tmp
    tmp=$(mktemp -d)
    if curl -fsSL --connect-timeout 8 --max-time 60 -o "$tmp/$asset" "$url" 2>/dev/null \
       || wget -q -T 8 -O "$tmp/$asset" "$url" 2>/dev/null; then
        ok "Downloaded ${asset}"
    else
        warn "未找到源码包 ${asset}（repo=${SOURCE_REPO}, tag=${SOURCE_TAG}）"
        rm -rf "$tmp"
        return 1
    fi
    mkdir -p "$dest"
    tar -C "$dest" -xzf "$tmp/$asset" 2>/dev/null \
        || { warn "Failed to extract ${asset}"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    if [[ ! -f "$dest/Makefile" ]]; then
        warn "源码包 ${asset} 缺少 Makefile，丢弃。"
        rm -rf "$dest"
        return 1
    fi
    MODULE_SRC="$dest"
    ok "源码树已就绪: $dest"
    return 0
}

# ---- State checks ------------------------------------------------------------
is_driver_compiled() {
    # Our own marker is authoritative.
    [[ -f "$MARKER" ]] && return 0
    # Fallback: the Quectel patch adds a vendor-wide 2c7c alias (usb:v2C7Cpd*),
    # which the stock option.ko never carries.
    if command -v modinfo >/dev/null 2>&1; then
        if modinfo -F alias option 2>/dev/null | grep -qiE 'usb:v2C7Cpd\*'; then
            return 0
        fi
    fi
    return 1
}

# ---- Readiness ---------------------------------------------------------------
# "设备已就绪" = 检测到 Quectel 模组，且其串口接口已绑定 option/qcserial，
# 并且 /dev/ttyUSB* 已创建（即用户可开始拨号）。
is_device_ready() {
    local dev vid iflink d
    for dev in /sys/bus/usb/devices/*; do
        [[ -f "$dev/idVendor" ]] || continue
        vid=$(cat "$dev/idVendor" 2>/dev/null || true)
        is_quectel_vid "$vid" || continue
        for iflink in "$dev":*/driver; do
            [[ -L "$iflink" ]] || continue
            d=$(basename "$(readlink "$iflink" 2>/dev/null)" 2>/dev/null)
            case "$d" in
                option|qcserial)
                    ls /dev/ttyUSB* >/dev/null 2>&1 && return 0 ;;
            esac
        done
    done
    return 1
}

# 加载驱动后等待 udev 完成绑定与 ttyUSB* 创建（最多 ~5 s），返回是否就绪。
settle_and_check() {
    local i
    [[ $DRY_RUN -eq 1 ]] && return 1
    for i in 1 2 3 4 5; do
        is_device_ready && return 0
        sleep 1
    done
    return 1
}

show_status() {
    local ttys net
    if [[ -d /sys/bus/usb/drivers/option ]]; then
        ok "  串口驱动 : option（已注册）"
    fi
    ttys=$(ls /dev/ttyUSB* 2>/dev/null | tr '\n' ' ')
    if [[ -n "$ttys" ]]; then
        ok "  串口设备 : ${ttys}"
    fi
    net=$(ip -o link show 2>/dev/null | grep -oE '(wwan|usb)[0-9]+' | head -1 || true)
    if [[ -n "$net" ]]; then
        ok "  网络接口 : ${net}"
    fi
    return 0
}

report_ready() {
    echo ""
    ok "=========================================="
    ok " 设备已就绪 ✅"
    ok "=========================================="
    show_status
    log "下一步拨号： sudo quectel-CM -s <APN> &   (MBIM/QMI)"
    echo ""
}

report_not_ready() {
    local reason="${1:-未知原因}"
    echo ""
    warn "=========================================="
    warn " 设备未就绪 ⚠️"
    warn " 原因：${reason}"
    warn "=========================================="
    echo ""
}

# ---- Build / install ---------------------------------------------------------
build_install_modules() {
    log "Compiling drivers (option, usb_wwan, qcserial)..."
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  (dry-run) would run: make -C $MODULE_SRC KERNELDIR=$KERNEL_BUILD install"
        return 0
    fi
    # Quectel's official Makefile uses `cp ... <dest>/`; ensure the dest dir exists.
    install -d "/lib/modules/$(uname -r)/kernel/drivers/usb/serial"
    if ! make -C "$MODULE_SRC" KERNELDIR="$KERNEL_BUILD" install; then
        err "Compilation failed. Review the build output above."
        return 1
    fi
    depmod -a 2>/dev/null || true
    mkdir -p "/lib/modules/$(uname -r)/extra"
    : > "$MARKER"
    ok "Modules installed to /lib/modules/$(uname -r)/kernel/drivers/usb/serial/"
    ok "Install marker written: $MARKER"
    return 0
}

# ---- Load / reload -----------------------------------------------------------
load_modules() {
    log "Loading driver modules..."
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  (dry-run) would run: modprobe usbserial usb_wwan option qcserial; modprobe qmi_wwan"
        return 0
    fi
    modprobe usbserial 2>/dev/null || true
    modprobe usb_wwan   2>/dev/null || true
    modprobe option     2>/dev/null || true
    modprobe qcserial   2>/dev/null || true
    modprobe qmi_wwan   2>/dev/null || true
    ok "Driver modules loaded (qmi_wwan is optional for QMI dial-up)."
}

reload_modules() {
    log "Unloading any already-loaded stock drivers, then loading the new build..."
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  (dry-run) would unload+reload option/usb_wwan/qcserial"
        return 0
    fi
    modprobe -r option   2>/dev/null || true
    modprobe -r qcserial 2>/dev/null || true
    modprobe -r usb_wwan 2>/dev/null || true
    load_modules
}

# ---- Install launcher / udev / DKMS ------------------------------------------
install_launcher() {
    log "Installing launcher to $INSTALLED_SCRIPT ..."
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  (dry-run) would install: $INSTALLED_SCRIPT (+ sources manifest)"
        return 0
    fi
    if [[ "$SCRIPT_PATH" != "$INSTALLED_SCRIPT" ]]; then
        install -m 755 "$SCRIPT_PATH" "$INSTALLED_SCRIPT"
    fi
    # Also install the sources manifest so the on-demand download can resolve
    # versions even when the script is run from /usr/local/bin.
    if [[ -f "$SOURCE_MANIFEST" ]]; then
        install -d "$(dirname "$SOURCE_MANIFEST_INSTALLED")"
        install -m 644 "$SOURCE_MANIFEST" "$SOURCE_MANIFEST_INSTALLED"
    fi
    ok "Launcher ready: $INSTALLED_SCRIPT"
}

install_udev_rule() {
    if [[ ! -f "$UDEV_RULE_SRC" ]]; then
        warn "udev rule not found: $UDEV_RULE_SRC"
        return 0
    fi
    log "Installing udev rule..."
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  (dry-run) would copy $UDEV_RULE_SRC -> $UDEV_RULE_DST"
        return 0
    fi
    install -m 644 "$UDEV_RULE_SRC" "$UDEV_RULE_DST"
    udevadm control --reload-rules 2>/dev/null || true
    ok "udev rule installed: $UDEV_RULE_DST"
}

install_source_tree() {
    # Stage the sources to a stable location so DKMS and future rebuilds work
    # even after the checkout directory is gone.
    [[ -n "$MODULE_SRC" ]] || resolve_source || {
        warn "No driver source tree available; skipping DKMS source staging."
        return 0
    }
    if [[ "$MODULE_SRC" == "$INSTALLED_SRC" ]]; then
        return 0
    fi
    log "Staging driver sources to $INSTALLED_SRC ..."
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  (dry-run) would copy sources to $INSTALLED_SRC"
        return 0
    fi
    mkdir -p "$INSTALLED_SRC"
    tar -C "$MODULE_SRC" \
        --exclude='*.ko' --exclude='*.o' --exclude='*.mod' --exclude='*.mod.c' \
        --exclude='*.cmd' --exclude='*.order' --exclude='*.symvers' \
        --exclude='.tmp_versions' --exclude='Module.symvers' --exclude='modules.order' \
        --exclude='USB TO RS232' \
        -cf - . | tar -C "$INSTALLED_SRC" -xf -
    if [[ -f "$DKMS_CONF_SRC" ]]; then
        install -m 644 "$DKMS_CONF_SRC" "$INSTALLED_SRC/dkms.conf"
    fi
    # Record which kernel this staged source targets, so a later resolve_source()
    # can validate it against the running kernel instead of trusting the dir name.
    if [[ -f "$MODULE_SRC/KERNEL_VERSION" ]]; then
        install -m 644 "$MODULE_SRC/KERNEL_VERSION" "$INSTALLED_SRC/KERNEL_VERSION"
    else
        printf '%s\n' "$(source_tree_version "$MODULE_SRC" || kernel_major_minor)" > "$INSTALLED_SRC/KERNEL_VERSION"
    fi
    ok "Sources staged: $INSTALLED_SRC"
}

install_dkms() {
    if ! command -v dkms >/dev/null 2>&1; then
        warn "dkms not installed; skipping auto-rebuild-on-kernel-upgrade."
        warn "Install the 'dkms' package to enable it."
        return 0
    fi
    if [[ ! -f "$INSTALLED_SRC/dkms.conf" ]]; then
        warn "dkms.conf missing in $INSTALLED_SRC; skipping DKMS."
        return 0
    fi
    log "Registering module with DKMS ($DKMS_MODULE_NAME/$DKMS_MODULE_VERSION)..."
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  (dry-run) would run: dkms add/build/install $DKMS_MODULE_NAME/$DKMS_MODULE_VERSION"
        return 0
    fi
    dkms add     -m "$DKMS_MODULE_NAME" -v "$DKMS_MODULE_VERSION" 2>/dev/null || true
    dkms build   -m "$DKMS_MODULE_NAME" -v "$DKMS_MODULE_VERSION" 2>/dev/null || true
    dkms install -m "$DKMS_MODULE_NAME" -v "$DKMS_MODULE_VERSION" 2>/dev/null || true
    ok "DKMS registered (auto-rebuild on kernel upgrade)."
}

# ---- Modes -------------------------------------------------------------------
do_quick_load() {
    log "=== QUICK-LOAD (hotplug trigger) ==="
    if is_device_ready; then
        report_ready
        return 0
    fi
    if ! is_driver_compiled; then
        # Fast path: pull a pre-built .ko package for this exact kernel, if present.
        if try_download_prebuilt; then
            load_modules
            if settle_and_check; then
                report_ready
                logger -t quectel "quick-load via pre-built package" 2>/dev/null || true
                return 0
            fi
        fi
        report_not_ready "驱动尚未安装，请先执行一次：sudo quectel_auto_install.sh --first-time"
        logger -t quectel "driver not installed; first-time install required" 2>/dev/null || true
        return 1
    fi
    load_modules
    if settle_and_check; then
        report_ready
    else
        report_not_ready "驱动已加载但串口未就绪；请检查模组是否处于 modem 模式（必要时 usb_modeswitch 或重新插拔）。"
    fi
    logger -t quectel "quick-load done" 2>/dev/null || true
}

do_first_time() {
    log "=== FIRST-TIME INSTALL ==="
    log "This downloads (or compiles) and installs the Quectel USB drivers."

    detect_module || warn "No module detected now; drivers will be ready for the next insertion."

    if ! check_kernel_config; then
        report_not_ready "内核缺少 CONFIG_USB_SERIAL（usb-serial 核心），option/qcserial 无法加载"
        return 1
    fi

    local installed=0 reason=""
    if is_driver_compiled; then
        ok "Drivers already installed for this kernel."
        load_modules
        installed=1
    elif try_download_prebuilt; then
        ok "Pre-built drivers installed from GitHub release (no compiler needed)."
        reload_modules
        installed=1
    else
        # Source-compile path: needs MATCHING kernel headers + MATCHING source tree.
        # Source is fetched on demand (GitHub) first, then local trees as fallback.
        if ! locate_kernel_build; then
            reason="缺少内核头文件 linux-headers-$(uname -r)，且无匹配的预编译包"
        elif try_download_source || resolve_source; then
            if build_install_modules; then
                reload_modules
                installed=1
            else
                reason="驱动源码编译失败（详见上方日志）"
            fi
        else
            reason="缺少与内核 $(uname -r) 匹配的驱动源码（下载失败且本地无匹配源码树）"
        fi
    fi

    if [[ $installed -eq 1 ]]; then
        install_launcher
        install_udev_rule
        install_source_tree
        install_dkms

        # 收敛到"设备已就绪"
        if settle_and_check; then
            report_ready
            log "后续插入模组将自动加载（udev 规则已安装）。"
            return 0
        fi
        if [[ -z "${DETECTED_PID:-}" ]]; then
            reason="未检测到模组（驱动已安装完毕，插入模组后将自动就绪）"
        else
            reason="驱动已安装，但串口未就绪；请确认模组处于 modem 模式，或重新插拔后重试"
        fi
    fi

    report_not_ready "$reason"
    return 1
}

do_uninstall() {
    log "=== UNINSTALL ==="
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  (dry-run) would remove modules, udev rule, DKMS, launcher and marker"
        return 0
    fi

    modprobe -r option    2>/dev/null || true
    modprobe -r qcserial  2>/dev/null || true
    modprobe -r usb_wwan  2>/dev/null || true
    modprobe -r qmi_wwan  2>/dev/null || true
    modprobe -r usbserial 2>/dev/null || true

    rm -f "$UDEV_RULE_DST"
    udevadm control --reload-rules 2>/dev/null || true

    if command -v dkms >/dev/null 2>&1; then
        dkms remove -m "$DKMS_MODULE_NAME" -v "$DKMS_MODULE_VERSION" --all 2>/dev/null || true
    fi
    rm -rf "$INSTALLED_SRC"
    rm -f "$INSTALLED_SCRIPT"
    rm -f "$MARKER"
    rm -rf "$SOURCE_CACHE"
    rm -f "$SOURCE_MANIFEST_INSTALLED"

    ok "Uninstall complete."
    warn "Note: the patched option/usb_wwan/qcserial .ko files remain under"
    warn "/lib/modules/$(uname -r)/kernel/drivers/usb/serial/ (we replaced the stock ones)."
    warn "Reinstall the distro's linux-modules package to fully restore the originals."
}

do_auto() {
    log "=== AUTO MODE ==="
    detect_module || true
    if is_device_ready; then
        report_ready
        exit 0
    fi
    if is_driver_compiled; then
        ok "驱动已安装，尝试快速加载。"
        do_quick_load
    else
        ok "驱动未安装，开始首次安装。"
        do_first_time
    fi
}

# ---- Main dispatch -----------------------------------------------------------
case "$MODE" in
    first-time) do_first_time ;;
    quick-load) do_quick_load ;;
    uninstall)  do_uninstall ;;
    auto)       do_auto ;;
    *) err "Unknown mode: $MODE"; exit 1 ;;
esac
