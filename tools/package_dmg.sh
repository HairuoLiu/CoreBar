#!/usr/bin/env bash
# CoreBar 专用 Intel DMG 镜像打包脚本
#
# 用法: ./tools/package_dmg.sh [版本号，如 v0.4.2]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-v0.4.2}"
DMG_NAME="CoreBar-${VERSION}-intel-x86_64.dmg"
APP="CoreBar.app"

if [ ! -d "$APP" ]; then
    echo "错误：未找到 $APP，请先执行 ./build.sh" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "→ 准备 Intel x86_64 专用独立安装包"
cp -R "$APP" "$TMP_DIR/CoreBar.app"

# 剥离多架构，提取纯粹的 Intel x86_64 Mach-O 切片
lipo -thin x86_64 "$TMP_DIR/CoreBar.app/Contents/MacOS/CoreBar" -output "$TMP_DIR/CoreBar.app/Contents/MacOS/CoreBar.x86"
mv "$TMP_DIR/CoreBar.app/Contents/MacOS/CoreBar.x86" "$TMP_DIR/CoreBar.app/Contents/MacOS/CoreBar"
codesign --force --sign - "$TMP_DIR/CoreBar.app" 2>/dev/null || true

# 创建 /Applications 快捷方式，方便拖拽安装
ln -s /Applications "$TMP_DIR/Applications"

echo "→ 打包压缩 DMG 镜像: $DMG_NAME"
rm -f "$DMG_NAME"
hdiutil create -volname "CoreBar Intel" -srcfolder "$TMP_DIR" -ov -format UDZO "$DMG_NAME" >/dev/null

echo "✓ 成功生成: $DMG_NAME ($(du -h "$DMG_NAME" | cut -f1))"
