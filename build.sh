#!/usr/bin/env bash
# CoreBar 一键构建。Swift 前端 + 原生 C 传感器（src/sensors.c），零第三方依赖、零子进程。
#
# 用法: ./build.sh
# 产物: ./CoreBar.app
set -euo pipefail
cd "$(dirname "$0")"

APP="CoreBar.app"
BIN="$APP/Contents/MacOS/CoreBar"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "错误：未找到 swiftc。请先安装 Xcode 或 Xcode Command Line Tools：" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# -O 优化；target 锁定 macOS 13 + Apple Silicon（LSUIElement 菜单栏应用无理由支持 Intel）。
# 同时编译 src/sensors.c（GPU 占用走 libIOReport，温度走 IOHID/AppleSMC），链接 IOKit/CoreFoundation。
swiftc -O -target arm64-apple-macosx13.0 src/main.swift src/sensors.c -o "$BIN" \
  -framework IOKit -framework CoreFoundation

# ad-hoc 签名：本机可直接运行，不需要开发者证书；失败也不阻断构建
codesign --force --sign - "$APP" 2>/dev/null || true

echo "构建完成 → $(pwd)/$APP"
echo "运行：open '$APP'"
