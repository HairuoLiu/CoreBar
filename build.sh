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

MACMON="$HOME/.local/bin/macmon"
if [ ! -x "$MACMON" ]; then
  echo "提示：未在 $MACMON 找到 macmon。MacMonBar 需要它提供 GPU / 内存 / 温度数据。" >&2
  echo "  CPU 与逐核占用率不依赖它，但其他指标会显示为 0。" >&2
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
