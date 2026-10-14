# Relationship to macmon / 与 macmon 的关系

[← Back to README](../README.md) · [中文](#中文)

## English

Everyone asks this, so it gets its own page: **no macmon code is used.** Not a fork, not a vendored library, not a linked dependency. MacMonBar is 733 lines of Swift written from scratch; macmon is written in Rust. There is no Rust anywhere in this repository, and nothing here calls into it.

The entire relationship is that MacMonBar spawns `macmon pipe -i <interval>` as a child process and reads its JSON, one line per sample.

### Why the dependency stays

Two of the four metrics are trivial to replace natively. Two are not.

| Metric | Native replacement | Effort |
|---|---|---|
| CPU / per-core | already native — runs on its own timer | done |
| Memory | `host_statistics64` + `vm_statistics64` | ~30 lines, easy |
| GPU utilization | IOReport private framework | hard, breaks across OS releases |
| Temperature | no public API — IOHID / SMC | hard, breaks across OS releases |

The two hard ones are precisely what macmon already solves, and they are precisely the ones that break on every macOS update. Reimplementing them would trade a 5.6 MiB child process for a permanent maintenance burden — and would make the app *less* reliable, not more.

Until 0.2.0 the coupling was worse than it looks: `cpuSampler.sample()` was only ever called from `apply()`, which only ran when a complete JSON line arrived from macmon's pipe. With macmon absent the whole app froze at 0 % — CPU included. The sampler now has its own `Timer`, so the dependency is honestly scoped to the three metrics it actually supplies.

### Why the name

`MacMonBar` says what it is: a menu bar for macmon. Renaming it while still shelling out to macmon would be less honest, not more.

### Licensing

There is no obligation either way: MIT only requires the notice be retained in copies of *the software*, and none of macmon's code ships here. macmon is credited anyway — see [Credits](../README.md#credits).

---

## 中文

这个问题被问得最多，所以单独开一页：**没有使用 macmon 的任何代码。** 不是 fork、不是 vendor 进来的库、也不是链接依赖。MacMonBar 是从零手写的 733 行 Swift，macmon 是 Rust。本仓库里没有任何 Rust，也没有任何地方调用它。

两者全部的关系就是：MacMonBar 把 `macmon pipe -i <间隔>` 拉起为子进程，读它的 JSON，一行一个样本。

### 为什么保留这个依赖

四项指标里两项很容易换成原生实现，两项不行。

| 指标 | 原生替代方案 | 工作量 |
|---|---|---|
| CPU / 逐核 | 本来就是原生——跑在自己的定时器上 | 已完成 |
| 内存 | `host_statistics64` + `vm_statistics64` | 约 30 行，简单 |
| GPU 占用率 | IOReport 私有框架 | 难，每次系统升级都可能挂 |
| 温度 | 没有公开 API——IOHID / SMC | 难，每次系统升级都可能挂 |

难的那两项正好是 macmon 已经解决的，也正好是每次 macOS 更新都会坏的那两项。自己重写等于用永久的维护负担换掉一个 5.6 MiB 的子进程——而且会让 App **更不可靠**，不会更可靠。

0.2.0 之前耦合比看起来更糟：`cpuSampler.sample()` 只从 `apply()` 调用，而 `apply()` 只在 macmon 管道送来完整 JSON 行时才跑。于是 macmon 缺失时整个 App 冻在 0%——连 CPU 一起。现在采样器有自己的 `Timer`，依赖被诚实地限定在它真正提供的那三项指标上。

### 为什么叫这个名字

`MacMonBar` 就是在说它是什么：macmon 的菜单栏。一边还在 shell 调用 macmon，一边改名反而更不诚实。

### 授权

两种方向都没有义务：MIT 只要求在其*软件*的副本中保留版权声明，而这里一行 macmon 代码都没带。尽管如此仍然致谢——见 [Credits](../README.md#credits)。
