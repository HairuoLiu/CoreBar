# Performance / 性能实测

[← Back to README](../README.md) · [中文](#中文)

Machine: Apple M6, 32 GB, macOS 13-era SDK. Memory is **physical footprint** measured via `libproc`'s `proc_pid_rusage` (`ri_phys_footprint`), not RSS — footprint is the correct cross-process memory metric on macOS. CPU is measured in % of one core.

机器：Apple M6 / 32 GB / macOS 13 时代 SDK。内存取 `libproc` 的 `ri_phys_footprint`（**物理 footprint**，而非 RSS——在 macOS 上跨进程比较内存，footprint 才是正确口径）。CPU 以"单核百分比"计。

## English

### Headline

| | macOS | Terminal route (`macmon` in Terminal.app) | CoreBar, menu closed | CoreBar, menu open |
|---|---|---|---|---|
| Memory (footprint) | — | ≈ **75 MiB** | **≈ 13 MiB** (single process) | ≈ 20 MiB |
| CPU | — | ≈ 0.62 % of a core | ≈ **0.26 %** of a core | ≈ 0.28 % of a core |
| Incremental power | — | — | ≈ **2.3 mW** | ≈ 3.3 mW |

CoreBar is a **single process** — there is no `macmon pipe` child anymore (see
[docs/macmon.md](macmon.md)). The 13 MiB figure is the whole app, GPU/temperature
included. Measured head-to-head against the last two-process build (v0.2.9, same machine,
same session, three 15-second runs each, 2 s default): **21.4 MiB → 12.9 MiB (−40 %)** and
**0.392 % → 0.263 % of a core (−33 %)**, one process instead of two. Details in
[v0.3.0: the subprocess is gone](#v030-the-subprocess-is-gone) below.

Compared with keeping `macmon` in a Terminal window, CoreBar uses about a **sixth of the
memory** (13 vs 75 MiB) at a fraction of the CPU, and carries **zero external dependencies**.

### v0.3.0: the subprocess is gone

The last build that still shelled out to `macmon pipe` is **v0.2.9** (tag `v0.2.9`, shipped as
`CoreBar-0.2.9.app.zip`). Both builds were run side by side on this machine, same session,
same tool (`tools/measure.swift`, `ri_phys_footprint` via `proc_pid_rusage`), 2 s default
interval, menu closed, three 15-second runs each:

| | v0.2.9 (App + `macmon pipe` child) | v0.3.0 (single process, native C sensors) | Δ |
|---|---|---|---|
| Processes | 2 | **1** | −1 |
| Memory (footprint) | 21.4 MiB (App 12.4 + child 9.0) | **12.9 MiB** | **−8.5 MiB (−40 %)** |
| CPU (% of one core) | 0.392 % (App 0.164 + child 0.228) | **0.263 %** | **−0.129 pp (−33 %)** |
| GPU / temperature source | `macmon` child, JSON over a pipe | `src/sensors.c` linked in | — |
| External dependencies | Rust `macmon` binary must exist | none | — |

Per-process the new app does more than the old app *shell* did (0.263 % vs 0.164 %) — the
sampling work moved inside — but the **total** cost of ownership drops by a third, and the
~9 MiB child plus its failure modes (missing binary, parse churn, second process to
supervise) disappear. Readout parity with `macmon` is verified sample-by-sample in
[docs/macmon.md](macmon.md#readout-parity-with-macmon): temperatures are bit-identical,
GPU utilisation matches to within sampling-window jitter.

### Where the memory goes

| Route | Breakdown |
|---|---|
| Terminal | Terminal.app 72.2 MiB + `macmon` TUI 2.7 MiB |
| CoreBar, closed | **single process ≈ 13 MiB** (Swift runtime + AppKit + the C sensor module linked in) |
| CoreBar, open | ≈ 20 MiB (the +7.5 MiB is the menu window + panel backing store, created on first open) |

Opening the menu for the first time costs about **7.5 MiB** (bare-binary measurement 12.1 → 19.6 MiB): the menu window and the panel's backing store only exist once you click the icon. Opening it repeatedly costs nothing further. With the JSON-pipe `macmon` child gone there is no per-2-second parse churn, so long-running instances no longer creep upward from allocation fragmentation.

### What each menu toggle costs

The display toggles cost **nothing measurable**. Comparing separate processes doesn't work — baseline `footprint` drifts ±150 KB between runs, larger than the effect — so instead the app flips one feature ON/OFF every 5 s *inside a single process*, and `ri_phys_footprint` is sampled every 0.5 s, each sample tagged by the actual phase. The shared baseline cancels; only the toggle's own effect survives.

| Toggle | RAM Δ | CPU Δ | What actually changes |
|---|---|---|---|
| Per-core bars | 0 B | < ±0.04 pp | panel +36 pt taller, only while expanded |
| Temperature in menu bar | 0 B | < ±0.04 pp | status bar +48 pt wider (the "99°C" readout) |
| Gauges in menu bar | 0 B | < ±0.04 pp | status bar +81 pt wider, 6 extra rounded rects/frame |
| Colour-code percentages | 0 B | < ±0.04 pp | 3 extra `NSColor`s per frame, transient |
| Refresh interval | 0 B | ±0.1 pp | fixed-size buffers; moves CPU, not memory |

40–70 samples per phase, repeated for every toggle. RAM Δ is exactly **0 bytes** because `MeterView` draws with `draw(_:)` into the menu bar on every frame — no `wantsLayer`, no persistent layer backing store — so a wider bar is *more drawing*, not more allocated memory. (The self-drawn menu rows themselves cost about **+0.5 MiB** — more than any single toggle they sit next to. These labels used to be printed at the right edge of each row; since 0.3.1 the column is gone, because every entry read "RAM ≈ 0" and a column of zeros is width without information. The measurements live here instead.) The big footprint win came from removing the `macmon pipe` child process entirely, which is now a single-process app.

### Refresh interval

1 / 2 / 5 s in the menu; **2 s is the default**. Re-measured on the current single-process
build (2026-10-20), two 20-second runs each — the interval was switched by rebuilding a
throwaway copy with a different default, since the menu itself needs a click:

| Interval | CPU (single process) | Memory | vs. default |
|---|---|---|---|
| 1 s | 0.36 % | 13.0 MiB | ≈ +37 % |
| **2 s (default)** | **0.26 %** | 12.9 MiB | — |
| 5 s | 0.07 % | 12.9 MiB | ≈ −73 % |

Memory is flat across intervals — the buffers are fixed size. CPU scales with the sampling
rate, but at this scale run-to-run noise is ±0.05 pp, so treat the *shape* (faster = more CPU,
same RAM) as the finding, not the third digit. Moving the default from 1 s to 2 s — what 0.2.8
did — is worth roughly a third of the app's CPU. (Previously the total was 0.740 % because a
`macmon pipe` child added another 0.445 %; that child is gone.)

### Cost decomposition

The app broken into removable blocks, each measured (menu closed, 1 s baseline — i.e. the *old* default; at 2 s every row roughly halves):

| Component | CPU | Notes |
|---|---|---|
| Status-bar `MeterView` redraw + status-item compositing | ≈ 0.17 % | **the single most expensive piece** — more than all four trend charts combined |
| C sensor tick (libIOReport GPU + SMC/IOHID temp, in-process) | ≈ 0.10 % | measured standalone: the full sensor loop (GPU delta + 57 SMC key reads) at the 2 s cadence costs 0.103 % of a core including its timer wakeup — vs. the old child's 0.228 % |
| Timers + AppKit floor | ≈ 0.04 % | an empty AppKit agent app costs 0.004 % by itself |

The open-menu increment (0.315 %) breaks down further: trend-chart data paths 0.130 %, per-core bars 0.022 %, menu event tracking and panel compositing 0.163 %.

**GPU: 0.000 %.** CoreBar is a pure AppKit 2D app, rasterized on the CPU, with panel compositing billed to WindowServer. "Reducing GPU usage" is not a thing that exists for this app.

### Power

Whole-machine power draw cannot resolve an app this small. In a three-way A/B — nothing running, menu bar running, menu bar plus a Terminal window — the three measured **10.41 W / 10.33 W / 10.38 W**, while run-to-run noise alone was **±0.71 W**. So the numbers below are derived from measured CPU time using a calibration taken on the same machine:

- idle: 8.60 W
- 12 threads at 100 %: 19.13 W
- ⇒ **10.53 W per 100 % of the 12-core package** (≈ 0.105 W per percentage point)

| State | CPU time | Incremental power | Energy per minute |
|---|---|---|---|
| Menu bar resident, menu **not** clicked (2 s default) | 0.26 core-s/min | ≈ 2.3 mW | ≈ 0.14 J |
| Menu open, 4 charts + 12 core bars redrawing every 2 s | 0.33 core-s/min | ≈ 3.3 mW | ≈ 0.20 J |

Power is linearly extrapolated from the calibration, i.e. an **upper bound**: a 0.26 % duty cycle never actually ramps core frequency, so the true increment is lower.

**Is there a difference? Yes in relative terms, no in absolute ones.** Opening the menu does about 27 % more work, worth ≈1.0 mW — still ≈700× below the ±0.71 W noise floor of whole-machine measurement, and about 0.04 % of the machine's idle draw. For scale, a minute of ordinary web browsing pushes whole-machine draw up by a few watts, on the order of 100 – 200 J per minute; this app costs 0.14 – 0.20 J.

Run continuously for a year the two states come to ≈20 Wh and ≈29 Wh — about 0.25 and 0.36 full charges on an 80 Wh battery, i.e. roughly **0.07 % / 0.10 % of a charge per day**. The practical meaning of these numbers is the electricity bill: a few cents a year.

> **Re-measurement note, 2026-10-13.** The re-measurement caught a unit bug in the tooling: `ri_user_time` / `ri_system_time` are in Mach ticks (41.6667 ns each on Apple Silicon), not nanoseconds; all three measuring scripts divided by `1e9`, **understating CPU time by 41.67×**. The fix was validated against a single-thread busy loop (which must read back ≈100 % of a core). Every number on this page comes from the corrected scripts.

---

## 中文

### 一句话结论

| | macOS | 终端路线（Terminal.app 里跑 macmon） | CoreBar 菜单收起 | CoreBar 菜单展开 |
|---|---|---|---|---|
| 内存（footprint） | — | ≈ **75 MiB** | **≈ 13 MiB（单进程）** | ≈ 20 MiB |
| CPU | — | ≈ 0.62% 单核 | ≈ **0.26%** 单核 | ≈ 0.28% 单核 |
| 增量功耗 | — | — | ≈ **2.3 mW** | ≈ 3.3 mW |

CoreBar 现在是**单进程**——不再有 `macmon pipe` 子进程（见 [docs/macmon.md](macmon.md)）。13 MiB 是整份 App（含 GPU/温度）的占用。与最后一个双进程构建（v0.2.9）同机同场实测（同一工具、同一会话、2 秒默认、菜单收起、各三轮 15 秒）：**21.4 MiB → 12.9 MiB（−40%）**，**0.392% → 0.263% 单核（−33%）**，进程数 2 → 1。明细见下文[「v0.3.0：子进程没了」](#v030-子进程没了)。

相比把 macmon 挂在终端窗口里，CoreBar 内存约为其**六分之一**（13 vs 75 MiB），CPU 只占零头，而且**零外部依赖**。

### v0.3.0：子进程没了

最后一个还在 shell 调 `macmon pipe` 的构建是 **v0.2.9**（tag `v0.2.9`，即随仓库分发的 `CoreBar-0.2.9.app.zip`）。两个构建在同一台机器、同一时段、同一工具（`tools/measure.swift`，`proc_pid_rusage` 的 `ri_phys_footprint`）下并排跑，2 秒默认间隔、菜单收起、各三轮 15 秒：

| | v0.2.9（App + `macmon pipe` 子进程） | v0.3.0（单进程 + 原生 C 传感器） | 变化 |
|---|---|---|---|
| 进程数 | 2 | **1** | −1 |
| 内存（footprint） | 21.4 MiB（App 12.4 + 子进程 9.0） | **12.9 MiB** | **−8.5 MiB（−40%）** |
| CPU（单核百分比） | 0.392%（App 0.164 + 子进程 0.228） | **0.263%** | **−0.129 个百分点（−33%）** |
| GPU / 温度来源 | `macmon` 子进程，JSON 走管道 | `src/sensors.c` 链接进 App | — |
| 外部依赖 | 必须存在 Rust `macmon` 二进制 | 无 | — |

单看主进程，新版比旧版的"外壳"做得更多（0.263% vs 0.164%）——采样工作搬进了进程内——但**总持有成本**降了三分之一，而且约 9 MiB 的子进程和它的一整串故障模式（二进制缺失、JSON 解析抖动、要多 supervising 一个进程）一起消失了。与 `macmon` 的读数一致性已逐样本验证，见 [docs/macmon.md](macmon.md#与-macmon-的读数一致性)：温度逐位相同，GPU 占用差异在采样窗口抖动范围内。

### 内存去哪了

| 路线 | 拆解 |
|---|---|
| 终端 | Terminal.app 72.2 MiB + macmon TUI 2.7 MiB |
| CoreBar（收起） | **单进程 ≈ 13 MiB**（Swift 运行时 + AppKit + 链接进来的 C 传感器模块） |
| CoreBar（展开） | ≈ 20 MiB（那 +7.5 MiB 是菜单窗口 + 面板位图，首次展开才创建） |

首次展开菜单约多花 **7.5 MiB**（裸二进制实测 12.1 → 19.6 MiB）：菜单窗口和面板位图只有点开后才存在。反复展开不再增长。去掉了每 2 秒解析 JSON 的 `macmon` 管道子进程后，长时间运行不再因分配碎片缓慢增长。

### 菜单里每个开关的代价

同一个二进制做 A/B：只翻一个开关，预热 9 秒后用 `ri_phys_footprint` 采 8 秒，各跑三轮。分辨率 0.1 MiB。

| 开关 | 代价 | 原因 |
|---|---|---|
| 显示每个核心 | < 0.1 MiB | 逐核 tick 本来就在采，开关只决定画不画 |
| 状态栏显示温度 | < 0.1 MiB | 温度由本进程 C 模块算好，开不开都一样 |
| 状态栏显示进度条 | < 0.1 MiB | 多画两个圆角矩形，不新增缓冲区 |
| 百分比颜色区分 | < 0.1 MiB | 选色时多一层分支 |
| 刷新间隔 | < 0.1 MiB | 缓冲区固定；这一项影响的是 CPU，不是内存 |

这些自绘菜单行本身要花约 **+0.5 MiB**——比它们旁边的任何一个开关都贵。行尾那列标注以前一直显示在这里，从 0.3.1 起已从界面移除：每一项都读作「内存≈0」，一整列零只是占宽度、没有信息量；测量数据保留在此页。这次最大的 footprint 收益来自彻底去掉 `macmon pipe` 子进程，整个 App 现在只有一个进程。

### 刷新间隔

菜单提供 1 / 2 / 5 秒，**默认 2 秒**。当前单进程构建实测（2026-10-20，每档两轮 20 秒；档位靠重建一份改了默认值的临时副本切换，因为点菜单需要 GUI 操作）：

| 间隔 | CPU（单进程） | 内存 | 对比默认 |
|---|---|---|---|
| 1 秒 | 0.36% | 13.0 MiB | ≈ +37% |
| **2 秒（默认）** | **0.26%** | 12.9 MiB | — |
| 5 秒 | 0.07% | 12.9 MiB | ≈ −73% |

内存在三档下完全持平——缓冲区大小固定。CPU 随采样频率缩放，但在这个量级上单轮噪声有 ±0.05 个百分点，所以请把「形状」（越快越费 CPU、内存不变）当作结论，不要纠结第三位小数。把默认从 1 秒改成 2 秒（0.2.8 的改动）大约省下三分之一的 CPU。（以前合计是 0.740%，因为 `macmon pipe` 子进程还另加了 0.445%；那个子进程已经没了。）

### 开销分解

把 App 拆成可移除的模块逐个实测（菜单收起、1 秒基线，即*旧*默认；2 秒时各行大约减半）：

| 组件 | CPU | 说明 |
|---|---|---|
| 状态栏 `MeterView` 重绘 + 状态项合成 | ≈ 0.17% | **单项最贵**，比四张趋势图加起来还贵 |
| C 传感器 tick（libIOReport GPU + SMC/IOHID 温度，进程内） | ≈ 0.10% | 单独实测：完整传感器循环（GPU delta + 57 个 SMC 键读取）按 2 秒节奏跑，含定时器唤醒共 0.103% 单核——旧子进程是 0.228% |
| 定时器 + AppKit 底噪 | ≈ 0.04% | 一个空的 AppKit 代理 App 本身只要 0.004% |

展开菜单的增量（0.315%）再拆：趋势图数据链路 0.130%、逐核柱 0.022%、菜单事件跟踪与面板合成 0.163%。

**GPU：0.000%。** CoreBar 是纯 AppKit 2D 应用，光栅化在 CPU 上完成，面板合成记在 WindowServer 头上。"降低 GPU 占用"这件事对它是伪命题。

### 功耗

整机功耗根本分辨不出这么小的 App。三路 A/B（什么都不跑 / 只跑菜单栏 / 菜单栏 + 一个终端窗口）实测 **10.41 W / 10.33 W / 10.38 W**，而单轮噪声就有 **±0.71 W**。所以下表由实测 CPU 时间结合同机标定换算：

- 空闲 8.60 W
- 12 线程满载 19.13 W
- ⇒ **整个 12 核封装满载 100% 约 10.53 W**（每百分点 ≈0.105 W）

| 状态 | CPU 时间 | 增量功耗 | 每分钟能耗 |
|---|---|---|---|
| 常驻但不点开菜单（2 秒默认） | 0.26 core-s/min | ≈ 2.3 mW | ≈ 0.14 J |
| 菜单展开，4 张图 + 12 根核柱每 2 秒重绘 | 0.33 core-s/min | ≈ 3.3 mW | ≈ 0.20 J |

功耗由标定线性外推，即**上界**：0.26% 的占空比根本不会把核心频率拉起来，真实增量只会更低。

**有没有差别？相对有，绝对没有。** 展开菜单多做约 27% 的功，值 ≈1.0 mW——仍比整机测量的 ±0.71 W 噪声低约 700 倍，约为整机空闲功耗的 0.04%。作为参照，一分钟普通网页浏览会把整机功耗顶高几瓦，量级是 100 – 200 J/分钟；这个 App 是 0.14 – 0.20 J。

连续跑一年，两种状态分别约 **20 Wh** 和 **29 Wh**——80 Wh 电池的 0.25 / 0.36 个满充，也就是每天约 **0.07% / 0.10% 一格电**。实际意义在电费上：一年几分钱。

> **2026-10-13 重测说明。** 这次重测顺带揪出工具链的一个单位 bug：`ri_user_time` / `ri_system_time` 的单位是 Mach tick（Apple Silicon 上 41.6667 ns），不是纳秒；三个测量脚本都按 `1e9` 除，**把 CPU 时间低估了 41.67 倍**。修正后用一个单线程忙循环验证（必须读回 ≈100% 单核）。本页所有数字均来自修正后的脚本。
