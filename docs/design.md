# Design notes / 设计说明

[← Back to README](../README.md) · [中文](#中文)

## English

**Why the menu bar and not a widget.** Ranked by resource cost and complexity, the menu bar wins on memory (about a quarter of the Terminal route, 18.5 vs 75 MiB) and on purity of form: it is the only option that can sample at 2 Hz without keeping a whole terminal session alive, needs no host app, no App Group, and no timeline plumbing. In CPU terms the two routes are actually even — though the terminal route also pays a WindowServer bill for compositing its window that never shows up in the process table. Desktop widgets and Notification-Center widgets are the *same* WidgetKit technology: timeline-driven and throttled to roughly minute granularity, unable to sample on their own, and requiring a host app plus an App Group — so they end up *heavier* than the thing they wrap.

**Charts, not text.** Percentages alone cannot show a trend. Four small multiples — one metric each, stacked — are used instead of two overlaid sparklines, because overlaid lines are unreadable when they cross. Each chart carries its current value inline on the header row, a 50 % dashed reference line, a light area fill, and (as of 0.2.9) no end-point dot — the header already prints the value, so the dot was pure repetition.

**Two disjoint colour systems.** Colour is split into two layers that never mix.

| Layer | Belongs to | Hues |
|---|---|---|
| **Identity hues** | charts only — trend lines, top-left labels, status-bar gauges | blue CPU, rose GPU, cyan memory, purple temperature — four hues that deliberately avoid green, amber and red |
| **Value hues** | the numbers only | green (normal), amber (elevated), red (alert) |

Percentages switch at <50 % / ≥50 % / ≥80 %; temperature at <60 °C / ≥60 °C / ≥80 °C. A chart can therefore never collide with a number wearing the same colour: the right column tells you *what is busy*, the line colour tells you *which metric it is*. In dark mode the identity hues are lightened so they keep their contrast.

**Fixed width.** The panel is 300 pt with 14 pt of padding on each side. A width chooser was removed — a monitor should have one good default, not a preference pane.

**Status-bar width is measured, not guessed.** The bar's width is the sum of its slots, each sized from measured font metrics: the value slot is sized for the common maximum ("99%" = 29.1 pt) rather than the theoretical one ("100%" = 37.4 pt), the difference being absorbed by the gap between groups. Enlarging the labels to 13 pt pushed the bar to 261 pt; measurement-driven re-sizing brought it back to **230 pt** — 7 pt *shorter* than before the labels grew.

---

## 中文

**为什么是菜单栏，而不是小组件。** 按资源开销和复杂度排序，菜单栏在内存上胜出（约为终端路线的四分之一，18.5 vs 75 MiB），形态上也最干净：它是唯一能做到 2Hz 采样却不必养着一整个终端会话的方案，不需要宿主 App、不需要 App Group、不需要时间线管道。CPU 上两者其实持平——但终端路线还要额外支付一个窗口合成的 WindowServer 开销，这在进程表里根本看不到。桌面小组件和通知中心小组件是**同一套** WidgetKit 技术：由时间线驱动、被节流到分钟级、无法自己采样，还需要宿主 App 加 App Group——结果是它们比被包裹的东西**更重**。

**要图，不要光有数字。** 只有百分比看不出趋势。所以用四张小图（一图一指标，纵向排布）而不是两条叠加的 sparkline——叠加的线一交叉就没法读了。每张图在标题行内联当前值、画一条 50% 虚线参考线、一层浅色面积填充；从 0.2.9 起不再画末端圆点——标题行已经写了当前值，圆点纯属重复。

**两套互不重叠的色系。** 颜色分成永不混用的两层。

| 层 | 归属 | 色相 |
|---|---|---|
| **身份色** | 只给图表——趋势线、左上角标签、状态栏进度条 | 蓝 CPU / 玫红 GPU / 青内存 / 紫温度，四种色相刻意避开绿、琥珀、红 |
| **数值色** | 只给数字 | 绿（正常）/ 琥珀（偏高）/ 红（告警） |

百分比阈值 <50% / ≥50% / ≥80%，温度 <60°C / ≥60°C / ≥80°C。因此图表永远不会和一个穿同色的数字撞上：右列告诉你**谁忙**，线的颜色告诉你**这是谁**。深色模式下身份色会提亮以保持对比度。

**固定宽度。** 面板 300pt，左右各 14pt 内边距。宽度选择器已移除——一个监视器该有一个好默认值，而不是一堆偏好设置。

**状态栏宽度是量出来的，不是猜的。** 状态栏宽度等于各槽位之和，每个槽位按实测字体度量确定：数值槽按常见最大值（"99%" = 29.1pt）而非理论最大值（"100%" = 37.4pt）取值，差值由组间间距吸收。标签放大到 13pt 时曾把状态栏撑到 261pt；按实测重新分配后回到 **230pt**——比标签放大前还短 7pt。
