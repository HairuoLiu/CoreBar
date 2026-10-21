# How it works / 工作原理

[← Back to README](../README.md) · [中文](#中文)

## English

### Data flow

```
  [always, in-process]   sampler Timer @ intervalMs  (RunLoop .common mode)
        |
        |-- CPU / per-core : Mach host_processor_info (PROCESSOR_CPU_LOAD_INFO)
        |                       per-core user/system/nice/idle ticks -> delta utilization
        |
        |-- Memory %        : Mach host_statistics64 (vm_statistics64)
        |
        |-- GPU %           : C bridge -> libIOReport  ("GPU Stats" residency -> scaled ratio)
        |                       @_silgen_name("corebar_gpu_scaled_ratio")
        |
        `-- Temperature     : C bridge -> AppleSMC (flt keys) or IOHID thermal fallback
                                @_silgen_name("corebar_cpu_temp_c" / "corebar_gpu_temp_c")
                                        |
                                        v
                          MeterView (status bar)  ->  PanelView (expanded panel)
```

There is **no child process and no JSON pipe** — the Swift side calls five C functions
declared with `@_silgen_name` and reads the values directly. If the C sensor module fails
to initialize (e.g. a future macOS locks down the private APIs), `sensorsAvailable` is
`false` and GPU / temperature simply render as "—"; CPU / memory keep working.

The status bar is a custom `NSView` (`MeterView`) attached to the `NSStatusItem`'s button via `statusItem.button?.addSubview`. `statusItem.length = meter.preferredWidth` keeps its width exact — the width is computed from measured text metrics, not guessed.

### CPU utilization is computed locally, not taken from macmon

macmon's `cpu_usage_pct` is a *frequency-weighted residency* metric — how much time a core spends at a given DVFS operating point — not "is the core busy". Under a 12-thread all-core load the two disagree by a factor of ~1.7:

| Load | Mach `host_processor_info` (what CoreBar uses) | macmon `cpu_usage_pct` |
|---|---|---|
| idle | 21.4 % | — |
| 4 busy threads | 44.6 % | — |
| 6 busy threads | 59.9 % | — |
| **12 busy threads (all cores)** | **99.3 %** | **59.0 %** |

For a utilization meter the first column is the one you want. `tools/cputest.swift` reproduces this table; `tools/coretest.swift` prints per-core values and was cross-checked against [mactop](https://github.com/context-labs/mactop)'s `core_usages` (agreement within 1 – 3 percentage points).

### One non-obvious bug worth knowing about

`NSMenu` opens a nested event loop in `NSEventTrackingRunLoopMode`. Blocks submitted with `DispatchQueue.main.async` are **not** dispatched in that mode, so the obvious implementation — background sampler → `DispatchQueue.main.async` → redraw — leaves the panel frozen the moment you click the icon.

The fix is to drive the whole UI from a single `Timer` added to `RunLoop.main` in `.common` mode, which *is* serviced during event tracking:

```swift
RunLoop.main.add(t, forMode: .common)
```

That one timer calls `tick()`, which samples CPU / memory (Mach) **and** GPU% / temperature (the C bridge) and repaints. The panel genuinely rasterizes every interval while the menu is open, which is also why the measured power numbers are believable: the drawing work is real, not skipped.

### Where the numbers come from

| Metric | Source | External code? |
|---|---|---|
| CPU utilization | `CPUCoreSampler` → Mach `host_processor_info` (Apple API) | No |
| Per-core utilization | same sampler | No |
| GPU utilization | `corebar_gpu_scaled_ratio` → `libIOReport` (private, `dlopen`) | No — implemented in `src/sensors.c` |
| Memory % | `MemorySampler` → Mach `host_statistics64` | No |
| Temperature | `corebar_cpu_temp_c` / `corebar_gpu_temp_c` → AppleSMC / IOHID | No — implemented in `src/sensors.c` |

---

## 中文

### 数据流

```
  [始终，进程内]        采样 Timer @ intervalMs  （RunLoop .common 模式）
        |
        |-- CPU / 逐核 : Mach host_processor_info（PROCESSOR_CPU_LOAD_INFO）
        |                  逐核 user/system/nice/idle tick → 差值占用率
        |
        |-- 内存 %       : Mach host_statistics64（vm_statistics64）
        |
        |-- GPU %        : C 桥接 → libIOReport（"GPU Stats" 驻留度 → scaled ratio）
        |                   @_silgen_name("corebar_gpu_scaled_ratio")
        |
        `-- 温度         : C 桥接 → AppleSMC（flt 键）或 IOHID 温度回退
                            @_silgen_name("corebar_cpu_temp_c" / "corebar_gpu_temp_c")
                                        |
                                        v
                          MeterView（状态栏）  ->  PanelView（展开面板）
```

**没有子进程，也没有 JSON 管道**——Swift 这边直接调五个用 `@_silgen_name` 声明的 C 函数读值。
若 C 传感器模块初始化失败（例如未来 macOS 锁死了私有 API），`sensorsAvailable` 为 `false`，
GPU / 温度就画成 "—"；CPU / 内存照常工作。

状态栏是一个自定义 `NSView`（`MeterView`），通过 `statusItem.button?.addSubview` 贴到 `NSStatusItem` 的按钮上；`statusItem.length = meter.preferredWidth` 让宽度精确——宽度由实测字体度量算出，不是猜的。

### CPU 占用率是本机算的，不取 macmon

macmon 的 `cpu_usage_pct` 是**频率加权的驻留度**——核心在某个 DVFS 工作点上待了多久——而不是"核心忙不忙"。12 线程全核加载下两者差约 1.7 倍：

| 负载 | Mach `host_processor_info`（CoreBar 用这个） | macmon `cpu_usage_pct` |
|---|---|---|
| 空闲 | 21.4% | — |
| 4 线程忙 | 44.6% | — |
| 6 线程忙 | 59.9% | — |
| **12 线程全核忙** | **99.3%** | **59.0%** |

做占用率表盘，第一列才是你要的。`tools/cputest.swift` 可复现该表；`tools/coretest.swift` 打印逐核值，并已与 [mactop](https://github.com/context-labs/mactop) 的 `core_usages` 交叉验证（差异在 1–3 个百分点内）。

### 一个值得知道的坑

`NSMenu` 会在 `NSEventTrackingRunLoopMode` 里开一个嵌套事件循环。用 `DispatchQueue.main.async` 投递的 block 在这个模式下**不会被派发**，所以最直观的写法——后台采样 → `DispatchQueue.main.async` → 重绘——会让你一点开图标面板就冻住。

修法是让整个 UI 由**一个**挂在 `RunLoop.main` 且模式为 `.common` 的 `Timer` 驱动——该模式在事件跟踪期间仍会被服务：

```swift
RunLoop.main.add(t, forMode: .common)
```

这一个定时器调用 `tick()`，它采样 CPU / 内存（Mach）**以及** GPU% / 温度（C 桥接）并重绘。菜单展开时面板每个间隔都真实重绘，这也是功耗数字可信的原因：绘制工作是真的发生了，没有被跳过。

### 数据来源

| 指标 | 来源 | 用了外部代码吗 |
|---|---|---|
| CPU 占用率 | `CPUCoreSampler` → Mach `host_processor_info`（Apple 公开 API） | 否 |
| 逐核占用率 | 同上 | 否 |
| GPU 占用率 | `corebar_gpu_scaled_ratio` → `libIOReport`（私有，dlopen） | 否——实现在 `src/sensors.c` |
| 内存百分比 | `MemorySampler` → Mach `host_statistics64` | 否 |
| 温度 | `corebar_cpu_temp_c` / `corebar_gpu_temp_c` → AppleSMC / IOHID | 否——实现在 `src/sensors.c` |
