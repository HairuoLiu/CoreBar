# Performance / 性能实测

[← Back to README](../README.md) · [中文](#中文)

Machine: Apple M6, 32 GB, macOS 13-era SDK. Memory is **physical footprint** measured via `libproc`'s `proc_pid_rusage` (`ri_phys_footprint`), not RSS — footprint is the correct cross-process memory metric on macOS. CPU is measured in % of one core.

机器：Apple M6 / 32 GB / macOS 13 时代 SDK。内存取 `libproc` 的 `ri_phys_footprint`（**物理 footprint**，而非 RSS——在 macOS 上跨进程比较内存，footprint 才是正确口径）。CPU 以"单核百分比"计。

## English

### Headline

| | macOS | Terminal route (`macmon` in Terminal.app) | MacMonBar, menu closed | MacMonBar, menu open |
|---|---|---|---|---|
| Memory (footprint) | — | ≈ **75 MiB** | **18.5 MiB** | ≈ 24 MiB |
| CPU | — | ≈ 0.62 % of a core | ≈ **0.43 %** of a core | ≈ 0.54 % of a core |
| Incremental power | — | — | ≈ **3.8 mW** | ≈ 4.8 mW |

MacMonBar's two columns are at the **2 s** default. At 1 s they read 0.74 % / 1.05 %.

Compared with keeping `macmon` in a Terminal window, MacMonBar uses about **a quarter of the memory** (18.5 vs 75 MiB) at roughly the same CPU cost. In CPU terms the two routes are near even — but the terminal route also pays a WindowServer bill for compositing its window that never shows up in the process table.

### Where the memory goes

| Route | Breakdown |
|---|---|
| Terminal | Terminal.app 72.2 MiB + `macmon` TUI 2.7 MiB |
| MacMonBar, closed | app 12.9 MiB + `macmon pipe` child 5.6 MiB |
| MacMonBar, open | ≈ 18 MiB app (+5 on first open) + child 5.6 MiB |

Opening the menu for the first time costs about **5 MiB** (bare-binary measurement 8.5 → 13.3 MiB): the menu window and the panel's backing store only exist once you click the icon. Opening it repeatedly costs nothing further (nine consecutive opens measured flat). Long-running instances grow slowly — a 1.5-hour-old instance sat at 21.0 MiB, presumably allocation fragmentation from parsing JSON every 2 seconds.

### Refresh interval

1 / 2 / 5 s in the menu; **2 s is the default**. Re-measured on the current build, two 30-second runs each:

| Interval | App | macmon child | Total | vs. default |
|---|---|---|---|---|
| 1 s | 0.295 % | 0.445 % | 0.740 % | +72 % |
| **2 s (default)** | **0.168 %** | **0.262 %** | **0.429 %** | — |
| 5 s | 0.098 % | 0.110 % | 0.207 % | −52 % |

Moving the default from 1 s to 2 s — what 0.2.8 did — takes the whole app from 0.740 % to 0.429 % of a core: **−42 %**.

### Cost decomposition

The app broken into removable blocks, each measured (menu closed, 1 s baseline — i.e. the *old* default; at 2 s every row roughly halves):

| Component | CPU | Notes |
|---|---|---|
| `macmon pipe` child | 0.465 % | separate process; supplies GPU / memory / temperature |
| Status-bar `MeterView` redraw + status-item compositing | ≈ 0.20 % | **the single most expensive piece** — more than all four trend charts combined |
| JSON ingestion (pipe + parse + `apply` + sampling) | ≈ 0.04 % | |
| Timers + AppKit floor | ≈ 0.04 % | an empty AppKit agent app costs 0.004 % by itself |

The open-menu increment (0.315 %) breaks down further: trend-chart data paths 0.130 %, per-core bars 0.022 %, menu event tracking and panel compositing 0.163 %.

**GPU: 0.000 %.** MacMonBar is a pure AppKit 2D app, rasterized on the CPU, with panel compositing billed to WindowServer. "Reducing GPU usage" is not a thing that exists for this app.

### Power

Whole-machine power draw cannot resolve an app this small. In a three-way A/B — nothing running, menu bar running, menu bar plus a Terminal window — the three measured **10.41 W / 10.33 W / 10.38 W**, while run-to-run noise alone was **±0.71 W**. So the numbers below are derived from measured CPU time using a calibration taken on the same machine:

- idle: 8.60 W
- 12 threads at 100 %: 19.13 W
- ⇒ **10.53 W per 100 % of the 12-core package** (≈ 0.105 W per percentage point)

| State | CPU time | Incremental power | Energy per minute |
|---|---|---|---|
| Menu bar resident, menu **not** clicked (2 s default) | 0.26 core-s/min | ≈ 3.8 mW | ≈ 0.23 J |
| Menu open, 4 charts + 12 core bars redrawing every 2 s | 0.33 core-s/min | ≈ 4.8 mW | ≈ 0.29 J |

Power is linearly extrapolated from the calibration, i.e. an **upper bound**: a 0.43 % duty cycle never actually ramps core frequency, so the true increment is lower.

**Is there a difference? Yes in relative terms, no in absolute ones.** Opening the menu does about 27 % more work, worth ≈1.0 mW — still ≈700× below the ±0.71 W noise floor of whole-machine measurement, and about 0.04 % of the machine's idle draw. For scale, a minute of ordinary web browsing pushes whole-machine draw up by a few watts, on the order of 100 – 200 J per minute; this app costs 0.23 – 0.29 J.

Run continuously for a year the two states come to ≈33 Wh and ≈42 Wh — about 0.4 and 0.5 full charges on an 80 Wh battery, i.e. roughly **0.1 % / 0.15 % of a charge per day**. The practical meaning of these numbers is the electricity bill: a few cents a year.

> **Re-measurement note, 2026-10-13.** The re-measurement caught a unit bug in the tooling: `ri_user_time` / `ri_system_time` are in Mach ticks (41.6667 ns each on Apple Silicon), not nanoseconds; all three measuring scripts divided by `1e9`, **understating CPU time by 41.67×**. The fix was validated against a single-thread busy loop (which must read back ≈100 % of a core). Every number on this page comes from the corrected scripts.

---

## 中文

### 一句话结论

| | macOS | 终端路线（Terminal.app 里跑 macmon） | MacMonBar 菜单收起 | MacMonBar 菜单展开 |
|---|---|---|---|---|
| 内存（footprint） | — | ≈ **75 MiB** | **18.5 MiB** | ≈ 24 MiB |
| CPU | — | ≈ 0.62% 单核 | ≈ **0.43%** 单核 | ≈ 0.54% 单核 |
| 增量功耗 | — | — | ≈ **3.8 mW** | ≈ 4.8 mW |

MacMonBar 两列均为 **2 秒**默认间隔；1 秒时分别是 0.74% / 1.05%。

相比把 macmon 挂在终端窗口里，MacMonBar 内存约为其**四分之一**（18.5 vs 75 MiB），CPU 基本持平——但终端路线还要额外支付一个窗口合成的 WindowServer 开销，这部分在进程表里根本看不到。

### 内存去哪了

| 路线 | 拆解 |
|---|---|
| 终端 | Terminal.app 72.2 MiB + macmon TUI 2.7 MiB |
| MacMonBar（收起） | App 12.9 MiB + `macmon pipe` 子进程 5.6 MiB |
| MacMonBar（展开） | App ≈18 MiB（首次展开 +5）+ 子进程 5.6 MiB |

首次展开菜单约多花 **5 MiB**（裸二进制实测 8.5 → 13.3 MiB）：菜单窗口和面板位图只有点开后才存在。反复展开不再增长（连续九次实测持平）。长时间运行会缓慢增长——运行 1.5 小时的实例停在 21.0 MiB，推测是每 2 秒解析一次 JSON 带来的内存碎片。

### 刷新间隔

菜单提供 1 / 2 / 5 秒，**默认 2 秒**。当前构建实测（每档两轮 30 秒）：

| 间隔 | App | macmon 子进程 | 合计 | 对比默认 |
|---|---|---|---|---|
| 1 秒 | 0.295% | 0.445% | 0.740% | +72% |
| **2 秒（默认）** | **0.168%** | **0.262%** | **0.429%** | — |
| 5 秒 | 0.098% | 0.110% | 0.207% | −52% |

把默认从 1 秒改成 2 秒（0.2.8 的改动）使整体从 0.740% 降到 0.429% 单核，**−42%**。

### 开销分解

把 App 拆成可移除的模块逐个实测（菜单收起、1 秒基线，即*旧*默认；2 秒时各行大约减半）：

| 组件 | CPU | 说明 |
|---|---|---|
| `macmon pipe` 子进程 | 0.465% | 独立进程，提供 GPU / 内存 / 温度 |
| 状态栏 `MeterView` 重绘 + 状态项合成 | ≈ 0.20% | **单项最贵**，比四张趋势图加起来还贵 |
| JSON 摄入（管道 + 解析 + `apply` + 采样） | ≈ 0.04% | |
| 定时器 + AppKit 底噪 | ≈ 0.04% | 一个空的 AppKit 代理 App 本身只要 0.004% |

展开菜单的增量（0.315%）再拆：趋势图数据链路 0.130%、逐核柱 0.022%、菜单事件跟踪与面板合成 0.163%。

**GPU：0.000%。** MacMonBar 是纯 AppKit 2D 应用，光栅化在 CPU 上完成，面板合成记在 WindowServer 头上。"降低 GPU 占用"这件事对它是伪命题。

### 功耗

整机功耗根本分辨不出这么小的 App。三路 A/B（什么都不跑 / 只跑菜单栏 / 菜单栏 + 一个终端窗口）实测 **10.41 W / 10.33 W / 10.38 W**，而单轮噪声就有 **±0.71 W**。所以下表由实测 CPU 时间结合同机标定换算：

- 空闲 8.60 W
- 12 线程满载 19.13 W
- ⇒ **整个 12 核封装满载 100% 约 10.53 W**（每百分点 ≈0.105 W）

| 状态 | CPU 时间 | 增量功耗 | 每分钟能耗 |
|---|---|---|---|
| 常驻但不点开菜单（2 秒默认） | 0.26 core-s/min | ≈ 3.8 mW | ≈ 0.23 J |
| 菜单展开，4 张图 + 12 根核柱每 2 秒重绘 | 0.33 core-s/min | ≈ 4.8 mW | ≈ 0.29 J |

功耗由标定线性外推，即**上界**：0.43% 的占空比根本不会把核心频率拉起来，真实增量只会更低。

**有没有差别？相对有，绝对没有。** 展开菜单多做约 27% 的功，值 ≈1.0 mW——仍比整机测量的 ±0.71 W 噪声低约 700 倍，约为整机空闲功耗的 0.04%。作为参照，一分钟普通网页浏览会把整机功耗顶高几瓦，量级是 100 – 200 J/分钟；这个 App 是 0.23 – 0.29 J。

连续跑一年，两种状态分别约 **33 Wh** 和 **42 Wh**——80 Wh 电池的 0.4 / 0.5 个满充，也就是每天约 **0.1% / 0.15% 一格电**。实际意义在电费上：一年几分钱。

> **2026-10-13 重测说明。** 这次重测顺带揪出工具链的一个单位 bug：`ri_user_time` / `ri_system_time` 的单位是 Mach tick（Apple Silicon 上 41.6667 ns），不是纳秒；三个测量脚本都按 `1e9` 除，**把 CPU 时间低估了 41.67 倍**。修正后用一个单线程忙循环验证（必须读回 ≈100% 单核）。本页所有数字均来自修正后的脚本。
