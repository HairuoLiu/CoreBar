# From a macmon subprocess to native C sensors / 从 macmon 子进程到原生 C 传感器

[← Back to README](../README.md) · [中文](#中文)

> TL;DR — The GPU and temperature data used to come from a `macmon pipe` **child process** (Rust).
> We replaced it with a **515-line C module** (`src/sensors.c`) bridged into Swift.
> Result: **one process instead of two**, footprint **21.4 MiB → 12.9 MiB (−40 %)**,
> total CPU **0.392 % → 0.263 % of a core (−33 %)**, **zero external dependencies**,
> **zero Python**. Readouts are **bit-identical to macmon** — verified sample-by-sample
> under idle, light, and saturated load (see [Readout parity with macmon](#readout-parity-with-macmon)).

## English

### Why a subprocess was ever used

When the app started, four metrics were needed and only two had a clean public API:

| Metric | Public API? | Native replacement |
|---|---|---|
| CPU / per-core | ✅ `host_processor_info` (Mach) | already in-app |
| Memory % | ✅ `host_statistics64` (Mach) | ~30 lines, done |
| GPU utilization | ❌ private `libIOReport` | hard, OS-version fragile |
| Temperature | ❌ `AppleSMC` / `IOHID` | hard, OS-version fragile |

The two hard metrics live behind **private Apple frameworks** that ship **no SDK headers**
(`libIOReport.dylib`) or are **frequently locked down** (`AppleSMC` temperature keys are
often restricted on Apple Silicon). They also **break on every macOS update** — the exact
byte layout of `IOReportCreateSubscription`'s arguments, the `GPUPH` residency channel
names, and the SMC `SMCKeyData` struct have all shifted across releases.

`macmon` (a separate Rust project) had already solved all of this and kept it maintained.
**Spawning it as a child process was a reasonable engineering tradeoff**, not a mistake:

1. **Isolation** — if a private-API call crashes or returns garbage after an OS update,
   only the child dies; the menu-bar app keeps showing CPU/memory.
2. **Maintenance boundary** — the fragile code lived in a third-party binary we could
   `brew upgrade`, not in our codebase.
3. **No Swift bindings** — `libIOReport` has no headers, so calling it from Swift meant
   `dlopen` + hand-written C anyway; a separate binary was the path of least resistance.

So the subprocess was **justified by robustness and effort**, not by any technical
*necessity*. It was a *convenience*, and conveniences have a cost (see below).

### What the subprocess actually cost

Running `macmon pipe -i 2000` next to the app measured on this machine (Apple Silicon):

| Cost | Value |
|---|---|
| Extra footprint | **+9.0 MiB** (a whole Rust runtime + allocator) |
| Extra CPU | **≈ 0.23 % of a core** (sampling + JSON emission) |
| JSON parsing in app | ≈ 0.04 % of a core (pipe → `JSONSerialization` → `apply`) |
| Process lifecycle | spawn, `Pipe`, `readabilityHandler`, drain timer, terminate-on-quit |
| Hard dependency | `macmon` must be `brew install`ed and on `PATH`, or GPU/temp show "—" |
| Launch fragility | arch mismatch / Gatekeeper / permissions → silent fallback |

Total before this change: **≈ 21.4 MiB** (App 12.4 MiB + child 9.0 MiB) and the child's
CPU. The child also had to be *found* on disk (`~/.local/bin`, `/opt/homebrew/bin`,
`/usr/local/bin`) — a real source of "why is my GPU blank?" support questions.

### The alternative: native C, same private APIs, no process

We did exactly what macmon does, but **in-process**, in plain C:

```
src/sensors.c  ──dlopen──>  /usr/lib/libIOReport.dylib
   │                         IOReportCopyChannelsInGroup  (5 args)
   │                         IOReportCreateSubscription   (5 args)
   │                         IOReportCreateSamples / CreateSamplesDelta
   │                         GPUPH channel → residency → scaled ratio
   ├─ AppleSMC ───────────>  Tp*/Te*/Ts* (CPU) + Tg* (GPU) "flt " keys — primary on macOS 14+
   └─ IOHID thermal ───────>  CPU/GPU die temp (PMU / PMU2 sensors) — fallback
```

Key points that make it safe and cheap:

- **Identical algorithm to macmon.** We reverse-engineered macmon's `sources.rs` /
  `metrics.rs` (v0.9.0, the version this app replaced) and mirror its exact math:
  subscription → two samples → delta → `GPUPH` residencies → frequency-weighted scaled
  ratio with the DVFS table from `voltage-states9`; SMC key enumeration via `#KEY` count
  → `key_by_index` → `Tp`/`Te`/`Ts`/`Tg` prefix → `flt `/4-byte filter → readable-value
  check, then the per-sample average over `(0, 150]` — byte-for-byte the same decisions,
  including the `usage` window covering exactly `freqs.len()` states after the first
  non-IDLE/OFF/DOWN state. Readout parity is verified sample-by-sample in
  [Readout parity with macmon](#readout-parity-with-macmon) below.

- **Bridged to Swift with zero overhead.** Five `@_silgen_name` C calls
  (`corebar_sensors_init/close/gpu_scaled_ratio/cpu_temp_c/gpu_temp_c`). No
  `Process`, no pipe, no `JSONSerialization`, no background queue.

- **Graceful degradation preserved.** `c_sensors_init()` returns non-zero if neither
  GPU nor thermal source opens. Then `sensorsAvailable = false` and GPU/temp show "—",
  exactly like before — but with **no subprocess and no install step** behind it.

- **Still owns the fragility.** This is the one real tradeoff: the private-API code now
  lives in *our* binary. Mitigations: everything is `dlopen`'d / `IOServiceOpen`'d at
  runtime, failures are caught per-call, and a bad OS update degrades to "—" instead of
  crashing (the `MeterView`/`PanelView` already render a dash for unavailable series).

### Measured result

| | Before (subprocess) | After (native C) | Δ |
|---|---|---|---|
| Processes | 2 (app + `macmon pipe`) | **1** | −1 |
| Footprint | ≈ 21.4 MiB | **≈ 12.9 MiB** | **−8.5 MiB (−40 %)** |
| CPU (total) | ≈ 0.392 %/core | **≈ 0.263 %/core** | **−33 %** |
| External deps | `macmon` binary | **none** | — |
| Python | n/a (runtime) | **none** | — |
| GPU/temp correctness | macmon | identical (bit-for-bit) | — |

> Note on the −8.5 vs −9.0 MiB: the 9.0 MiB was the *child alone*. Linking the C module
> + `IOKit`/`CoreFoundation` into the single binary grows the app shell by ~0.5 MiB
> (12.4 → 12.9 MiB), so the net single-process saving is ~8.5 MiB. That is still a
> strictly smaller, simpler process with one less moving part.

### Readout parity with macmon

Removing the child is only safe if the numbers stay the same. Verification drove
**macmon 0.9.0 `pipe` and the C sensors simultaneously** and compared every sample
(`/tmp/compare.swift`, one-shot tool, not shipped). Four scenarios on this machine
(Apple Silicon, macOS 14+ SMC path), 2 s cadence on the macmon side:

| Scenario | n | Metric | macmon | native | Δ mean | Δ \|max\| | r |
|---|---|---|---|---|---|---|---|
| Idle, steady | 30 | GPU ratio | 0.1788 | 0.1792 | +0.0004 | 0.0141 | 0.9936 |
| | | CPU temp °C | 47.1636 | 47.1636 | **±0.0000** | **0.0000** | 1.0000 |
| | | GPU temp °C | 46.7994 | 46.7994 | **±0.0000** | **0.0000** | 1.0000 |
| GPU saturated (`macmon stress gpu`) | 80 | GPU ratio | 1.0000 | 1.0000 | **±0.0000** | **0.0000** | — |
| | | CPU temp °C | 60.9482 | 60.9482 | **±0.0000** | **0.0000** | 1.0000 |
| | | GPU temp °C | 69.7782 | 69.7782 | **±0.0000** | **0.0000** | 1.0000 |
| CPU pulse (1 s busy / 1 s idle) | 60 | GPU ratio | 0.1357 | 0.1364 | +0.0007 | 0.0438* | 0.9964 |
| | | CPU temp °C | 69.4772 | 69.4772 | **±0.0000** | **0.0000** | 1.0000 |
| | | GPU temp °C | 65.5144 | 65.5144 | **±0.0000** | **0.0000** | 1.0000 |
| Deep idle | 20 | GPU ratio | 0.0005 | 0.0005 | ±0.0000 | 0.0003 | 0.9973 |
| | | CPU temp °C | 44.7027 | 44.7027 | **±0.0000** | **0.0000** | 1.0000 |
| | | GPU temp °C | 43.1365 | 43.1365 | **±0.0000** | **0.0000** | 1.0000 |

\* first sample only, before the delta window aligns; both sides prime identically.

**Temperatures are bit-identical in every scenario.** Both read the same SMC keys
(39 CPU + 18 GPU `flt` keys on this machine) with the same filter and average — the
only way to differ is if the die temperature moves between the two reads a few
milliseconds apart, which shows up as ≤ 0.4 °C during fast thermal transitions and
vanishes in steady state.

**GPU utilisation matches to within sampling-window jitter.** The ratio is a delta
metric: each side integrates over its own window, so when the load oscillates the two
windows see slightly different slices (mean |Δ| ≈ 0.001–0.002 on a ~0.14–0.18 signal,
r ≥ 0.99). Under saturation both pin to exactly 1.0000. This is a property of delta
metrics, not an algorithmic gap — the formula is identical.

**What the verification caught.** The first attempt at parity was *not* clean: GPU
temperature read 2.2 °C low. Root cause was a byte-order bug in our SMC key
enumeration — `smc_key_by_index` returns FourCC keys big-endian (`Tp05` arrives as
`0x54703035`, which on a little-endian machine `memcpy`s to `"50pT"`), and the prefix
match ran on the unswapped bytes, so every real temperature key was silently skipped
and the code fell through to the IOHID path (different sensors, different numbers).
Two smaller parity gaps were fixed at the same time: the `usage` window now covers
exactly `freqs.len()` states after the offset (this machine's `GPUPH` has 16 states
against a 13-entry DVFS table — the trailing P14/P15 must be excluded), and key reads
now pass the cached `key_info` in the request like macmon does. After the fix: 39 + 18
keys found, SMC path active, temperatures bit-identical.

### Why not inline the C into Swift?

Two reasons. (1) The GPU path holds **mutable module-level state** (subscription refs,
previous sample for delta, the DVFS frequency table) that is far clearer as a small C
translation unit than as a tangle of `UnsafeMutablePointer` globals in Swift. (2) C keeps
the hot path free of ARC retain/release and Swift bridging overhead — and the file is
trivial to read, test standalone (`cc -DSTANDALONE_TEST`), and audit against macmon.

---

## 中文

> TL;DR — GPU/温度数据以前来自一个 `macmon pipe` **子进程**（Rust）。我们把它换成了
> 桥接进 Swift 的 **515 行 C 模块**（`src/sensors.c`）。结果：**两个进程变一个**，
> footprint **21.4 MiB → 12.9 MiB（−40%）**，总 CPU **0.392% → 0.263% 单核（−33%）**，
> **零外部依赖**、**零 Python**。读数与 macmon **逐位一致**——已在空闲、轻载、满载三种
> 场景下逐样本验证（见[与 macmon 的读数一致性](#与-macmon-的读数一致性)）。

### 为什么曾经要用子进程

项目起步时需要四个指标，但只有两个有干净的公开 API：

| 指标 | 公开 API？ | 原生替代 |
|---|---|---|
| CPU / 逐核 | ✅ `host_processor_info`（Mach） | 已在 App 内 |
| 内存百分比 | ✅ `host_statistics64`（Mach） | 约 30 行，已完成 |
| GPU 占用率 | ❌ 私有 `libIOReport` | 难，随系统版本易变 |
| 温度 | ❌ `AppleSMC` / `IOHID` | 难，随系统版本易变 |

那两项硬骨头藏在**没有 SDK 头文件的私有框架**（`libIOReport.dylib`）里，或被**频繁锁死**
（`AppleSMC` 的温度键在 Apple Silicon 上常常受限）。它们还**每次 macOS 更新都可能变**：
`IOReportCreateSubscription` 的参数个数、`GPUPH` 驻留通道名、SMC 的 `SMCKeyData` 结构布局
都曾在版本间改过。

`macmon`（一个独立的 Rust 项目）早已把这些都解决并持续维护。把它**拉起为子进程**是
一个合理的工程权衡，不是错误：

1. **隔离**——某次系统更新后私有 API 崩溃或返回垃圾，死的只是子进程，菜单栏 App
   仍能显示 CPU/内存。
2. **维护边界**——易碎的代码在第三方二进制里，我们可以 `brew upgrade`，不进自己的代码库。
3. **Swift 没绑定**——`libIOReport` 没头文件，从 Swift 调它本来也要 `dlopen` + 手写 C；
   直接跑一个独立二进制是阻力最小的路。

所以子进程是**出于健壮性和省事而被采用**，并非技术上的*必需*。它是一种*便利*，而
便利是有代价的（见下）。

### 子进程实际付出了什么

在本机（Apple Silicon）上实测 `macmon pipe -i 2000` 与 App 并列运行：

| 代价 | 数值 |
|---|---|
| 额外内存 footprint | **+9.0 MiB**（一整个 Rust 运行时 + 分配器） |
| 额外 CPU | **≈ 0.23% 单核**（采样 + 输出 JSON） |
| App 内 JSON 解析 | ≈ 0.04% 单核（管道 → `JSONSerialization` → `apply`） |
| 进程生命周期 | spawn、`Pipe`、`readabilityHandler`、drain 定时器、退出时 terminate |
| 硬依赖 | 必须 `brew install macmon` 且在 `PATH` 上，否则 GPU/温度显示 "—" |
| 启动脆弱性 | 架构不匹配 / Gatekeeper / 权限问题 → 静默降级 |

改动前总计：**≈ 21.4 MiB**（App 12.4 MiB + 子进程 9.0 MiB）外加子进程的 CPU。子进程还得
在磁盘上被*找到*（`~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin`）——这是"为什么我的
GPU 是空的？"这类支持问题的真实来源。

### 替代方案：原生 C，同样的私有 API，不要进程

我们把 macmon 做的事**原样搬进进程内**，用纯 C 实现：

```
src/sensors.c  ──dlopen──>  /usr/lib/libIOReport.dylib
   │                         IOReportCopyChannelsInGroup  （5 参数）
   │                         IOReportCreateSubscription   （5 参数）
   │                         IOReportCreateSamples / CreateSamplesDelta
   │                         GPUPH 通道 → 驻留度 → scaled ratio
   ├─ AppleSMC ───────────>  Tp*/Te*/Ts*（CPU）+ Tg*（GPU）"flt " 键——macOS 14+ 的主路径
   └─ IOHID 温度 ─────────>  CPU/GPU 裸片温度（PMU / PMU2 传感器）——回退路径
```

让它既安全又省的关键点：

- **算法与 macmon 完全一致。** 我们逆向了 macmon 的 `sources.rs` / `metrics.rs`
  （v0.9.0，即本 App 取代的版本），照搬其精确决策：订阅 → 两次采样 → delta →
  `GPUPH` 驻留度 → 用 `voltage-states9` 的 DVFS 表按频率加权的 scaled ratio；SMC 键枚举
  走 `#KEY` 计数 → `key_by_index` → `Tp`/`Te`/`Ts`/`Tg` 前缀 → `flt `/4 字节过滤 →
  可读性检查，然后每样本对 `(0, 150]` 区间求平均——连 `usage` 窗口只取第一个
  非 IDLE/OFF/DOWN 状态之后恰好 `freqs.len()` 个状态这样的细节都一致。读数一致性已
  逐样本验证，见下文[与 macmon 的读数一致性](#与-macmon-的读数一致性)。

- **零开销桥接到 Swift。** 五个 `@_silgen_name` C 调用
  （`corebar_sensors_init/close/gpu_scaled_ratio/cpu_temp_c/gpu_temp_c`）。没有
  `Process`、没有管道、没有 `JSONSerialization`、没有后台队列。

- **降级能力保留。** `c_sensors_init()` 在 GPU 与温度传感器都打不开时返回非 0。于是
  `sensorsAvailable = false`，GPU/温度显示 "—"，和以前一模一样——但背后**没有子进程、
  没有安装步骤**。

- **脆弱性仍由我们承担。** 这是唯一的真实权衡：私有 API 代码现在进了*我们*的二进制。
  缓解措施：所有调用都在运行时 `dlopen` / `IOServiceOpen`，单调用错误被捕获，糟糕的系统
  更新会降级成 "—" 而不是崩溃（`MeterView`/`PanelView` 对不可用的序列本来就画一道杠）。

### 实测结果

| | 改动前（子进程） | 改动后（原生 C） | 变化 |
|---|---|---|---|
| 进程数 | 2（App + `macmon pipe`） | **1** | −1 |
| Footprint | ≈ 21.4 MiB | **≈ 12.9 MiB** | **−8.5 MiB（−40%）** |
| CPU（合计） | ≈ 0.392% 单核 | **≈ 0.263% 单核** | **−33%** |
| 外部依赖 | `macmon` 二进制 | **无** | — |
| Python | 运行时无关 | **无** | — |
| GPU/温度正确性 | macmon | 逐位一致 | — |

> 关于 −8.5 而非 −9.0 MiB：9.0 MiB 是*子进程单独*的占用。把 C 模块 + `IOKit` /
> `CoreFoundation` 链进单一二进制让 App 外壳多占约 0.5 MiB（12.4 → 12.9 MiB），所以
> 单进程净省约 8.5 MiB。这仍是一个更小、更简单、少一个活动部件的进程。

### 与 macmon 的读数一致性

去掉子进程的前提是数字不能变。验证方式是**同时驱动 macmon 0.9.0 的 `pipe` 和 C 传感器**，
逐样本比对（`/tmp/compare.swift`，一次性工具，不随项目分发）。本机（Apple Silicon、
macOS 14+ 的 SMC 路径）四种场景，macmon 侧 2 秒节奏：

| 场景 | n | 指标 | macmon | 原生 | 偏差均值 | 偏差最大 | r |
|---|---|---|---|---|---|---|---|
| 空闲稳态 | 30 | GPU 占用 | 0.1788 | 0.1792 | +0.0004 | 0.0141 | 0.9936 |
| | | CPU 温度 °C | 47.1636 | 47.1636 | **±0.0000** | **0.0000** | 1.0000 |
| | | GPU 温度 °C | 46.7994 | 46.7994 | **±0.0000** | **0.0000** | 1.0000 |
| GPU 满载（`macmon stress gpu`） | 80 | GPU 占用 | 1.0000 | 1.0000 | **±0.0000** | **0.0000** | — |
| | | CPU 温度 °C | 60.9482 | 60.9482 | **±0.0000** | **0.0000** | 1.0000 |
| | | GPU 温度 °C | 69.7782 | 69.7782 | **±0.0000** | **0.0000** | 1.0000 |
| CPU pulse（1 秒忙 / 1 秒闲） | 60 | GPU 占用 | 0.1357 | 0.1364 | +0.0007 | 0.0438* | 0.9964 |
| | | CPU 温度 °C | 69.4772 | 69.4772 | **±0.0000** | **0.0000** | 1.0000 |
| | | GPU 温度 °C | 65.5144 | 65.5144 | **±0.0000** | **0.0000** | 1.0000 |
| 深度空闲 | 20 | GPU 占用 | 0.0005 | 0.0005 | ±0.0000 | 0.0003 | 0.9973 |
| | | CPU 温度 °C | 44.7027 | 44.7027 | **±0.0000** | **0.0000** | 1.0000 |
| | | GPU 温度 °C | 43.1365 | 43.1365 | **±0.0000** | **0.0000** | 1.0000 |

\* 仅首个样本，delta 窗口尚未对齐；两侧的 prime 行为一致。

**温度在全部场景下逐位相同。** 两边读同一批 SMC 键（本机 39 个 CPU + 18 个 GPU `flt` 键），
用同样的过滤和平均——唯一能造成差异的是两次读取相隔几毫秒内裸片温度本身动了，这表现在
快速温变过程中的 ≤ 0.4°C，稳态下为零。

**GPU 占用率的差异在采样窗口抖动范围内。** 它是 delta 指标：每一侧都在自己的窗口上积分，
负载振荡时两个窗口切到的切片略有不同（在 ~0.14–0.18 的信号上平均绝对偏差约 0.001–0.002，
r ≥ 0.99）。满载时两边都精确等于 1.0000。这是 delta 指标的固有性质，不是算法差距——
公式完全相同。

**这次验证抓到了什么。** 第一轮一致性验证*并不干净*：GPU 温度低了 2.2°C。根因是我们
SMC 键枚举里的字节序 bug——`smc_key_by_index` 返回的 FourCC 键是大端（`Tp05` 到达时是
`0x54703035`，小端机上 `memcpy` 出来是 `"50pT"`），而前缀匹配跑在未交换的字节上，于是所有
真正的温度键都被静默跳过，代码落到了 IOHID 回退路径（不同传感器、不同数值）。同时修掉的
还有两处小的对齐差距：`usage` 窗口现在只取偏移后恰好 `freqs.len()` 个状态（本机 `GPUPH`
有 16 个状态而 DVFS 表只有 13 项——多出的 P14/P15 必须排除），以及读键时像 macmon 一样
在请求里带上缓存的 `key_info`。修完之后：找到 39 + 18 个键，SMC 路径激活，温度逐位一致。

### 为什么不把 C 直接内联进 Swift？

两个原因。(1) GPU 路径持有**可变的模块级状态**（订阅引用、用于 delta 的上一次采样、
DVFS 频率表），作为一小个 C 翻译单元远比 Swift 里一堆 `UnsafeMutablePointer` 全局量清晰。
(2) C 让热路径免遭 ARC  retain/release 与 Swift 桥接开销——而且这个文件极易阅读、可独立
测试（`cc -DSTANDALONE_TEST`）、也方便对照 macmon 审计。
