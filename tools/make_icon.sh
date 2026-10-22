#!/usr/bin/env bash
# CoreBar 图标一键生成：1024 PNG → AppIcon.iconset → AppIcon.icns，并导出 docs/app-icon.png。
#
# 用法: ./tools/make_icon.sh
# 依赖: swiftc（Xcode CLT）、sips、iconutil（macOS 自带）。
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ 编译图标生成器"
swiftc -O tools/make_icon.swift -o "$TMP/make_icon"

echo "→ 渲染 1024×1024"
"$TMP/make_icon" "$TMP/icon_1024.png"

echo "→ 构建 iconset"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
# 10 个标准槽位：16/32/128/256/512 各 1x+2x
sips -z 16 16     "$TMP/icon_1024.png" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$TMP/icon_1024.png" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$TMP/icon_1024.png" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$TMP/icon_1024.png" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$TMP/icon_1024.png" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$TMP/icon_1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$TMP/icon_1024.png" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$TMP/icon_1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$TMP/icon_1024.png" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$TMP/icon_1024.png" "$ICONSET/icon_512x512@2x.png"   # 1024 直接复用，不重采样

echo "→ 打包 AppIcon.icns"
iconutil -c icns "$ICONSET" -o AppIcon.icns

echo "→ 导出 docs/app-icon.png（1024）"
cp "$TMP/icon_1024.png" docs/app-icon.png

echo "完成：AppIcon.icns（$(du -h AppIcon.icns | cut -f1)）、docs/app-icon.png"
