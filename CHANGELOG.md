# Changelog

All notable changes to MacMonBar. Versions are also tagged as GitHub releases.

<!-- 每条记录先英文后中文；中文标题下为对应中文说明。 -->

## 0.2.9 — 2026-10-14

**EN**

- **Fixed (P0):** `macmon` was only ever looked up at `~/.local/bin/macmon`, while the README told you to `brew install macmon` — which puts it in `/opt/homebrew/bin` on Apple Silicon. Every Homebrew user got a degraded bar. The lookup now tries `~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin`, and `build.sh` reports the same three paths.
- **Fixed (P1):** when `macmon` existed but failed to launch (permissions, Gatekeeper, architecture mismatch), `try? p.run()` swallowed the error and the whole bar froze — the fallback timer only started when macmon was *absent*. A launch failure now falls back to the CPU-only heartbeat.
- **Fixed:** the "Show every core (N cores)" menu item hard-coded `12`, contradicting the "the count is read from the kernel, never hard-coded" claim. It now reads `ProcessInfo.activeProcessorCount`.
- **Refactor:** CPU sampling had two copies of the same code (`tickCPU()` and `apply(_:)`); both now call one `sampleCPU()`. This is the exact duplication that caused the 0.2.0 freeze.
- **UI:** the 50 % dashed reference line is no longer drawn on the temperature chart (a normalised 30 – 100 °C axis has no meaningful 50 %); the latest-sample dot is gone (the header already prints the value); area fill 0.22/0.18 → 0.16/0.12; the per-core grey track is lighter (0.12 → 0.08).
- **Docs:** READMEs rewritten as a short, image-first page with dedicated **Install**, **For AI agents**, **Troubleshooting** and **Performance** sections. The long-form material moved to `docs/`; this changelog moved out of the README.

**中文**

- **修复（P0）：** 只从 `~/.local/bin/macmon` 找 macmon，而 README 教的是 `brew install macmon`（Apple Silicon 上装到 `/opt/homebrew/bin`），所有 Homebrew 用户必然降级运行。现在按 `~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin` 顺序查找，`build.sh` 提示同一组路径。
- **修复（P1）：** macmon 存在但启动失败（权限 / Gatekeeper / 架构不匹配）时，`try? p.run()` 把错误吞掉，整条菜单栏跟着冻住——兜底 Timer 只在 macmon *缺失* 时才启动。现在启动失败会退回 CPU 自采样心跳。
- **修复：** 菜单里的"显示每个核心（N 核）"写死 `12`，与"核数从内核读取、绝不硬编码"的说法自相矛盾。现改为 `ProcessInfo.activeProcessorCount`。
- **重构：** CPU 采样有两份重复代码（`tickCPU()` 与 `apply(_:)`），现统一走 `sampleCPU()`——正是这处重复导致过 0.2.0 的整栏冻结。
- **界面：** 温度图不再画 50% 虚线（30–100 °C 归一化后 50% 无意义）；删掉曲线末端圆点（标题行已写当前值）；面积填充 0.22/0.18 → 0.16/0.12；逐核灰底 0.12 → 0.08。
- **文档：** 中英 README 重写为极简图片优先版，独立出 **安装**、**给 AI Agent**、**故障排查**、**性能** 四块；长篇内容下沉到 `docs/`；变更记录从 README 移到本文件。

## 0.2.8 — 2026-10-14

**EN**

- **Default refresh interval is now 2 s** (the menu still offers 1 / 2 / 5 s). Re-measured: the whole app drops from 0.740 % to 0.429 % of a core — **−42 %**. The trend charts' history window grows to 4 minutes as a consequence.
- **Bilingual UI.** The menu and the expanded panel follow the system language (Chinese on `zh-*`, English otherwise), resolved once at launch; every user-facing string sits behind a single `Loc.t(zh, en)` helper. The status bar labels stay pinned to English — CPU / GPU / RAM.
- **Colour split into two disjoint systems.** Identity hues belong to the charts only (trend lines, top-left labels, status-bar gauges): blue CPU, rose GPU, cyan memory, purple temperature — four hues that deliberately avoid green, amber and red. Value hues belong to the numbers only: green / amber / red, with percentages at <50 % / ≥50 % / ≥80 % and temperature at <60 °C / ≥60 °C / ≥80 °C.
- **Status-bar labels at 13 pt semibold, centred** — 13 pt is exactly the system menu-bar size. Each label is centred in its slot, and values are left-aligned to hug their label, removing the dead space right-aligned short values used to leave.
- **Net width is shorter, not longer.** Enlarging the labels pushed the bar to 261 pt; re-sizing every slot from measurements brings it back to **230 pt** — 7 pt shorter than before the labels grew.
- **Fixed `drawText` clipping on overflow** ("100 %" rendered as "100").

**中文**

- **默认刷新间隔改为 2 秒**（菜单仍保留 1 / 2 / 5 秒）。重新实测：整体从 0.740% 降到 0.429% 单核占用，**−42%**；趋势图窗口随之扩展到 4 分钟。
- **中英双语界面。** 菜单与展开面板跟随系统语言（`zh-*` 中文，其余英文），启动时解析一次；所有界面文案统一走 `Loc.t(zh, en)`。状态栏的 CPU / GPU / RAM 保持英文。
- **配色拆成两套互不重叠的色系。** 身份色只给图表（趋势线、左上角标签、状态栏进度条）：蓝 CPU / 玫红 GPU / 青内存 / 紫温度，刻意避开绿、琥珀、红。数值色只给数字：绿 / 琥珀 / 红，百分比阈值 <50% / ≥50% / ≥80%，温度 <60°C / ≥60°C / ≥80°C。
- **状态栏标签 13pt semibold 并居中**——13pt 正是系统菜单栏字号。标签在自己的槽位里居中，数值左对齐紧贴标签，消除了右对齐时短数值留下的空白。
- **总宽度是变短而不是变长。** 标签放大后一度到 261pt，按实测重新分配各槽位后回到 **230pt**，比放大前还短 7pt。
- **修复 `drawText` 溢出裁切**（"100%" 会被画成 "100"）。

## 0.2.2 — 2026-10-13

**EN**

- Status bar redesigned: larger fonts, thin dividers between CPU / GPU / memory, each label right-aligned against its own percentage.
- Gauges and percentage colouring became two independent menu toggles — gauges default **off**, colour coding default **on**.
- Cost unchanged: measured main-process CPU still ~0.26 %.

**中文**

- 状态栏重做：字号加大，CPU / GPU / 内存之间加细分隔线，标签与自己的百分比对齐。
- 进度条与百分比着色拆成两个独立开关——进度条默认**关**，着色默认**开**。
- 开销未变：主进程 CPU 实测仍约 0.26%。

## 0.2.1 — 2026-10-13

**EN**

- **Fixed (tooling):** the `tools/` scripts treated `ri_user_time` / `ri_system_time` as nanoseconds; the real unit is Mach ticks (41.6667 ns), so CPU time was understated 41.67×. Every power / CPU figure in the docs was recomputed.
- Added a per-component cost decomposition.

**中文**

- **修复（工具）：** `tools/` 脚本把 `ri_user_time` / `ri_system_time` 当成纳秒，实际单位是 Mach tick（41.6667 ns），CPU 时间被低估 41.67 倍。文档中所有功耗 / CPU 数字全部重算。
- 新增逐组件开销分解。

## 0.2.0 — 2026-10-13

**EN**

- **Fixed:** with `macmon` absent the app froze at 0 % for *every* metric, CPU included, because `cpuSampler.sample()` was only reachable through macmon's JSON. CPU and per-core now run on an independent `Timer`.
- **Fixed:** GPU / memory / temperature render `—` instead of a misleading `0 %` when their data source is missing.
- **Added:** a menu entry linking to macmon's install instructions, shown only when macmon is absent.
- **Removed:** dead code — `kLabel`, `CPUCoreSampler.coreCount`, `AppDelegate.latest`.

**中文**

- **修复：** macmon 缺失时**所有**指标（含 CPU）都冻在 0%——因为 `cpuSampler.sample()` 只能通过 macmon 的 JSON 触发。CPU 与逐核现在跑在独立 `Timer` 上。
- **修复：** GPU / 内存 / 温度在数据源缺失时显示 `—`，不再显示误导性的 `0%`。
- **新增：** 菜单里指向 macmon 安装说明的入口，仅在 macmon 缺失时出现。
- **删除：** 死代码 `kLabel`、`CPUCoreSampler.coreCount`、`AppDelegate.latest`。

## 0.1.0 — 2026-10-13

**EN** — First release.

**中文** — 首个版本。
