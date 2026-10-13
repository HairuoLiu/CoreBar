# MacMonBar

A native macOS menu-bar front end for [macmon](https://github.com/vladkens/macmon) — CPU, GPU, memory and temperature at a glance, plus per-core utilization for **every** core on the chip.

One status-bar item. Four trend charts. One 540-line Swift file. **Zero third-party dependencies.**

[中文说明 →](./README.zh-CN.md)

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

## Why

`macmon` is an excellent sudoless Apple Silicon monitor, but it lives in a terminal. Running it in Terminal.app keeps a window, a tab, a login shell and a scrollback buffer alive — and that costs far more than the monitor itself.

| Route | Physical footprint | Notes |
|---|---|---|
| `macmon` in Terminal.app | **97 – 121 MiB** | Terminal window + tab + shell + scrollback |
| MacMonBar, menu closed | **≈ 22 MiB** | 13.1 MiB app + 9.0 MiB `macmon pipe` child |
| MacMonBar, menu open | **≈ 29 MiB** | 20.1 MiB app + 9.0 MiB child |

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

> These images are rendered by the app's own `draw(_:)` code against real sampled data, not composited screenshots — see [Reproducing the screenshots](#reproducing-the-screenshots).

## Features

- **Status bar** — compact CPU / GPU / memory bars with percentages. Temperature is optional and off by default.
- **Click to expand** — four full-width area charts in a 2 × 2 grid (CPU, GPU, memory, temperature), each with its current value on the header row, plus a per-core bar row underneath.
- **Every core is counted.** CPU utilization is sampled by the app itself through Mach `host_processor_info`, so all cores appear — 12 on an M6-class chip. The count is read from the kernel, never hard-coded.
- **No watts in the status bar.** The status bar is for utilization; wattage was deliberately left out because it does not change the decisions you make while coding.
- **Refresh interval** — 1 s / 2 s / 5 s, switchable from the menu.
- **Light and dark** aware, with semantic color thresholds (≥ 75 % turns red, ≥ 40 % amber).
- `LSUIElement` — no Dock icon, no window, nothing to switch to.
- **No dependencies.** AppKit + Foundation + Mach only. No SwiftPM, no Carthage, no SPM packages.

## Requirements

- macOS 13.0 or later, Apple Silicon (Intel is not supported — a menu-bar meter is pointless there).
- Xcode Command Line Tools (`swiftc`).
- [macmon](https://github.com/vladkens/macmon) installed at `~/.local/bin/macmon` — it supplies GPU, memory and temperature. CPU utilization and per-core data do **not** depend on it.

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
                         ┌─────────────────────────────┐
   macmon pipe -i 1000  │  JSON lines on stdout        │
   (child Process) ────▶│  gpu_scaled_ratio            │────┐
                         │  memory.ram_usage / ram_total│    │
                         │  temp.cpu_temp_avg           │    │
                         └─────────────────────────────┘    │
                                                           ▼
   Mach host_processor_info ──▶ per-core user/system/nice/idle ticks
   (PROCESSOR_CPU_LOAD_INFO)      ▼
                                delta-based utilization
                                for ALL N cores ──▶ MeterView (status bar)
                                                  └▶ PanelView (expanded)
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

## Measured resource usage

Machine: Apple M6, 32 GB, macOS 13-era SDK. Physical footprint measured via `libproc`'s `proc_pid_rusage` (`ri_phys_footprint`), not RSS — footprint is the correct cross-process memory metric on macOS.

| | Terminal route | MacMonBar, menu closed | MacMonBar, menu open |
|---|---|---|---|
| Resident memory | 97 – 121 MiB | ≈ 22 MiB | ≈ 29 MiB |
| CPU time | ~0.07 % of a core | ~0.016 % of a core | ~0.023 % of a core |

Opening the menu costs about **7 MiB** (13.1 → 20.1 MiB): the menu window and the panel's backing store only exist once you click the icon. The `macmon pipe` child contributes a flat ~9 MiB either way.

### Power

Whole-machine power draw cannot resolve an app this small. In a three-way A/B — nothing running, menu bar running, menu bar plus a Terminal window — the three measured **10.41 W / 10.33 W / 10.38 W**, while run-to-run noise alone was **±0.71 W**. The menu bar's contribution is simply not distinguishable from zero at whole-machine resolution, so the numbers below are derived from measured CPU time instead, using a calibration taken on the same machine:

- idle: **8.60 W**
- 12 threads at 100 %: **19.13 W**
- ⇒ **10.53 W per 100 % of the 12-core package** (≈ 0.105 W per percentage point)

Each state was measured twice over 120-second windows (`tools/power_ab.py`):

| State | CPU time | Incremental power | Energy per minute |
|---|---|---|---|
| Menu bar resident, menu **not** clicked | 0.0092 – 0.0096 core-s/min | ≈ 0.14 mW | ≈ 0.008 J |
| Menu open, 4 charts + 12 core bars redrawing at 1 Hz | 0.0128 – 0.0145 core-s/min | ≈ 0.20 mW | ≈ 0.012 J |

**Is there a difference? Yes in relative terms, no in absolute ones.** Opening the menu does about **45 % more work** — the two ranges do not overlap — but that is ≈0.06 mW, or ≈0.004 J per minute. That is roughly **3,500× below the ±0.71 W noise floor** of whole-machine measurement, and about **0.002 % of the machine's idle draw**. For scale, a minute of ordinary web browsing pushes whole-machine draw up by a few watts, on the order of 100 – 200 J per minute; this app costs about 0.01 J.

Run continuously for a year the two states come to ≈1.2 Wh and ≈1.7 Wh — about 1.5 % and 2.2 % of one full charge on an 80 Wh battery.

The app's own cost is also dominated by the `macmon pipe` child it spawns (≈0.007 core-s/min), not by the drawing.

## Design notes

**Why the menu bar and not a widget.** Ranked by resource cost and complexity, the menu bar wins on every axis: it is the only option that can sample at 1 Hz, it needs no host app, no App Group, and no timeline plumbing, and it costs roughly a quarter of the Terminal route. A desktop or Notification-Center widget would be the *same* WidgetKit stack either way, just with extra ceremony.

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

## License

MIT — see [LICENSE](./LICENSE).
