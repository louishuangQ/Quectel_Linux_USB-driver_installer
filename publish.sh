#!/bin/bash
###############################################################################
# publish.sh — 一键发布到 GitHub（在你的机器上、已登录 gh 后运行）
#
# 完成三件事：
#   1. 创建 public 仓库（已存在则复用）
#   2. 把轻量工程推上去（.gitignore 已排除 sources/、zip 等大文件）
#   3. 打包 sources/ 为 quectel-src-vX.Y.Z.tar.gz 并上传到 Release
#
# 用法：
#   ./publish.sh <owner>/<repo> [tag]
#   例：./publish.sh louishuangQ/quectel-drivers quectel-usb-2.0
###############################################################################
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

REPO="${1:-}"
TAG="${2:-quectel-usb-2.0}"
[[ -n "$REPO" ]] || { echo "usage: ./publish.sh <owner>/<repo> [tag]" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || { echo "需要先安装并登录 gh：https://cli.github.com/" >&2; exit 1; }

# 1) 确保是 git 仓库并有提交
if [[ ! -d .git ]]; then
    git init -q
    git add -A
    git commit -q -m "Quectel Linux USB driver auto-installer (lightweight)" || true
fi

# 2) 创建/推送 GitHub 仓库
if gh repo view "$REPO" >/dev/null 2>&1; then
    echo "[*] 仓库已存在：$REPO，直接推送"
    git remote add origin "https://github.com/${REPO}.git" 2>/dev/null \
        || git remote set-url origin "https://github.com/${REPO}.git"
    git push -u origin HEAD
else
    echo "[*] 创建并推送仓库：$REPO"
    gh repo create "$REPO" --public --source . --push
fi

# 3) 打包并上传源码包（按需下载功能依赖这些资产）
if [[ -d sources ]]; then
    ./make_source_assets.sh "$REPO" "$TAG"
else
    echo "[!] 未找到 sources/，跳过源码包上传。"
    echo "    如需「按需下载源码」功能，请先放回 sources/ 再重跑。"
fi

echo "[OK] 发布完成：https://github.com/${REPO}"
