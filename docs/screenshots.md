# Screenshots / 截图

[← Back to README](../README.md)

Every image here is rendered by the app's own `draw(_:)` code against real sampled data — not a screen capture. See [docs/tools.md](tools.md#reproducing-the-screenshots) for the pipeline. / 本页所有图片都由 App 自己的 `draw(_:)` 用真实采样数据渲染而成，不是屏幕截图；流程见 [docs/tools.md](tools.md)。

## Status bar / 状态栏

Default — colour-coded percentages, thin dividers, no gauges, temperature hidden. / 默认——百分比着色、细分隔线、无进度条、不显示温度。

![status bar, default](statusbar-light.png)

Gauges switched on. / 打开进度条。

![status bar with gauges](statusbar-bars-light.png)

Temperature switched on. / 打开温度。

![status bar with temperature](statusbar-temp-light.png)

Dark mode. / 深色模式。

![status bar, dark](statusbar-dark.png)

Dark mode, gauges on. / 深色模式，开启进度条。

![status bar with gauges, dark](statusbar-bars-dark.png)

Dark mode, temperature on. / 深色模式，开启温度。

![status bar with temperature, dark](statusbar-temp-dark.png)

## Expanded panel / 展开面板

Four trend charts (2 × 2) plus a per-core bar row. / 四张趋势图（2 × 2）加逐核柱状图。

![panel, light](panel-light.png)

![panel, dark](panel-dark.png)

## Without macmon / 缺少 macmon

CPU and per-core still work; the other three degrade to `—` instead of a misleading `0 %`. / CPU 与逐核仍然工作，其余三项降级为 `—`，而不是误导性的 `0%`。

![status bar without macmon](statusbar-no-macmon-light.png)

![panel without macmon](panel-no-macmon-light.png)
