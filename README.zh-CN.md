# MacMonBar

一个原生的 macOS 菜单栏前端，为 [macmon](https://github.com/vladkens/macmon) 而做——CPU、GPU、内存、温度一眼可见，并且**每一个核**的占用率都单独统计。

一个状态栏图标、四张趋势图、一个 540 行的 Swift 文件，**零第三方依赖**。

[English →](./README.md)

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

## 为什么做这个

`macmon` 是一个很好的、不需要 sudo 的 Apple Silicon 监控工具，但它住在终端里。在 Terminal.app 里跑它，等于同时养着一个窗口、一个标签页、一个登录 shell 和一份回滚缓冲区——这些开销比监控本身大得多。

| 方案 | 物理内存占用 | 说明 |
|---|---|---|
| 在 Terminal.app 里跑 `macmon` | **97 – 121 MiB** | 终端窗口 + 标签页 + shell + 回滚缓冲 |
| MacMonBar，菜单关闭 | **约 22 MiB** | App 13.1 MiB + `macmon pipe` 子进程 9.0 MiB |
| MacMonBar，菜单展开 | **约 29 MiB** | App 20.1 MiB + 子进程 9.0 MiB |

菜单栏也是三种"挂件"形态里唯一能做到 1 Hz 刷新的。桌面挂件和右侧通知中心挂件用的是**同一套** WidgetKit 技术：时间线驱动、被节流到分钟级、无法自己采样，还必须配一个宿主 App + App Group——最后往往比它包起来的东西还重。

## 截图

状态栏（默认状态，不显示温度）：

![状态栏，浅色](docs/statusbar-light.png)

打开温度显示后的状态栏：

![状态栏含温度，浅色](docs/statusbar-temp-light.png)

展开后的面板——四张趋势图（2 行 × 2 列）+ 逐核柱状图：

![面板，浅色](docs/panel-light.png)

同一面板的深色模式：

![面板，深色](docs/panel-dark.png)

> 这些图不是屏幕截图，而是用 App 自己的 `draw(_:)` 代码对真实采样数据离线渲染出来的——见[复现截图](#复现截图)。

## 功能

- **状态栏**——CPU / GPU / 内存三条紧凑进度条，带百分比。温度可选，默认关闭。
- **点击展开**——四张整格宽度面积图排成 2 行 × 2 列（CPU、GPU、内存、温度），当前值直接标在标题行；下方是逐核柱状图。
- **每一个核都统计到。** CPU 占用率由 App 自己通过 Mach `host_processor_info` 采样，所以所有核都会出现——M6 级别芯片上是 12 个。核数从内核读取，不写死。
- **状态栏不显示瓦数。** 状态栏只放占用率；功耗对"写代码时该关注什么"这个决策没有帮助，所以刻意去掉了。
- **刷新间隔**——1 秒 / 2 秒 / 5 秒，菜单里直接切。
- **自动适配浅色 / 深色**，颜色阈值语义化（≥ 75% 转红，≥ 40% 转琥珀色）。
- `LSUIElement`——没有 Dock 图标、没有窗口、不用切换。
- **无依赖。** 只用 AppKit + Foundation + Mach。没有 SwiftPM、没有 Carthage、没有任何第三方包。

## 环境要求

- macOS 13.0 及以上，Apple Silicon（不支持 Intel——在 Intel 上做一个菜单栏功耗监控没有意义）。
- Xcode Command Line Tools（需要 `swiftc`）。
- [macmon](https://github.com/vladkens/macmon) 装在 `~/.local/bin/macmon`——它提供 GPU、内存和温度。**CPU 占用率和逐核数据不依赖它。**

## 构建与运行

```bash
git clone https://github.com/HairuoLiu/MacMonBar.git
cd MacMonBar
./build.sh          # 编译 src/main.swift → ./MacMonBar.app
open MacMonBar.app
```

开机自启：**系统设置 → 通用 → 登录项与扩展 → 打开时登录 → +**，选 `MacMonBar.app`。（它是 `LSUIElement`，不会出现在 Dock 和切换器里。）

### 安装 macmon

```bash
brew install macmon
```

不想用包管理器的话，也可以从 [releases](https://github.com/vladkens/macmon/releases) 下载预编译的 arm64 二进制放进 `~/.local/bin`，并确认该目录在 `PATH` 里。MacMonBar 会把 `macmon pipe -i <interval>` 作为子进程拉起来，逐行读它的 JSON，不经过终端。

## 工作原理

```
                         ┌─────────────────────────────┐
   macmon pipe -i 1000   │  stdout 上的 JSON 行         │
   （子进程）───────────▶│  gpu_scaled_ratio            │────┐
                         │  memory.ram_usage / ram_total│    │
                         │  temp.cpu_temp_avg           │    │
                         └─────────────────────────────┘    │
                                                           ▼
   Mach host_processor_info ──▶ 每核 user/system/nice/idle tick
   (PROCESSOR_CPU_LOAD_INFO)      ▼
                                基于差值的占用率
                                覆盖全部 N 个核 ──▶ MeterView（状态栏）
                                                  └▶ PanelView（展开面板）
```

**CPU 占用率是自己算的，不取 macmon 的值。** macmon 的 `cpu_usage_pct` 是一个*频率加权驻留*指标——核在各个 DVFS 档位上花了多少时间——而不是"这个核忙不忙"。12 线程全核压载时，两者能差出 1.7 倍：

| 负载 | Mach `host_processor_info` | macmon `cpu_usage_pct` |
|---|---|---|
| 空闲 | 21.4 % | — |
| 4 个忙线程 | 44.6 % | — |
| 6 个忙线程 | 59.9 % | — |
| **12 个忙线程（全核）** | **99.3 %** | **59.0 %** |

对于一个占用率仪表，你要的是第二列。`tools/cputest.swift` 可以复现这张表；`tools/coretest.swift` 打印逐核数值，并与 `mactop` 的 `core_usages` 交叉验证过（偏差 1 – 3 个百分点）。

### 一个不太容易发现的坑

`NSMenu` 展开时会在 `NSEventTrackingRunLoopMode` 里跑一个嵌套事件循环。用 `DispatchQueue.main.async` 投递的 block 在这个模式下**不会**被派发，所以最直觉的写法——管道回调 → `DispatchQueue.main.async` → 重绘——会让面板在你点下图标的那一刻就冻住。

直接测出来的结果：菜单展开的 25 秒里，后台队列收到 24 个采样，但只跑了 3 次 `ingest`、1 次重绘。

解决办法是把原始字节交给一个挂在 `RunLoop.main` 的 `.common` 模式上的 `Timer`，这个模式在事件跟踪期间照样会被驱动：

```swift
RunLoop.main.add(t, forMode: .common)
```

改完之后同样的 25 秒窗口变成 `bg=24 main=24 panelDraw=23`——面板在菜单展开期间是实打实每秒光栅化一次的。这也是下面功耗数字可信的原因：绘制的活是真的干了，没有被跳过。

## 实测资源占用

测试机：Apple M6，32 GB，macOS 13 时代 SDK。物理内存用 `libproc` 的 `proc_pid_rusage`（`ri_phys_footprint`）测，不用 RSS——footprint 才是 macOS 上跨进程比较内存的正确指标。

| | 终端方案 | MacMonBar，菜单关闭 | MacMonBar，菜单展开 |
|---|---|---|---|
| 常驻内存 | 97 – 121 MiB | 约 22 MiB | 约 29 MiB |
| CPU 时间 | 约 0.07% 个核 | 约 0.016% 个核 | 约 0.023% 个核 |

点开菜单会多花约 **7 MiB**（13.1 → 20.1 MiB）：菜单窗口和面板的备份存储只有在你点下图标之后才存在。`macmon pipe` 子进程恒定贡献约 9 MiB。

### 功耗

整机功耗分辨不出这么小的一个应用。做了一次三方 A/B——什么都不跑 / 挂菜单栏 / 挂菜单栏再加一个终端窗口——三者分别测到 **10.41 W / 10.33 W / 10.38 W**，而单纯的重测噪声就有 **±0.71 W**。菜单栏的贡献在整机分辨率下根本区分不出来，所以下面这组数字改用实测 CPU 时间推算，标定系数来自同一台机器：

- 空闲：**8.60 W**
- 12 线程 100%：**19.13 W**
- ⇒ **12 核整体每 100% 对应 10.53 W**（约每 1 个百分点 0.105 W）

每个状态用 120 秒窗口测了两轮（`tools/power_ab.py`）：

| 状态 | CPU 时间 | 增量功耗 | 每分钟能量 |
|---|---|---|---|
| 菜单栏常驻，**不点开** | 0.0092 – 0.0096 core-s/分 | 约 0.14 mW | 约 0.008 J |
| 菜单展开，4 张图 + 12 核条以 1 Hz 重绘 | 0.0128 – 0.0145 core-s/分 | 约 0.20 mW | 约 0.012 J |

**有没有差距？相对意义上有，绝对意义上没有。** 展开菜单会多干约 **45%** 的活——两组区间确实不重叠——但折算下来只有约 0.06 mW、每分钟约 0.004 J。这比整机功耗测量的 ±0.71 W 噪声底还低约 **3500 倍**，大约只占整机空闲功耗的 **0.002%**。作为参照，正常浏览网页一分钟会把整机功耗推高几瓦，也就是每分钟 100 – 200 J 量级；这个 App 是 0.01 J 左右。

常驻一整年，两个状态分别约 **1.2 Wh** 和 **1.7 Wh**——在 80 Wh 电池上约等于一次满电的 1.5% 和 2.2%。

App 自身的开销里，占大头的也是它拉起来的 `macmon pipe` 子进程（约 0.007 core-s/分），而不是绘图。

## 设计说明

**为什么选菜单栏而不是挂件。** 按资源消耗和复杂度排序，菜单栏在每一项上都赢：它是唯一能以 1 Hz 采样的形态，不需要宿主 App、不需要 App Group、不需要时间管线，开销大约只有终端方案的四分之一。桌面挂件和通知中心挂件本质是同一套 WidgetKit，只是多了一层仪式。

**用图不用纯文字。** 光有百分比看不出趋势。四张 small multiples——一个指标一张、纵向排开——而不是两条叠在一起的 sparkline，因为折线交叉时叠线根本读不出来。每张图把当前值内嵌在标题行，配一条 50% 虚线参考线、18% 面积填充，以及最新采样点上的圆点。

**颜色要有语义。** CPU 蓝、GPU 橙、内存绿，外加一套在所有元素间保持一致的"红 / 琥珀 / 绿"阈值梯度。深色模式下色相会提亮，以维持对比度。

**固定宽度。** 面板固定 300 pt，左右各留 14 pt 内边距。宽度选择器被去掉了——一个监控工具应该有一个好用的默认值，而不是一个偏好设置面板。

## 复现截图

`docs/` 里的图不是屏幕截图，而是把真实采样数据喂给同一套 `PanelView` / `MeterView` 的 `draw(_:)`，再光栅化进 `NSBitmapImageRep`：

```swift
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
view.frame = NSRect(x: 0, y: 0, width: w, height: h)
view.draw(view.bounds)
```

这样不需要屏幕录制权限，也不可能和 App 真实渲染出来的样子走偏。要重新生成，拿 `src/main.swift`，把底部的 `NSApplication.shared` 启动段换成一个采集器（读 `macmon pipe -i 200` 约 26 秒），然后以 `scale: 2`（面板）和 `scale: 3`（状态栏）在 `.aqua` 和 `.darkAqua` 下分别渲染。

## `tools/`

几个小而专的脚本保留在这里，因为本 README 里每一个数字都出自其中之一。

| 文件 | 用途 |
|---|---|
| `cputest.swift` | 全核 CPU 精度测试：空闲 → 4 → 6 → 12 个忙线程 |
| `coretest.swift` | 打印逐核占用率；与 `mactop` 交叉验证 |
| `machsampler.swift` | 纯 Mach 采样器——零依赖基线 |
| `measure.py` | 用 `libproc` 测单进程 CPU% / RSS / 物理内存 |
| `measure_state.py` | 测某一状态在 N 秒内的 CPU 时间 |
| `power_ab.py` | 上表所用的两状态功耗 A/B |

任意一个都可以这样编译：`swiftc -O tools/<name>.swift -o /tmp/<name>`。

## 致谢

- [macmon](https://github.com/vladkens/macmon)（vladkens）——本项目前端所对接的无 sudo Apple Silicon 监控工具。MIT。
- 逐核精度与 [mactop](https://github.com/context-labs/mactop) 交叉验证。

## 许可证

MIT——见 [LICENSE](./LICENSE)。
