# How it works / 工作原理

[← Back to README](../README.md) · [中文](#中文)

## English

### Data flow

```
  [macmon installed]  macmon pipe -i 2000   (child Process)
                      stdout JSON  ->  gpu_scaled_ratio
                                      ->  memory.ram_usage / ram_total
                                      ->  temp.cpu_temp_avg
                                          |
                                          +--> GPU / memory / temperature
                                          |     (macmon missing -> these show "—")
                                          |     (macmon fails to launch -> same)

  [always]            Timer @ intervalMs          Mach host_processor_info
                      independent heartbeat  -->  (PROCESSOR_CPU_LOAD_INFO)
                      does NOT wait on macmon          |
                                                       v
                                          per-core user/system/nice/idle ticks
                                                       |
                                                       v
                                          delta-based utilization
                                          for ALL N cores ---> MeterView (status bar)
                                                            -> PanelView (expanded)
```

The status bar is a custom `NSView` (`MeterView`) attached to the `NSStatusItem`'s button via `statusItem.button?.addSubview`. `statusItem.length = meter.preferredWidth` keeps its width exact — the width is computed from measured text metrics, not guessed.

### CPU utilization is computed locally, not taken from macmon

macmon's `cpu_usage_pct` is a *frequency-weighted residency* metric — how much time a core spends at a given DVFS operating point — not "is the core busy". Under a 12-thread all-core load the two disagree by a factor of ~1.7:

| Load | Mach `host_processor_info` (what MacMonBar uses) | macmon `cpu_usage_pct` |
|---|---|---|
| idle | 21.4 % | — |
| 4 busy threads | 44.6 % | — |
| 6 busy threads | 59.9 % | — |
| **12 busy threads (all cores)** | **99.3 %** | **59.0 %** |

For a utilization meter the first column is the one you want. `tools/cputest.swift` reproduces this table; `tools/coretest.swift` prints per-core values and was cross-checked against [mactop](https://github.com/context-labs/mactop)'s `core_usages` (agreement within 1 – 3 percentage points).

### One non-obvious bug worth knowing about

`NSMenu` opens a nested event loop in `NSEventTrackingRunLoopMode`. Blocks submitted with `DispatchQueue.main.async` are **not** dispatched in that mode, so the obvious implementation — pipe handler → `DispatchQueue.main.async` → redraw — leaves the panel frozen the moment you click the icon.

Measured directly: over 25 seconds with the menu open, the background queue received 24 samples while only 3 `ingest` calls and 1 redraw ever ran.

The fix is to hand the raw bytes to the main thread through a `Timer` added to `RunLoop.main` in `.common` mode, which *is* serviced during event tracking:

```swift
RunLoop.main.add(t, forMode: .common)
```

After the fix the same 25-second window yields `bg=24 main=24 panelDraw=23` — the panel genuinely rasterizes once per second while the menu is open. This is also why the measured power numbers are believable: the drawing work is real, not skipped.

### Where the numbers come from

| Metric | Source | macmon's code? |
|---|---|---|
| CPU utilization | `CPUCoreSampler` → Mach `host_processor_info` (Apple API) | No |
| Per-core utilization | same sampler | No |
| GPU utilization | `gpu_scaled_ratio` in macmon's JSON | No — but computed by the macmon binary |
| Memory % | `ram_usage` / `ram_total` in macmon's JSON | No |
| Temperature | `cpu_temp_avg` in macmon's JSON | No |

---

## 中文

### 数据流

```
  [装了 macmon]        macmon pipe -i 2000   （子进程）
                      stdout JSON  ->  gpu_scaled_ratio
                                      ->  memory.ram_usage / ram_total
                                      ->  temp.cpu_temp_avg
                                          |
                                          +--> GPU / 内存 / 温度
                                          |     （macmon 缺失 → 显示 "—"）
                                          |     （macmon 起不来 → 同样）

  [始终运行]           Timer @ intervalMs         Mach host_processor_info
                      独立心跳              -->  (PROCESSOR_CPU_LOAD_INFO)
                      不等待 macmon                 |
                                                    v
                                      逐核 user/system/nice/idle tick
                                                    |
                                                    v
                                       基于差值的占用率
                                       覆盖全部 N 核 ---> MeterView（状态栏）
                                                     -> PanelView（展开面板）
```

状态栏是一个自定义 `NSView`（`MeterView`），通过 `statusItem.button?.addSubview` 贴到 `NSStatusItem` 的按钮上；`statusItem.length = meter.preferredWidth` 让宽度精确——宽度由实测字体度量算出，不是猜的。

### CPU 占用率是本机算的，不取 macmon

macmon 的 `cpu_usage_pct` 是**频率加权的驻留度**——核心在某个 DVFS 工作点上待了多久——而不是"核心忙不忙"。12 线程全核加载下两者差约 1.7 倍：

| 负载 | Mach `host_processor_info`（MacMonBar 用这个） | macmon `cpu_usage_pct` |
|---|---|---|
| 空闲 | 21.4% | — |
| 4 线程忙 | 44.6% | — |
| 6 线程忙 | 59.9% | — |
| **12 线程全核忙** | **99.3%** | **59.0%** |

做占用率表盘，第一列才是你要的。`tools/cputest.swift` 可复现该表；`tools/coretest.swift` 打印逐核值，并已与 [mactop](https://github.com/context-labs/mactop) 的 `core_usages` 交叉验证（差异在 1–3 个百分点内）。

### 一个值得知道的坑

`NSMenu` 会在 `NSEventTrackingRunLoopMode` 里开一个嵌套事件循环。用 `DispatchQueue.main.async` 投递的 block 在这个模式下**不会被派发**，所以最直观的写法——管道回调 → `DispatchQueue.main.async` → 重绘——会让你一点开图标面板就冻住。

实测：菜单展开的 25 秒里，后台队列收到 24 个样本，但只发生了 3 次 `ingest` 和 1 次重绘。

修法是把原始字节通过一个挂在 `RunLoop.main` 且模式为 `.common` 的 `Timer` 交回主线程——该模式在事件跟踪期间仍会被服务：

```swift
RunLoop.main.add(t, forMode: .common)
```

修复后同样 25 秒窗口得到 `bg=24 main=24 panelDraw=23`——菜单展开时面板确实每秒真实重绘一次。这也是功耗数字可信的原因：绘制工作是真的发生了，没有被跳过。

### 数据来源

| 指标 | 来源 | 用了 macmon 的代码吗 |
|---|---|---|
| CPU 占用率 | `CPUCoreSampler` → Mach `host_processor_info`（Apple 公开 API） | 否 |
| 逐核占用率 | 同上 | 否 |
| GPU 占用率 | macmon JSON 里的 `gpu_scaled_ratio` | 否，但由 macmon 二进制算出 |
| 内存百分比 | macmon JSON 里的 `ram_usage` / `ram_total` | 否 |
| 温度 | macmon JSON 里的 `cpu_temp_avg` | 否 |
