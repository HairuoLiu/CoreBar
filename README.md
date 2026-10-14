# MacMonBar

**CPU, GPU, RAM and temperature in your menu bar — one status item, four trend charts, every core on the chip.**

A hand-written 733-line Swift app with zero third-party dependencies. It costs **18.5 MiB and 0.43 % of a core** where keeping [macmon](https://github.com/vladkens/macmon) in a Terminal window costs **≈75 MiB**.

[中文说明 →](./README.zh-CN.md) · [Full feature list](docs/features.md) · [Changelog](CHANGELOG.md) · [**The talk →**](TALK.md)

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen) ![License](https://img.shields.io/badge/license-MIT-green)

![MacMonBar expanded panel](docs/panel-light.png)

![MacMonBar status bar](docs/statusbar-light.png)

---

## Performance at a glance

| | Terminal route | MacMonBar | Difference |
|---|---|---|---|
| Memory (footprint) | ≈ 75 MiB | **18.5 MiB** | **−75 %** |
| CPU (2 s refresh) | ≈ 0.62 % of a core | **0.43 %** of a core | −31 % |
| Incremental power | — | **≈ 3.8 mW** | ≈ 0.1 % of a charge per day |
| GPU | — | **0.000 %** | pure AppKit 2D, rasterized on the CPU |

Measured, not estimated — `ri_phys_footprint` via `libproc`, CPU time over 8-second-plus windows, multiple rounds. Full methodology, cost decomposition, refresh-interval table and the power calibration: **[docs/performance.md](docs/performance.md)**.

## Why MacMonBar

- **Honest CPU numbers.** CPU and per-core utilization are sampled by the app itself through Mach `host_processor_info`, so all cores appear and the count comes from the kernel. macmon's own `cpu_usage_pct` is a frequency-weighted residency metric: under a 12-thread all-core load it reports **59.0 %** where the true utilization is **99.3 %**. **[How →](docs/how-it-works.md)**
- **CPU keeps working if macmon is missing.** The sampler runs on its own timer, so a missing macmon costs you GPU / memory / temperature and nothing else — and those three render as `—` rather than a misleading `0 %`.
- **No Dock icon, no window, nothing to switch to.** `LSUIElement`, so it lives in the menu bar and nowhere else.
- **Zero dependencies, one source file.** AppKit + Foundation + Mach. No SwiftPM, no Carthage, no vendored code — and no macmon code either: it shells out to the `macmon` binary at runtime for GPU / memory / temperature. **[Why the dependency stays →](docs/macmon.md)**
- **Not a widget.** Menu bar is the only form that can sample at 2 Hz without keeping a terminal session alive, needs no host app and no App Group — WidgetKit is timeline-driven and throttled to minute granularity, so a widget ends up heavier than the thing it wraps.
- **Two disjoint colour systems.** Charts use identity hues (blue CPU, rose GPU, cyan memory, purple temperature); the numbers use value hues (green / amber / red by their own thresholds). A chart can never collide with a number wearing the same colour. **[Design notes →](docs/design.md)**

## Install

Requires macOS 13+ on Apple Silicon.

### Step 1 — macmon (do this first)

MacMonBar needs the `macmon` binary for GPU, memory and temperature:

```bash
brew install macmon
```

No Homebrew? Drop the prebuilt arm64 binary from [macmon's releases](https://github.com/vladkens/macmon/releases) into `~/.local/bin`. MacMonBar looks in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, in that order.

### Step 2 — MacMonBar

**Download** the latest release:

**[→ Download MacMonBar (macOS, Apple Silicon)](https://github.com/HairuoLiu/MacMonBar/releases/latest)**

Unzip, drag `MacMonBar.app` to `/Applications`, and open it. There is no Dock icon — look at your menu bar.

**Or build it from source** (needs Xcode Command Line Tools):

```bash
git clone https://github.com/HairuoLiu/MacMonBar.git
cd MacMonBar
./build.sh          # compiles src/main.swift → ./MacMonBar.app
open MacMonBar.app
```

### Start at login

**System Settings → General → Login Items & Extensions → Open at Login → +** and pick `MacMonBar.app`.

### Configure

Click the menu-bar item and pick from the menu: percentage colouring (**on**), gauges (off), temperature (off), per-core row (**on**), refresh interval (**2 s** default; 1 / 2 / 5 s available). Full menu reference: **[docs/features.md](docs/features.md)**.

<details>
<summary><b>For AI agents — installing this unattended</b></summary>

Resolve the machine first: Apple Silicon (`uname -m` = `arm64`) and macOS 13+ (`sw_vers -productVersion`). Abort with a clear message if either fails — this app is arm64-only and will not run on Intel.

```bash
#!/usr/bin/env bash
# MacMonBar unattended install. Safe to re-run.
set -euo pipefail

# 1. macmon — supplies GPU / memory / temperature. CPU works without it.
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

# 2. verify macmon actually emits one valid JSON line before continuing
MACMON_BIN="$HOME/.local/bin/macmon"
[ -x "$MACMON_BIN" ] || MACMON_BIN="$(command -v macmon)"
"$MACMON_BIN" pipe -i 500 2>/dev/null | head -n 1 \
  | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
  || { echo "macmon 没有输出可解析的 JSON，请检查权限/Gatekeeper" >&2; exit 1; }
# expected keys: gpu_scaled_ratio, memory.ram_usage / ram_total, temp.cpu_temp_avg

# 3. MacMonBar — resolve the newest release asset instead of hard-coding a version
URL=$(curl -fsSL https://api.github.com/repos/HairuoLiu/MacMonBar/releases/latest \
      | python3 -c 'import json,sys; print([a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].endswith(".zip")][0])')
curl -fsSL "$URL" -o /tmp/MacMonBar.zip
rm -rf /tmp/MacMonBar-app && mkdir -p /tmp/MacMonBar-app
unzip -oq /tmp/MacMonBar.zip -d /tmp/MacMonBar-app

# 4. install + clear the quarantine bit so it launches without a Gatekeeper prompt
rm -rf /Applications/MacMonBar.app
mv /tmp/MacMonBar-app/MacMonBar.app /Applications/
xattr -dr com.apple.quarantine /Applications/MacMonBar.app 2>/dev/null || true

# 5. launch, then confirm the process is alive — it is LSUIElement, so there is no window
open /Applications/MacMonBar.app
sleep 2
pgrep -x MacMonBar >/dev/null && echo "OK: MacMonBar running" || { echo "启动失败" >&2; exit 1; }
```

Notes for an agent:

- The app reads `macmon` at launch **and** on every refresh-interval change. If you install macmon *after* MacMonBar is already running, use **Quit MacMonBar** from the menu and reopen it — there is no "reload" item.
- Success looks like a process named `MacMonBar` plus a child process named `macmon` running `pipe -i 2000`.
- Do **not** try to screenshot the app to verify it. It has no window; use `pgrep` and the menu-bar item's presence.
- To uninstall: quit from the menu, delete `/Applications/MacMonBar.app`. Nothing else is written outside the bundle.

</details>

## Troubleshooting

<details>
<summary><b>Something is wrong — open this</b></summary>

| Symptom | Cause | Fix |
|---|---|---|
| GPU / RAM / temperature show `—` | macmon not found, or found but failed to launch | Install it (Step 1), then **quote and reopen MacMonBar**. It looks in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`. |
| Everything shows `—`, including CPU | Should be impossible — CPU has its own timer. Report it. | — |
| Values sit at `0 %` and never move | An old build (≤ 0.1.x) that depended on macmon for *all* metrics | Update to 0.2.0 or later |
| Menu bar item gone after a restart | Not registered as a login item | **System Settings → General → Login Items & Extensions → Open at Login → +** |
| Menu bar item hidden behind the notch | macOS drops items off the right edge when the bar is full | `⌘`-drag the item to reorder it, or quit other menu-bar apps |
| "MacMonBar is damaged / cannot be opened" | Gatekeeper quarantine on a downloaded, unsigned build | `xattr -dr com.apple.quarantine /Applications/MacMonBar.app` |
| `xcrun: error: invalid active developer path` when building | Command Line Tools not installed | `xcode-select --install` |
| `swiftc: error: unable to find utility` | Same as above | Same as above |
| Nothing happens after `open MacMonBar.app` | It is `LSUIElement` — there is no window or Dock icon by design | Look at the menu bar |
| The panel freezes while the menu is open | Fixed in 0.2.0 (a `DispatchQueue.main.async` redraw does not run inside `NSEventTrackingRunLoopMode`) | Update — [details](docs/how-it-works.md) |
| Builds fail on Intel | The target is `arm64-apple-macosx13.0` | Not supported; a menu-bar meter is pointless on Intel |
| CPU reads differently from Activity Monitor | Expected. Activity Monitor shows frequency-weighted residency, the same metric macmon uses | [details](docs/how-it-works.md) |

</details>

## Screenshots

Gauges switched on — the optional level bars:

![status bar with gauges](docs/statusbar-bars-light.png)

Without macmon — CPU and per-core still work, the other three say `—` instead of `0 %`:

![without macmon](docs/statusbar-no-macmon-light.png)

Dark mode, temperature enabled, and the degraded panel: **[docs/screenshots.md](docs/screenshots.md)**.

## Learn more

| Page | What is in it |
|---|---|
| [TALK.md](TALK.md) | **The 75-Megabyte Window** — an 18-minute talk on the four times measurement caught me being confidently wrong |
| [docs/performance.md](docs/performance.md) | Memory / CPU / power measurements, cost decomposition, refresh-interval table |
| [docs/how-it-works.md](docs/how-it-works.md) | Data flow, the Mach sampler, why macmon's CPU figure differs, the `NSMenu` event-loop bug |
| [docs/macmon.md](docs/macmon.md) | The relationship to macmon, and why the dependency stays |
| [docs/features.md](docs/features.md) | Every feature, every menu item, every default |
| [docs/design.md](docs/design.md) | Why the menu bar, why charts, the two colour systems, width as a measured value |
| [docs/tools.md](docs/tools.md) | The measurement scripts, and how the screenshots are generated |
| [CHANGELOG.md](CHANGELOG.md) | Version history |

## Credits

- [macmon](https://github.com/vladkens/macmon) by vladkens — the sudoless Apple Silicon monitor this app fronts for. MIT.
- Per-core accuracy cross-checked against [mactop](https://github.com/context-labs/mactop).

## License

MIT — see [LICENSE](./LICENSE).
