# `tools/` and reproducing the screenshots / 工具与截图复现

[← Back to README](../README.md) · [中文](#中文)

## English

### `tools/`

Small, single-purpose scripts — kept because every number in `docs/performance.md` comes from one of them.

| File | Purpose |
|---|---|
| `cputest.swift` | Full-core CPU accuracy test: idle → 4 → 6 → 12 busy threads |
| `coretest.swift` | Prints per-core utilization; cross-validated against `mactop` |
| `machsampler.swift` | Pure Mach sampler — the zero-dependency baseline |
| `measure.py` | Per-pid CPU % / RSS / physical footprint via `libproc` |
| `measure_state.py` | CPU time of one state over N seconds |
| `power_ab.py` | The two-state power A/B used for the power table |
| `render_docs.py` | Regenerates every image in `docs/` (see below) |

Compile any Swift one with `swiftc -O -target arm64-apple-macosx13.0 tools/<name>.swift -o /tmp/<name>`.

### Reproducing the screenshots

The images in `docs/` are **not** screen captures. They are produced by feeding real sampled data into the very same `PanelView` / `MeterView` `draw(_:)` code and rasterizing into an `NSBitmapImageRep`:

```swift
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
view.frame = NSRect(x: 0, y: 0, width: w, height: h)
view.draw(view.bounds)
```

This needs no screen-recording permission and cannot drift from what the app actually renders.

One command regenerates everything:

```bash
python3 tools/render_docs.py          # writes docs/*.png and docs/zh/*.png
```

It works by truncating `src/main.swift` at the `NSApplication` bootstrap, appending a collector that reads `macmon pipe -i 200` for ~26 seconds, then rendering at `scale: 2` (panel) / `scale: 3` (status bar) in both `.aqua` and `.darkAqua`, once with `Loc.isChinese = false` (→ `docs/`) and once with `true` (→ `docs/zh/`).

Two gotchas were hard-won and are baked into the script:

- Dynamic colours (`labelColor`, `secondaryLabelColor`) do **not** resolve against `view.appearance` during offscreen drawing unless the draw call happens inside `NSAppearance.performAsCurrentDrawingAppearance { }`. Without it, dark-mode labels come out almost black. (`NSGraphicsContext.appearance` does not exist in this SDK.)
- `NSBitmapImageRep`'s `colorSpaceName` only accepts `.deviceRGB` / `.calibratedRGB` here — `.sRGB` is not a member.

The `-no-macmon-` images are the same pipeline with `macmonAvailable = false` and the GPU / memory / temperature histories cleared — that is the real degraded state, not a hand-edited mock-up.

---

## 中文

### `tools/`

小工具，每个只干一件事——留着是因为 `docs/performance.md` 里每个数字都出自其中之一。

| 文件 | 用途 |
|---|---|
| `cputest.swift` | 全核 CPU 准确性测试：空闲 → 4 → 6 → 12 线程忙 |
| `coretest.swift` | 打印逐核占用率，已与 `mactop` 交叉验证 |
| `machsampler.swift` | 纯 Mach 采样器——零依赖基线 |
| `measure.py` | 按 pid 测 CPU % / RSS / 物理 footprint，走 `libproc` |
| `measure_state.py` | 单个状态在 N 秒内的 CPU 时间 |
| `power_ab.py` | 功耗表用的两状态 A/B |
| `render_docs.py` | 重新生成 `docs/` 下所有图片（见下） |

Swift 脚本编译：`swiftc -O -target arm64-apple-macosx13.0 tools/<名字>.swift -o /tmp/<名字>`。

### 截图复现

`docs/` 里的图片**不是**屏幕截图，而是把真实采样数据喂给 App 自己的 `PanelView` / `MeterView` `draw(_:)`，再光栅化进 `NSBitmapImageRep`：

```swift
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
view.frame = NSRect(x: 0, y: 0, width: w, height: h)
view.draw(view.bounds)
```

这样不需要屏幕录制权限，也永远不会和 App 的真实渲染脱节。

一条命令重生成全部：

```bash
python3 tools/render_docs.py          # 输出 docs/*.png 与 docs/zh/*.png
```

原理是：在 `src/main.swift` 的 `NSApplication` 启动处截断，接上一段采集器（读 `macmon pipe -i 200` 约 26 秒），然后以 `scale: 2`（面板）/ `scale: 3`（状态栏）分别在 `.aqua` 与 `.darkAqua` 下渲染，并分别以 `Loc.isChinese = false`（→ `docs/`）和 `true`（→ `docs/zh/`）各跑一遍。

两个踩过的坑已经写进脚本：

- 离屏绘制时动态色（`labelColor`、`secondaryLabelColor`）**不会**按 `view.appearance` 解析，除非绘制发生在 `NSAppearance.performAsCurrentDrawingAppearance { }` 里。少了这一步，深色模式的文字会发黑。（这个 SDK 里根本没有 `NSGraphicsContext.appearance`。）
- 这里的 `NSBitmapImageRep` 的 `colorSpaceName` 只接受 `.deviceRGB` / `.calibratedRGB`，`.sRGB` 不是成员。

`-no-macmon-` 那两张是同一套流程，只是 `macmonAvailable = false` 并清空了 GPU / 内存 / 温度历史——那是真实的降级状态，不是手改的示意图。
