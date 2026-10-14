# MacMonBar

**把 CPU、GPU、内存、温度放进 macOS 菜单栏——一个状态项、四张趋势图、芯片上每一个核心。**

手写 733 行 Swift，零第三方依赖。占用 **18.5 MiB 内存、0.43% 单核**，而把 [macmon](https://github.com/vladkens/macmon) 挂在终端窗口里要花 **≈75 MiB**。

[English →](./README.md) · [完整功能](docs/features.md) · [更新记录](CHANGELOG.md)

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen) ![License](https://img.shields.io/badge/license-MIT-green)

![MacMonBar 展开面板](docs/zh/panel-light.png)

![MacMonBar 状态栏](docs/zh/statusbar-light.png)

---

## 性能一览

| | 终端路线 | MacMonBar | 差距 |
|---|---|---|---|
| 内存（footprint） | ≈ 75 MiB | **18.5 MiB** | **−75%** |
| CPU（2 秒刷新） | ≈ 0.62% 单核 | **0.43%** 单核 | −31% |
| 增量功耗 | — | **≈ 3.8 mW** | 每天约 0.1% 一格电 |
| GPU | — | **0.000%** | 纯 AppKit 2D，CPU 上光栅化 |

全部实测，不是估算——内存走 `libproc` 的 `ri_phys_footprint`，CPU 时间为多轮 8 秒以上窗口的统计。完整方法、开销分解、刷新间隔表与功耗标定见 **[docs/performance.md](docs/performance.md)**。

## 为什么选它

- **CPU 数字是诚实的。** CPU 与逐核占用率由 App 自己用 Mach `host_processor_info` 采样，因此所有核心都在，核数也来自内核。macmon 自己的 `cpu_usage_pct` 是频率加权驻留度：12 线程全核加载时它报 **59.0%**，而真实利用率是 **99.3%**。**[原理 →](docs/how-it-works.md)**
- **没装 macmon 也能用。** 采样器跑在自己的定时器上，所以缺 macmon 只损失 GPU / 内存 / 温度三项，CPU 照常；那三项显示 `—`，而不是误导性的 `0%`。
- **没有 Dock 图标、没有窗口、没有可切换的界面。** `LSUIElement`，它只活在菜单栏里。
- **零依赖，单文件。** 只用 AppKit + Foundation + Mach。没有 SwiftPM、没有 Carthage、没有 vendor 代码——也没有 macmon 的代码：运行时通过调用 `macmon` 二进制拿 GPU / 内存 / 温度。**[为什么保留这个依赖 →](docs/macmon.md)**
- **不是小组件。** 菜单栏是唯一能 2Hz 采样又不必养着终端会话的形态，不需要宿主 App、不需要 App Group——WidgetKit 由时间线驱动并被节流到分钟级，所以小组件比它包裹的东西更重。
- **两套互不重叠的色系。** 图表用身份色（蓝 CPU / 玫红 GPU / 青内存 / 紫温度）；数字用数值色（按各自阈值绿 / 琥珀 / 红）。图表永远不会和一个穿同色的数字撞上。**[设计说明 →](docs/design.md)**

## 安装

需要 macOS 13+ 与 Apple Silicon。

### 第一步——先装 macmon

MacMonBar 需要 `macmon` 二进制来提供 GPU、内存与温度：

```bash
brew install macmon
```

没有 Homebrew？把 [macmon 的 release](https://github.com/vladkens/macmon/releases) 里预编译的 arm64 二进制丢进 `~/.local/bin` 即可。MacMonBar 会按 `~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin` 的顺序查找。

### 第二步——装 MacMonBar

**直接下载**最新版本：

**[→ 下载 MacMonBar（macOS / Apple Silicon）](https://github.com/HairuoLiu/MacMonBar/releases/latest)**

解压，把 `MacMonBar.app` 拖进 `/Applications`，打开。没有 Dock 图标——去看菜单栏。

**或者从源码构建**（需要 Xcode Command Line Tools）：

```bash
git clone https://github.com/HairuoLiu/MacMonBar.git
cd MacMonBar
./build.sh          # 编译 src/main.swift → ./MacMonBar.app
open MacMonBar.app
```

### 开机自启

**系统设置 → 通用 → 登录项与扩展 → 登录时打开 → +**，选中 `MacMonBar.app`。

### 配置

点菜单栏图标即可：百分比着色（**开**）、进度条（关）、温度（关）、逐核柱（**开**）、刷新间隔（默认 **2 秒**，可选 1 / 2 / 5 秒）。完整菜单说明见 **[docs/features.md](docs/features.md)**。

<details>
<summary><b>给 AI Agent——无人值守安装</b></summary>

先确认环境：Apple Silicon（`uname -m` = `arm64`）与 macOS 13+（`sw_vers -productVersion`）。任一不满足就明确报错退出——本 App 只有 arm64 版本，在 Intel 上跑不起来。

```bash
#!/usr/bin/env bash
# MacMonBar 无人值守安装，可重复执行。
set -euo pipefail

# 1. macmon —— 提供 GPU / 内存 / 温度；就算没有它，CPU 也照常工作
if ! command -v macmon >/dev/null 2>&1 \
   && [ ! -x "$HOME/.local/bin/macmon" ] \
   && [ ! -x /opt/homebrew/bin/macmon ]; then
  if command -v brew >/dev/null 2>&1; then
    brew install macmon
  else
    mkdir -p "$HOME/.local/bin"
    curl -fsSL https://github.com/vladkens/macmon/releases/latest/download/macmon-macos-arm64.tar.gz \
      | tar -xz -C "$HOME/.local/bin" macmon
    chmod +x "$HOME/.local/bin/macmon"
  fi
fi

# 2. 验证 macmon 真的能吐出一行可解析的 JSON
MACMON_BIN="$HOME/.local/bin/macmon"
[ -x "$MACMON_BIN" ] || MACMON_BIN="$(command -v macmon)"
"$MACMON_BIN" pipe -i 500 2>/dev/null | head -n 1 \
  | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
  || { echo "macmon 没有输出可解析的 JSON，请检查权限/Gatekeeper" >&2; exit 1; }
# 应包含字段：gpu_scaled_ratio、memory.ram_usage / ram_total、temp.cpu_temp_avg

# 3. MacMonBar —— 从 API 解析最新资产，不要写死版本号
URL=$(curl -fsSL https://api.github.com/repos/HairuoLiu/MacMonBar/releases/latest \
      | python3 -c 'import json,sys; print([a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].endswith(".zip")][0])')
curl -fsSL "$URL" -o /tmp/MacMonBar.zip
rm -rf /tmp/MacMonBar-app && mkdir -p /tmp/MacMonBar-app
unzip -oq /tmp/MacMonBar.zip -d /tmp/MacMonBar-app

# 4. 安装，并清掉 quarantine 位，避免 Gatekeeper 弹窗
rm -rf /Applications/MacMonBar.app
mv /tmp/MacMonBar-app/MacMonBar.app /Applications/
xattr -dr com.apple.quarantine /Applications/MacMonBar.app 2>/dev/null || true

# 5. 启动并确认进程存活——它是 LSUIElement，没有窗口可看
open /Applications/MacMonBar.app
sleep 2
pgrep -x MacMonBar >/dev/null && echo "OK: MacMonBar running" || { echo "启动失败" >&2; exit 1; }
```

给 Agent 的几条提醒：

- App 在启动时**以及**每次切换刷新间隔时读 `macmon`。如果你在 MacMonBar 已经运行时才装上 macmon，请从菜单里 **退出 MacMonBar** 再重新打开——菜单里没有"重新加载"这一项。
- 成功的标志是：有个叫 `MacMonBar` 的进程，外加一个跑着 `pipe -i 2000` 的 `macmon` 子进程。
- **不要**试图截图验证——它没有窗口。用 `pgrep` 和菜单栏上那一项是否存在来判断。
- 卸载：从菜单退出，删掉 `/Applications/MacMonBar.app`。除此之外它不在 bundle 外写任何东西。

</details>

## 故障排查

<details>
<summary><b>出问题了——点开这里</b></summary>

| 现象 | 原因 | 解决 |
|---|---|---|
| GPU / 内存 / 温度显示 `—` | 找不到 macmon，或找到了但启动失败 | 先装它（第一步），然后**退出并重开 MacMonBar**。查找顺序：`~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin` |
| 全部指标都是 `—`，连 CPU 也是 | 理论上不该发生——CPU 有自己的定时器。请反馈 | — |
| 一直卡在 `0%` 不动 | 旧版本（≤ 0.1.x）所有指标都依赖 macmon | 升级到 0.2.0 或更高 |
| 重启后菜单栏那一项不见了 | 没有设置成登录项 | **系统设置 → 通用 → 登录项与扩展 → 登录时打开 → +** |
| 菜单栏那一项被藏进刘海底下 | 菜单栏排满时 macOS 会把右边的项挤掉 | 按住 `⌘` 拖动调整顺序，或退出其他菜单栏 App |
| 提示"MacMonBar 已损坏／无法打开" | 下载的未签名构建带 Gatekeeper quarantine | `xattr -dr com.apple.quarantine /Applications/MacMonBar.app` |
| 构建时报 `xcrun: error: invalid active developer path` | 没装 Command Line Tools | `xcode-select --install` |
| 构建时报 `swiftc: error: unable to find utility` | 同上 | 同上 |
| `open MacMonBar.app` 之后什么都没发生 | 它是 `LSUIElement`，设计上就没有窗口和 Dock 图标 | 看菜单栏 |
| 菜单展开时面板冻住 | 0.2.0 已修（`DispatchQueue.main.async` 的重绘在 `NSEventTrackingRunLoopMode` 里不会执行） | 升级，[细节](docs/how-it-works.md) |
| Intel 机器上构建失败 | 编译目标是 `arm64-apple-macosx13.0` | 不支持；Intel 上做菜单栏监视器没有意义 |
| CPU 数值和活动监视器不一致 | 预期之内。活动监视器显示的是频率加权驻留度，和 macmon 同一口径 | [细节](docs/how-it-works.md) |

</details>

## 截图

开启进度条——可选的水平刻度条：

![状态栏·进度条](docs/zh/statusbar-bars-light.png)

没有 macmon——CPU 与逐核照常工作，其余三项显示 `—` 而不是 `0%`：

![无 macmon](docs/zh/statusbar-no-macmon-light.png)

深色模式、开启温度，以及降级状态下的面板：**[docs/screenshots.md](docs/screenshots.md)**。

## 深入了解

| 页面 | 内容 |
|---|---|
| [docs/performance.md](docs/performance.md) | 内存 / CPU / 功耗实测、开销分解、刷新间隔表 |
| [docs/how-it-works.md](docs/how-it-works.md) | 数据流、Mach 采样器、为何与 macmon 的 CPU 数值不同、`NSMenu` 事件循环坑 |
| [docs/macmon.md](docs/macmon.md) | 与 macmon 的关系，以及为什么保留这个依赖 |
| [docs/features.md](docs/features.md) | 每个功能、每个菜单项、每个默认值 |
| [docs/design.md](docs/design.md) | 为什么是菜单栏、为什么用图、两套色系、宽度是量出来的 |
| [docs/tools.md](docs/tools.md) | 测量脚本，以及截图是怎么生成的 |
| [CHANGELOG.md](CHANGELOG.md) | 版本历史 |

## 致谢

- [macmon](https://github.com/vladkens/macmon)（作者 vladkens）——本 App 所包装的无 sudo Apple Silicon 监视器，MIT。
- 逐核准确度与 [mactop](https://github.com/context-labs/mactop) 交叉验证。

## 授权

MIT——见 [LICENSE](./LICENSE)。
