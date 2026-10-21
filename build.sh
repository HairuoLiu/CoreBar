#!/usr/bin/env bash
# CoreBar 一键构建。Swift 前端 + 原生 C 传感器（src/sensors.c），零第三方依赖、零子进程。
#
# 用法: ./build.sh
# 产物: ./CoreBar.app（支持 Universal Binary arm64 + x86_64，若不支持则为原生架构）
set -euo pipefail
cd "$(dirname "$0")"

APP="CoreBar.app"
BIN="$APP/Contents/MacOS/CoreBar"

if ! command -v swiftc > /dev/null 2>&1; then
  echo "错误：未找到 swiftc。请先安装 Xcode 或 Xcode Command Line Tools：" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 架构检测：检测当前机器原生架构，优先尝试 Universal Binary（arm64 + x86_64 lipo 合并）。
# 若 arm64/x86_64 任一工具链缺失，则回退到当前机器单架构。
# sensors.c 已做好 Intel/Apple Silicon 双平台兼容。
HOST_ARCH="$(uname -m)"   # arm64 或 x86_64
TMPDIR_BUILD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BUILD"' EXIT

# 公共编译参数
FRAMEWORKS="-framework IOKit -framework CoreFoundation"

# -----------------------------------------------------------------------
# 辅助函数：编译单个架构（C 先 clang 编成 .o，再传给 swiftc 链接）
# 返回 0 表示成功，1 表示失败（失败时静默，由调用方处理）
# -----------------------------------------------------------------------
build_arch() {
  local arch="$1"        # arm64 or x86_64
  local outbin="$2"      # 输出可执行文件路径
  local target="${arch}-apple-macosx13.0"
  local sensors_o="$TMPDIR_BUILD/sensors_${arch}.o"

  # Step 1: 用 clang 单独编译 sensors.c（兼容旧版 swiftc 不自动处理 .c 文件的行为）
  clang -O2 -target "$target" -c src/sensors.c -o "$sensors_o" 2>/dev/null || return 1

  # Step 2: 用 swiftc 编译 main.swift，链接 sensors_o
  swiftc -O -target "$target" src/main.swift "$sensors_o" \
    $FRAMEWORKS -o "$outbin" 2>/dev/null || return 1

  return 0
}

BUILD_UNIVERSAL=1
BIN_ARM64="$TMPDIR_BUILD/CoreBar.arm64"
BIN_X86="$TMPDIR_BUILD/CoreBar.x86_64"

echo "尝试构建 Universal Binary（arm64 + x86_64）…"

if build_arch arm64 "$BIN_ARM64"; then
  echo "  ✓ arm64 编译完成"
else
  echo "  ✗ arm64 编译失败，放弃 Universal Binary"
  BUILD_UNIVERSAL=0
fi

if [ "$BUILD_UNIVERSAL" = "1" ]; then
  if build_arch x86_64 "$BIN_X86"; then
    echo "  ✓ x86_64 编译完成"
  else
    echo "  ✗ x86_64 编译失败，放弃 Universal Binary"
    BUILD_UNIVERSAL=0
  fi
fi

if [ "$BUILD_UNIVERSAL" = "1" ]; then
  lipo -create "$BIN_ARM64" "$BIN_X86" -output "$BIN"
  echo "  ✓ Universal Binary 合并完成（arm64 + x86_64）"
else
  # 回退：仅编译当前机器的原生架构（显示详细错误信息）
  echo "回退：编译原生架构 ${HOST_ARCH}-apple-macosx13.0 …"
  SENSORS_O="$TMPDIR_BUILD/sensors_native.o"
  clang -O2 -target "${HOST_ARCH}-apple-macosx13.0" -c src/sensors.c -o "$SENSORS_O"
  swiftc -O -target "${HOST_ARCH}-apple-macosx13.0" src/main.swift "$SENSORS_O" \
    $FRAMEWORKS -o "$BIN"
fi

# ad-hoc 签名：本机可直接运行，不需要开发者证书；失败也不阻断构建
codesign --force --sign - "$APP" 2>/dev/null || true

echo "构建完成 → $(pwd)/$APP"
echo "运行：open '$APP'"
