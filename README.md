# MacMonBar

A native macOS menu-bar front end for [macmon](https://github.com/vladkens/macmon) — CPU, GPU, memory and temperature at a glance, plus per-core utilization for **every** core on the chip.

One status-bar item. Four trend charts. One 540-line Swift file. **Zero third-party dependencies.**

[中文说明 →](./README.zh-CN.md)

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

## Why

`macmon` is an excellent sudoless Apple Silicon monitor, but it lives in a terminal. Running it in Terminal.app keeps a window, a tab, a login shell and a scrollback buffer alive — four times the monitor's own memory; in CPU terms the two are actually even (both under 1 % of a core).

| Route | Physical footprint | Notes |
|---|---|---|
| `macmon` in Terminal.app | **≈ 75 MiB** | Terminal.app 72.2 MiB + `macmon` TUI 2.7 MiB |
| MacMonBar, menu closed | **≈ 18.5 MiB** | 12.9 MiB app + 5.6 MiB `macmon pipe` child |
| MacMonBar, menu open | **≈ 24 MiB** | ≈ 18 MiB app (+5 on first open) + 5.6 MiB child |

The menu bar is also the only one of the three "widget" options that can actually refresh at 1 Hz. Desktop widgets and Notification-Center widgets are the **same** WidgetKit technology: timeline-driven and throttled to roughly minute granularity, unable to sample on their own, and they require a host app plus an App Group — so they end up *heavier* than the thing they wrap.

## Screenshots

Status bar (default — temperature hidden):

![status bar, light](docs/statusbar-light.png)

Status bar with temperature enabled:

![status bar with temperature, light](docs/statusbar-temp-light.png)

Expanded panel — 4 trend charts (2 × 2) + per-core bars:

![panel, light](docs/panel-light.png)

Same panel in dark mode:

![panel, dark](docs/panel-dark.png)

And if `macmon` is not installed — CPU and per-core still work, the rest degrades to `—` instead of a misleading `0 %`:

![status bar without macmon](docs/statusbar-no-macmon-light.png)

![panel without macmon](docs/panel-no-macmon-light.png)

> These images are rendered by the app's own `draw(_:)` code against real sampled data, not composited screenshots — see [Reproducing the screenshots](#reproducing-the-screenshots).

## Features

- **Status bar** — compact CPU / GPU / memory bars with percentages. Temperature is optional and off by default.
- **Click to expand** — four full-width area charts in a 2 × 2 grid (CPU, GPU, memory, temperature), each with its current value on the header row, plus a per-core bar row underneath.
- **Every core is counted.** CPU utilization is sampled by the app itself through Mach `host_processor_info`, so all cores appear — 12 on an M6-class chip. The count is read from the kernel, never hard-coded.
- **CPU works without macmon.** The sampler runs on its own timer, so a missing macmon costs you GPU / memory / temperature and nothing else. Those three render as `—` rather than `0 %`, and the menu gains a one-click link to the install instructions.
- **No watts in the status bar.** The status bar is for utilization; wattage was deliberately left out because it does not change the decisions you make while coding.
- **Refresh interval** — 1 s / 2 s / 5 s, switchable from the menu.
- **Light and dark** aware, with semantic color thresholds (≥ 75 % turns red, ≥ 40 % amber).
- `LSUIElement` — no Dock icon, no window, nothing to switch to.
- **No dependencies.** AppKit + Foundation + Mach only. No SwiftPM, no Carthage, no SPM packages.

## Requirements

- macOS 13.0 or later, Apple Silicon (Intel is not supported — a menu-bar meter is pointless there).
- Xcode Command Line Tools (`swiftc`).
- [macmon](https://github.com/vladkens/macmon) installed at `~/.local/bin/macmon` — **required for GPU, memory and temperature; optional for CPU.** MacMonBar contains zero lines of macmon's code (it is a clean-room Swift reimplementation) but it shells out to the `macmon` binary at runtime for those three metrics. CPU utilization and per-core data come from the app's own Mach sampler and work regardless.

## Build and run

```bash
git clone https://github.com/HairuoLiu/MacMonBar.git
cd MacMonBar
./build.sh          # compiles src/main.swift → ./MacMonBar.app
open MacMonBar.app
```

To start it at login: **System Settings → General → Login Items & Extensions → Open at Login → +** and pick `MacMonBar.app`. (It is `LSUIElement`, so it will not appear in the Dock or the app switcher.)

### Installing macmon

```bash
brew install macmon
```

or, if you prefer no package manager, drop the prebuilt arm64 binary from the [releases page](https://github.com/vladkens/macmon/releases) into `~/.local/bin` and make sure that directory is on your `PATH`. MacMonBar spawns `macmon pipe -i <interval>` as a child process and reads its JSON line by line; it does not shell out through a terminal.

## How it works

```
  [macmon installed]  macmon pipe -i 1000  (child Process)
                      stdout JSON  ->  gpu_scaled_ratio
                                      ->  memory.ram_usage / ram_total
                                      ->  temp.cpu_temp_avg
                                          |
                                          +--> GPU / memory / temperature
                                          |     (macmon missing -> these show "—")

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

**CPU utilization is computed locally, not taken from macmon.** macmon's `cpu_usage_pct` is a *frequency-weighted residency* metric — how much time a core spends at a given DVFS operating point — not "is the core busy". Under a 12-thread all-core load the two disagree by a factor of ~1.7:

| Load | Mach `host_processor_info` | macmon `cpu_usage_pct` |
|---|---|---|
| idle | 21.4 % | — |
| 4 busy threads | 44.6 % | — |
| 6 busy threads | 59.9 % | — |
| **12 busy threads (all cores)** | **99.3 %** | **59.0 %** |

For a utilization meter the second column is the one you want. `tools/cputest.swift` reproduces this table; `tools/coretest.swift` prints per-core values and was cross-checked against `mactop`'s `core_usages` (agreement within 1 – 3 percentage points).

### One non-obvious bug worth knowing about

`NSMenu` opens a nested event loop in `NSEventTrackingRunLoopMode`. Blocks submitted with `DispatchQueue.main.async` are **not** dispatched in that mode, so the obvious implementation — pipe handler → `DispatchQueue.main.async` → redraw — leaves the panel frozen at the moment you click the icon.

Measured directly: over 25 seconds with the menu open, the background queue received 24 samples while only 3 `ingest` calls and 1 redraw ever ran.

The fix is to hand the raw bytes to the main thread through a `Timer` added to `RunLoop.main` in `.common` mode, which *is* serviced during event tracking:

```swift
RunLoop.main.add(t, forMode: .common)
```

After the fix the same 25-second window yields `bg=24 main=24 panelDraw=23` — the panel genuinely rasterizes once per second while the menu is open. This is also why the power numbers below are believable: the drawing work is real, not skipped.

## Relationship to macmon

Everyone asks this, so it gets its own section: **no macmon code is used.** Not a fork, not a vendored library, not a linked dependency. MacMonBar is 543 lines of Swift written from scratch; macmon is written in Rust. There is no Rust anywhere in this repository, and nothing here calls into it.

The entire relationship is that MacMonBar spawns `macmon pipe -i <interval>` as a child process and reads its JSON.

| Metric | Where the number comes from | macmon's code? |
|---|---|---|
| CPU utilization | `CPUCoreSampler` → Mach `host_processor_info` (Apple API) | No |
| Per-core utilization | same sampler | No |
| GPU utilization | `gpu_scaled_ratio` in macmon's JSON | No — but computed by the macmon binary |
| Memory % | `ram_usage` / `ram_total` in macmon's JSON | No |
| Temperature | `cpu_temp_avg` in macmon's JSON | No |

### Why the dependency stays

Two of the four metrics are trivial to replace natively. Two are not.

| Metric | Native replacement | Effort |
|---|---|---|
| CPU / per-core | already native — runs on its own timer | done |
| Memory | `host_statistics64` + `vm_statistics64` | ~30 lines, easy |
| GPU utilization | IOReport private framework | hard, breaks across OS releases |
| Temperature | no public API — IOHID / SMC | hard, breaks across OS releases |

The two hard ones are precisely what macmon already solves, and they are precisely the ones that break on every macOS update. Reimplementing them would trade a 9 MiB child process for a permanent maintenance burden — and would make the app *less* reliable, not more.

Until 0.2.0 the coupling was worse than it looks: `cpuSampler.sample()` was only ever called from `apply()`, which only ran when a complete JSON line arrived from macmon's pipe. With macmon absent the whole app froze at 0 % — CPU included. The sampler now has its own `Timer`, so the dependency is honestly scoped to the three metrics it actually supplies.

The name stays for the same reason: `MacMonBar` says what it is, a menu bar for macmon. Renaming it while still shelling out to macmon would be less honest, not more.

(Licensing-wise there is no obligation either way: MIT only requires the notice be retained in copies of *the software*, and none of it ships here. macmon is credited anyway.)

## Measured resource usage

Machine: Apple M6, 32 GB, macOS 13-era SDK. Physical footprint measured via `libproc`'s `proc_pid_rusage` (`ri_phys_footprint`), not RSS — footprint is the correct cross-process memory metric on macOS.

> **Full re-measurement, 2026-10-13.** The re-measurement also caught a unit bug in the tooling: `ri_user_time` / `ri_system_time` are in Mach ticks (41.6667 ns each on Apple Silicon), not nanoseconds; all three measuring scripts had divided by `1e9` as if they were nanoseconds, **understating CPU time by 41.67×**. The fix was validated against a single-thread busy loop (which must read back ≈100 % of a core). Every number below comes from the corrected `tools/measure.py` and siblings.

| | Terminal route | MacMonBar, menu closed | MacMonBar, menu open |
|---|---|---|---|
| Resident memory | ≈ 75 MiB | 18.5 MiB | ≈ 24 MiB |
| CPU time | ≈ 0.62 % of a core | ≈ 0.75 % of a core | ≈ 1.05 % of a core |

Broken down: the terminal route is Terminal.app (0.225 % / 72.2 MiB) plus `macmon` in TUI mode (0.398 % / 2.7 MiB); the closed state is the app itself (0.30 % / 12.9 MiB) plus the `macmon pipe` child (0.465 % / 5.6 MiB); the open state is 0.585 % for the app plus ≈0.47 % for the child.

Opening the menu for the first time costs about **5 MiB** (bare-binary measurement 8.5 → 13.3 MiB): the menu window and the panel's backing store only exist once you click the icon. Opening it repeatedly costs nothing further (nine consecutive opens measured flat). Long-running instances grow slowly — a 1.5-hour-old instance sat at 21.0 MiB, presumably allocation fragmentation from the once-a-second JSON parsing.

### Power

Whole-machine power draw cannot resolve an app this small. In a three-way A/B — nothing running, menu bar running, menu bar plus a Terminal window — the three measured **10.41 W / 10.33 W / 10.38 W**, while run-to-run noise alone was **±0.71 W**. The menu bar's contribution is simply not distinguishable from zero at whole-machine resolution, so the numbers below are derived from measured CPU time instead, using a calibration taken on the same machine:

- idle: **8.60 W**
- 12 threads at 100 %: **19.13 W**
- ⇒ **10.53 W per 100 % of the 12-core package** (≈ 0.105 W per percentage point, ≈ 0.88 W per core at full tilt)

Each state was measured over 8-second-plus windows, multiple rounds (`tools/measure.py`):

| State | CPU time | Incremental power | Energy per minute |
|---|---|---|---|
| Menu bar resident, menu **not** clicked | 0.45 core-s/min | ≈ 6.6 mW | ≈ 0.40 J |
| Menu open, 4 charts + 12 core bars redrawing at 1 Hz | 0.63 core-s/min | ≈ 9.2 mW | ≈ 0.55 J |

Power is linearly extrapolated from the calibration, i.e. an **upper bound**: a 0.75 % duty cycle never actually ramps core frequency, so the true increment is lower.

**Is there a difference? Yes in relative terms, no in absolute ones.** Opening the menu does about **40 % more work**, worth ≈2.6 mW or ≈0.15 J per minute — still ≈**270× below** the ±0.71 W noise floor of whole-machine measurement, and about **0.03 % of the machine's idle draw**. For scale, a minute of ordinary web browsing pushes whole-machine draw up by a few watts, on the order of 100 – 200 J per minute; this app costs 0.4 – 0.55 J.

Run continuously for a year the two states come to ≈**58 Wh** and ≈**80 Wh** — about 0.7 and 1.0 full charges on an 80 Wh battery, or 0.16 / 0.22 Wh per day, i.e. roughly **0.2 % / 0.3 % of a charge per day**. The Mac mini is a desktop; the practical meaning of these numbers is the electricity bill: a few cents a year.

Most of the app's own cost is the `macmon pipe` child it spawns (0.465 % = 0.28 core-s/min, 62 % of the whole stack); second is the status-bar `MeterView` redrawing every second (≈0.20 %) — which costs more than all four trend charts combined. See below.

### Cost decomposition (measured, 2026-10-13)

The app broken into removable blocks, each measured (menu closed, 1 s refresh baseline):

| Component | CPU | Notes |
|---|---|---|
| `macmon pipe` child | 0.465 % | separate process; supplies GPU / memory / temperature |
| Status-bar `MeterView` redraw + status-item compositing | ≈ 0.20 % | **the single most expensive piece** — more than all 4 trend charts combined |
| JSON ingestion (pipe + parse + `apply` + sampling) | ≈ 0.04 % | |
| Timers + AppKit floor | ≈ 0.04 % | an empty AppKit agent app costs 0.004 % by itself |

Refresh interval (the menu already offers 1 / 2 / 5 s; measured):

| Interval | App | Child | Total | vs. default |
|---|---|---|---|---|
| 1 s (default) | 0.270 % | 0.465 % | 0.735 % | — |
| 2 s | 0.172 % | 0.235 % | 0.407 % | −45 % |
| 5 s | 0.123 % | 0.102 % | 0.225 % | −69 % |

The open-menu increment (0.315 %) breaks down further: trend-chart data paths 0.130 %, per-core bars 0.022 %, menu event tracking and panel compositing 0.163 %.

On GPU: MacMonBar itself measures **0.000 %** — it is a pure AppKit 2D app, rasterized on the CPU, with panel compositing billed to WindowServer. "Reducing GPU usage" is not a thing that exists for this app.

## Design notes

**Why the menu bar and not a widget.** Ranked by resource cost and complexity, the menu bar wins on memory (about a quarter of the Terminal route, 18.5 vs 75 MiB) and on purity of form: it is the only option that can sample at 1 Hz without keeping a whole terminal session alive, needs no host app, no App Group, and no timeline plumbing. In CPU terms the two routes are actually even — though the terminal route also pays a WindowServer bill for compositing its window that never shows up in the process table. A desktop or Notification-Center widget would be the *same* WidgetKit stack either way, just with extra ceremony.

**Charts, not text.** Percentages alone cannot show a trend. Four small multiples — one metric each, stacked — are used instead of two overlaid sparklines, because overlaid lines are unreadable when they cross. Each chart carries its current value inline on the header row, a 50 % dashed reference line, an 18 % area fill, and a dot on the latest sample.

**Color is semantic.** Blue for CPU, orange for GPU, green for memory, and a red/amber/green threshold ramp that is consistent across every element. In dark mode the hues are lightened so they keep their contrast.

**Fixed width.** The panel is 300 pt with 14 pt of padding on each side. A width chooser was removed — a monitor should have one good default, not a preference pane.

## Reproducing the screenshots

The images in `docs/` are not screen captures. They are produced by feeding real sampled data into the very same `PanelView` / `MeterView` `draw(_:)` code and rasterizing into an `NSBitmapImageRep`:

```swift
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
view.frame = NSRect(x: 0, y: 0, width: w, height: h)
view.draw(view.bounds)
```

This needs no screen-recording permission and cannot drift from what the app actually renders. To regenerate them, take `src/main.swift`, replace the `NSApplication.shared` bootstrap at the bottom with a collector that reads `macmon pipe -i 200` for ~26 seconds, then render the views at `scale: 2` (panel) and `scale: 3` (status bar) in both `.aqua` and `.darkAqua`.

The two `-no-macmon-` images are the same pipeline with `macmonAvailable = false` and the GPU / memory / temperature histories cleared — that is the degraded state, not a hand-edited mock-up.

## `tools/`

Small, single-purpose scripts — kept because every number in this README comes from one of them.

| File | Purpose |
|---|---|
| `cputest.swift` | Full-core CPU accuracy test: idle → 4 → 6 → 12 busy threads |
| `coretest.swift` | Prints per-core utilization; cross-validated against `mactop` |
| `machsampler.swift` | Pure Mach sampler — the zero-dependency baseline |
| `measure.py` | Per-pid CPU % / RSS / physical footprint via `libproc` |
| `measure_state.py` | CPU time of one state over N seconds |
| `power_ab.py` | The two-state power A/B used for the table above |

Compile any of them with `swiftc -O tools/<name>.swift -o /tmp/<name>`.

## Credits

- [macmon](https://github.com/vladkens/macmon) by vladkens — the sudoless Apple Silicon monitor this app fronts for. MIT.
- Per-core accuracy cross-checked against [mactop](https://github.com/context-labs/mactop).

## Changelog

### 0.2.1 — 2026-10-13

- **Fixed (tooling):** the three scripts under `tools/` treated `ri_user_time` / `ri_system_time` as nanoseconds and divided by `1e9`; the real unit is Mach ticks (41.6667 ns), so CPU time was understated 41.67×. Corrected via `mach_timebase_info` and validated against a single-thread busy loop. Every power / CPU figure in the README recomputed.
- **Docs:** new "Cost decomposition" section — per-component measurements (macmon child 0.465 %, status-bar redraw 0.20 %, JSON ingestion 0.04 %, AppKit floor 0.04 %) plus a 1 / 2 / 5 s refresh-interval comparison.

### 0.2.0 — 2026-10-13

- **Fixed:** with `macmon` absent the app froze at 0 % for *every* metric, CPU included, because `cpuSampler.sample()` was only reachable through macmon's JSON. CPU and per-core now run on an independent `Timer`.
- **Fixed:** GPU / memory / temperature now render `—` instead of a misleading `0 %` when their data source is missing.
- **Added:** a menu entry linking to macmon's install instructions, shown only when macmon is absent.
- **Removed:** dead code — `kLabel`, `CPUCoreSampler.coreCount`, `AppDelegate.latest` (all write-only or unused).

### 0.1.0 — 2026-10-13

- First release.

## License

MIT — see [LICENSE](./LICENSE).
