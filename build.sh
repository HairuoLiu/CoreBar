#!/usr/bin/env bash
# MacMonBar 一键构建。单文件 Swift，零第三方依赖。
#
# 用法: ./build.sh
# 产物: ./MacMonBar.app
set -euo pipefail
cd "$(dirname "$0")"

APP="MacMonBar.app"
BIN="$APP/Contents/MacOS/MacMonBar"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "错误：未找到 swiftc。请先安装 Xcode 或 Xcode Command Line Tools：" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

# 与 App 内查找顺序一致：~/.local/bin → Homebrew(AS) → Homebrew(Intel)
MACMON=""
for c in "$HOME/.local/bin/macmon" /opt/homebrew/bin/macmon /usr/local/bin/macmon; do
  [ -x "$c" ] && MACMON="$c" && break
done
if [ -z "$MACMON" ]; then
  echo "提示：未找到 macmon（已查找 ~/.local/bin、/opt/homebrew/bin、/usr/local/bin）。" >&2
  echo "  安装：brew install macmon" >&2
  echo "  CPU 与逐核占用率不依赖它，其余指标会显示 —。" >&2
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

# -O 优化；target 锁定 macOS 13 + Apple Silicon（LSUIElement 菜单栏应用无理由支持 Intel）
swiftc -O -target arm64-apple-macosx13.0 src/main.swift -o "$BIN"

# ad-hoc 签名：本机可直接运行，不需要开发者证书；失败也不阻断构建
codesign --force --sign - "$APP" 2>/dev/null || true

echo "构建完成 → $(pwd)/$APP"
echo "运行：open '$APP'"
