# Full feature list / 完整功能与菜单说明

[← Back to README](../README.md) · [中文](#中文)

## English

### Status bar

- **Three metric groups** — CPU / GPU / RAM percentages, separated by thin vertical dividers.
- Labels are **13 pt semibold** (exactly the system menu-bar size, a touch heavier than the values) and are **centred** in their reserved slots. Values are **left-aligned and hug their label**, so there is no dead space inside a group and all the slack goes to the gaps between groups.
- **Colour-coded percentages.** Each percentage is coloured by its own load — green below 50 %, amber from 50 %, red from 80 % — so a glance tells you what is busy without reading the numbers.
- **Temperature is optional** and off by default (30 – 100 °C scale, its own thresholds).
- **Optional gauges.** The little level bars are a separate menu toggle, off by default. Plain percentages are the least noisy thing to keep in the corner of your screen all day; the gauges are there for when you want to read a level rather than a number.
- **No watts.** The status bar is for utilization; wattage was deliberately left out because it does not change the decisions you make while coding.
- Width is computed from measured text metrics: **230 pt** with the defaults.

### Expanded panel (click the icon)

- **Four full-width area charts** in a 2 × 2 grid — CPU, GPU, memory, temperature — each with its current value on the header row.
- **Per-core bars** underneath: one bar per core, CPU blue, with a faint grey track so you can tell idle cores from absent ones.
- **A 50 % dashed reference line** on the percentage charts (not on the temperature chart — a normalised 30 – 100 °C axis has no meaningful 50 %).
- Fixed width, 300 pt with 14 pt of padding on each side. There is no width chooser — a monitor should have one good default, not a preference pane.

### Menu

| Item | Default | What it does |
|---|---|---|
| Colour-code percentages | **on** | Colours each percentage by its own load |
| Show gauges | off | The small level bars in the status bar |
| Show temperature | off | Adds the CPU temperature to the status bar |
| Show every core (N cores) | **on** | The per-core bar row in the panel |
| Refresh interval → 1 / 2 / 5 s | **2 s** | How often the bar and charts update |
| Install macmon… | — | Only shown when macmon is missing; opens the install instructions |
| Quit MacMonBar | — | `⌘Q` |

### General

- **Bilingual.** The menu and the expanded panel follow the system language — Chinese on a `zh-*` system, English everywhere else — resolved once at launch. The status bar's CPU / GPU / RAM labels are deliberately pinned to English regardless, so the bar reads identically on every machine. Changing the system language takes effect after a restart.
- **Light and dark aware**, with semantic thresholds. Chart lines and labels use a separate set of identity hues — blue CPU, rose GPU, cyan memory, purple temperature — so the two colour systems never overlap.
- `LSUIElement` — no Dock icon, no window, nothing to switch to.
- **No dependencies.** AppKit + Foundation + Mach only. No SwiftPM, no Carthage, no SPM packages, one source file.

---

## 中文

### 状态栏

- **三组指标**——CPU / GPU / 内存百分比，中间用细分隔线隔开。
- 标签为 **13pt semibold**（正是系统菜单栏字号，比数值略重）并在自己的槽位里**居中**；数值**左对齐并紧贴标签**，因此组内没有空白，所有余量都留给组与组之间的间距。
- **百分比按数值着色。** 每个百分比按自身负载着色——低于 50% 绿、50% 起琥珀、80% 起红——扫一眼就知道谁忙，不用读数字。
- **温度可选**，默认关闭（30–100 °C 标尺，独立阈值）。
- **进度条可选。** 小进度条是独立的菜单开关，默认关闭。整天挂在屏幕角上，纯百分比最安静；想要"一眼看水平"而不是读数字时，再把进度条打开。
- **不显示功耗瓦数。** 状态栏是给占用率用的；瓦数刻意不放——它不会改变你写代码时的任何决策。
- 宽度由实测字体度量算出：默认配置下 **230pt**。

### 展开面板（点击图标）

- **四张全宽面积图**，2 × 2 排布——CPU、GPU、内存、温度——每张标题行右侧写着当前值。
- 下方是**逐核柱状图**：每核一根 CPU 蓝柱，带一层浅灰底槽，方便区分"空闲"和"没有这个核"。
- 百分比图上有 **50% 虚线参考线**（温度图不画——30–100 °C 归一化后 50% 没有意义）。
- 固定宽度 300pt，左右各 14pt 内边距。没有宽度选择器——一个监视器该有一个好默认值，而不是一堆偏好设置。

### 菜单

| 菜单项 | 默认 | 作用 |
|---|---|---|
| 百分比着色 | **开** | 按各自负载给百分比上色 |
| 显示进度条 | 关 | 状态栏里的小水平进度条 |
| 显示温度 | 关 | 状态栏增加 CPU 温度 |
| 显示每个核心（N 核） | **开** | 面板底部逐核柱状图 |
| 刷新间隔 → 1 / 2 / 5 秒 | **2 秒** | 状态栏与图表的更新频率 |
| 安装 macmon… | — | 仅在 macmon 缺失时出现，打开安装说明 |
| 退出 MacMonBar | — | `⌘Q` |

### 通用

- **中英双语。** 菜单与展开面板跟随系统语言——`zh-*` 系统显示中文，其余英文——启动时解析一次。状态栏的 CPU / GPU / RAM 标签刻意固定英文，保证任何机器上读起来都一样。切换系统语言需要重启后生效。
- **适配深浅色**，阈值语义化。趋势线与标签用一整套独立的身份色——蓝 CPU / 玫红 GPU / 青内存 / 紫温度——两套色系永不重叠。
- `LSUIElement`——没有 Dock 图标、没有窗口、没有可切换的界面。
- **零依赖。** 只用 AppKit + Foundation + Mach。没有 SwiftPM、没有 Carthage、没有 SPM 包，只有一个源文件。
