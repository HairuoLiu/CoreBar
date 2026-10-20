# The 75-Megabyte Window

### What a menu bar app taught me about measuring twice

*A TED-style talk · ~18 minutes · [中文版 →](./TALK.zh-CN.md)*

> Delivered as a technical talk, but the subject is not Swift or macOS. It is the difference between *believing* something is cheap and *knowing* it is — and how many of my confident beliefs turned out to be wrong by a factor of forty.

---

## 0:00 — The hook

*[Slide: a screenshot of a Terminal window running a system monitor. Nothing else on screen.]*

For two weeks, I had a terminal window open on my Mac. It ran a system monitor — CPU, GPU, memory, temperature. It was a good monitor. It refreshed every second. It needed no sudo.

It also cost **75 megabytes**.

Not the monitor. The monitor was 2.7 megabytes. The other 72 megabytes was Terminal.app itself: a window, a tab, a login shell, a scrollback buffer holding ten thousand lines of CPU percentages I would never read again.

I was paying 75 megabytes to watch a number.

So I built a replacement. It lives in the menu bar. It costs **18.5 megabytes** and **0.43 % of one core**. That part of the story is a straightforward win, and I could stop here.

I'm not going to stop here, because the interesting part isn't the app. The interesting part is that **every single number I just gave you was wrong the first time I measured it** — and not by a little.

---

## 1:30 — The premise: a monitor should cost nothing

*[Slide: 18.5 MiB · 0.43 % · 3.8 mW · 0.000 % GPU]*

A system monitor occupies a strange position. It is the tool you run in order to find out what else is expensive. Which means it has a moral obligation to be free.

If your monitor is a significant line item in its own report, you have built a very expensive thermometer.

So I set a rule for myself before writing any code: **I would not claim any number I hadn't measured, and I would not remove a feature I hadn't measured the cost of.** That rule sounds like discipline. It is actually just a way of arranging to be embarrassed repeatedly, which is the fastest way I know to learn.

---

## 3:00 — Act one: the measurement was off by 41.67×

*[Slide: `ri_user_time / 1e9` — crossed out]*

Here is my first embarrassment, and it's a beautiful one because it is so small.

To measure CPU time on macOS you ask `libproc` for `proc_pid_rusage`. It hands you back `ri_user_time` and `ri_system_time`. Every tutorial, every Stack Overflow answer, and I, all assumed these were nanoseconds. They are not. They are **Mach ticks** — 41.6667 nanoseconds each on Apple Silicon.

So my scripts divided by `1e9` as if they were nanoseconds. Every CPU percentage I had reported was **understated by a factor of 41.67**.

For a week, I had been walking around with a set of numbers that said my app cost 0.01 % of a core, and I had been quietly pleased with myself about it.

How did I catch it? Not by reading documentation — I read the documentation and misread it. I caught it because I finally did the thing I should have done on day one: **I wrote a program whose answer I already knew.**

A single-threaded busy loop must read back as 100 % of a core. That is known by construction; it is a tautology. When my tooling reported 2.4 %, the tooling was wrong, not the universe.

*[Slide: "Before you measure the unknown, measure the known."]*

That is the whole first act. **Calibrate against a tautology before you trust an instrument.** Every measurement apparatus — a profiler, a survey, a dashboard, a quarterly report — should be pointed at something with an answer you already have, once, before you believe anything it tells you about something you don't.

---

## 6:00 — Act two: the panel that wouldn't move

*[Slide: a frozen chart, timestamp not advancing]*

Second embarrassment. I finished the app, clicked the menu bar icon, and the trend charts — frozen. Perfectly rendered. Completely static. The numbers in the menu bar updated. The charts did not.

My first instinct was the usual one: it's a performance problem. Too much drawing. So I instrumented it. Over 25 seconds with the menu open, the background queue received **24 samples**. The main thread ran **3**. One redraw happened.

Not a performance problem. The work wasn't slow. **The work was never scheduled.**

Here is what was actually happening. When you click a menu bar item, `NSMenu` opens a nested event loop running in `NSEventTrackingRunLoopMode`. And blocks you submit with `DispatchQueue.main.async` — the single most idiomatic thing in all of Apple development — **are not dispatched in that mode.**

*[Slide: `DispatchQueue.main.async` crossed out → `RunLoop.main.add(t, forMode: .common)`]*

So the world's most obvious implementation — pipe handler, dispatch to main, redraw — is structurally incapable of working while a menu is open. Not slow. Incapable.

The fix is one line: attach a `Timer` to `RunLoop.main` in `.common` mode, which *is* serviced during event tracking. After the fix, the same 25-second window gives `bg=24 main=24 panelDraw=23`.

But I want to dwell on the diagnosis, not the fix, because the diagnosis is the generalizable part. My hypothesis was "too slow." The data said "too slow" is not even the right category — the arrival count was 24 versus 3. **A hypothesis about rate cannot explain a discrepancy in counts.** I had two different bugs available to me and I was about to fix the one I hadn't measured.

The second lesson, then: **measure the mechanism, not the symptom.** "It's slow" and "it never runs" look identical from a user's chair and are completely different diseases.

---

## 9:00 — Act three: the number that lied

*[Slide: 99.3 % next to 59.0 %]*

Now the one that changed what I think the app is *for*.

I had a choice. I could take CPU utilization from `macmon` — the excellent monitor I was building a front end for — or I could sample it myself through Mach's `host_processor_info`. Taking it from macmon is less code. It's also, obviously, the same number that macmon displays in its own terminal UI, so consistency seemed like a virtue.

So I tested it. I ran 12 busy threads on a 12-core chip. All cores saturated. The machine was, unambiguously, at 100 %.

Mach said **99.3 %**. macmon said **59.0 %**.

*[Slide: the table — idle 21.4 %, 4 threads 44.6 %, 6 threads 59.9 %, 12 threads 99.3 %]*

Not a bug on either side. They are answering **different questions**.

`macmon` reports what Apple calls frequency-weighted residency: how much time a core spends at a given DVFS operating point. It is a measure of *energy state*. Mach's counters measure *busy versus idle ticks*. At full load they diverge by 1.7×, because a core can be resident at a high frequency state while not being fully utilized.

For a battery tool, macmon's number is the right one. For a **utilization meter** — a thing whose entire job is to answer "is my machine busy right now" — the second number is the one you want, and the first one is quietly misleading.

I cross-checked my sampler against `mactop`'s per-core readings: agreement within 1–3 percentage points. That's how I know it isn't my own number that's wrong.

*[Slide: "Ask what the number measures, not whether it is accurate."]*

This is the third lesson and I think it's the most transferable one. **A number can be perfectly accurate and answer a question you didn't ask.** Every dashboard you have ever loved has at least one metric like this. It is computed correctly. It is defined in the documentation. And it is not the thing you think it is.

The defence is not to distrust numbers. The defence is to make the number's *definition* explicit, out loud, in a sentence a non-expert could repeat back to you. If you can't say what a metric counts, you can't say what it means.

---

## 12:00 — Act four: the README that lied to my users

*[Slide: `brew install macmon` next to `~/.local/bin/macmon`]*

Last one, and this is the one that still stings.

My README told you to install macmon with Homebrew. On Apple Silicon, Homebrew puts it in `/opt/homebrew/bin`. My code looked for it in exactly one place: `~/.local/bin/macmon`.

So: every person who followed my instructions got a degraded app. GPU, memory and temperature showed a dash. No error. No crash. Just a quieter, worse app than the one I described.

I had a test for "macmon is missing." I never had a test for "macmon is where a normal person would put it."

And there was a second bug hiding behind it: if macmon was found but *failed to launch* — permissions, quarantine, wrong architecture — I swallowed the error with a `try?` and the fallback timer didn't start, because I'd only written the fallback for the "not installed" case. **The whole menu bar would freeze at zero.** The one thing that was supposed to keep working if the dependency broke, stopped working precisely when the dependency broke.

*[Slide: the two colour systems — identity hues vs value hues]*

I only found both of these by asking two people to review the project as if they were strangers. In code, as in writing, **you cannot proofread your own assumptions** — you read what you meant.

---

## 14:30 — The design: what I chose not to build

*[Slide: the status bar, 230 pt wide, three groups]*

Everything so far is about measuring. The rest is about restraint, which is harder and less glamorous.

**Two disjoint colour systems.** Charts get identity hues — blue CPU, rose GPU, cyan memory, purple temperature. Numbers get value hues — green, amber, red, by their own thresholds. These two sets never overlap, and that is deliberate: I never want you to look at a red line and wonder whether red means "this is the GPU" or "this is on fire." The right-hand column tells you *what is busy*. The line colour tells you *which metric it is*. One glance, two independent channels.

**No wattage in the menu bar.** It was easy to add — macmon gives it to me. I left it out, because knowing my Mac is drawing 11.3 watts has never once changed a decision I made while writing code. It's information that feels like information.

**No width chooser.** The panel is 300 points. It was configurable once; I deleted the setting. A monitor should have one good default, not a preference pane.

**The width is measured, not guessed.** Every slot is sized from real font metrics — the value slot is sized for "99 %" at 29.1 points, not for the theoretical worst case of 37.4 points, and the difference goes into the gaps. When I made the labels bigger, the bar grew to 261 points; measuring each slot brought it back to **230** — shorter than before the labels grew.

*[Slide: 0.000 % GPU]*

And one honest disclosure: **GPU usage is 0.000 %.** This is a pure AppKit 2D app, rasterized on the CPU. Panel compositing is billed to WindowServer. So when someone asks whether I optimized the GPU usage — that question has no answer, because there is nothing there. The most useful thing I did on that axis was decline to have an opinion.

---

## 16:30 — What I'd like you to take home

*[Slide: four lines]*

Four things, and none of them are about Swift.

**One: calibrate against something you already know.** Before you trust an instrument, point it at a tautology. My CPU numbers were 41.67× wrong and the only reason I found out is that I finally measured a busy loop that had to read 100 %.

**Two: measure the mechanism, not the symptom.** "Slow" and "never scheduled" are indistinguishable from the outside and completely different from the inside. Counts will tell you which one you have; rates won't.

**Three: ask what the number counts, not whether it's correct.** 99.3 % and 59.0 % are both accurate. They answer different questions. Pick the one that answers yours, and be able to say the definition out loud.

**Four: minimalism is a measurement problem, not a taste problem.** I didn't make this app small by having good taste. I made it small by measuring what each part cost and deleting the parts whose cost bought me nothing — the wattage, the width chooser, the end-point dot on the chart, the 50 % reference line on a chart where 50 % means nothing. **You cannot delete with confidence until you have measured what you're deleting.**

*[Slide: ≈13 MiB · 0.26 % · 2.3 mW · 1,361 lines · 0 dependencies]*

The app is 1,361 lines — 842 of Swift, 519 of C. No dependencies, no subprocess, no Python. About 13 megabytes, 0.26 % of a core, about 2.3 milliwatts — which, if you leave it running for a year, is 20 watt-hours. Roughly 0.07 % of one battery charge per day.

I replaced a 75-megabyte window with that. But the thing I actually got out of it wasn't the memory. It was discovering, four separate times, that I had been confidently wrong — and that in three of those cases, **measurement, not intelligence, is what caught me.**

*[Slide: blank]*

Measure twice. It's not a carpentry slogan. It's the only reason anything I've told you today is true.

Thank you.

---

## Postscript — 0.3.0, or "what the subprocess actually cost"

This talk is given with the app exactly as it was built: 20.8 MiB, two processes, a Rust child named `macmon` on the other end of a JSON pipe. The whole premise of the talk — *replace the 75-megabyte window with a 20-megabyte menu bar* — rests on that child staying.

Months later I measured the child itself, and it was 9.0 MiB and 0.23 % of a core. Nearly half my "win" was one binary I had chosen not to look at. So I looked at it.

GPU load was `libIOReport` — `dlopen`, a subscription, two samples, a delta, one residency channel, a frequency-weighted ratio. Temperature was `AppleSMC` with an `IOHID` thermal fallback. Both private, both fragile, both the reason I had outsourced the problem in the first place. And both, it turned out, about 500 lines of C.

The result: **one process, ≈12.9 MiB, 0.26 % of a core, zero dependencies** — measured head-to-head against the old build on the same machine in the same session: 21.4 → 12.9 MiB (−40 %) and 0.392 → 0.263 % of a core (−33 %), one process instead of two. And the numbers themselves? Because the algorithms were copied from macmon rather than reinvented, they are **bit-identical** — I drove both samplers simultaneously and compared every sample: temperatures matched to 0.0000 °C across idle, pulsing and saturated load. (That check earned its keep: the first attempt read GPU temperature 2.2 °C low, because the SMC key enumeration matched big-endian FourCC names unswapped and silently fell through to a different sensor set. Fixed, re-verified, now bit-exact.)

The lesson I would add to the four above: **the thing you are afraid to measure is usually the thing you should measure first.** I spent a year optimising display toggles that cost 0 bytes while a dependency I was "just shelling out to" quietly held half the memory budget. Measure the parts you did not write, too — and when you replace them, verify the replacement reads the same numbers, not just smaller ones.

---

## Appendix — the numbers, with their definitions

> Numbers as of 0.3.0 (single process), re-measured 2026-10-20 head-to-head against the v0.2.9 two-process build. The 0.2.x figures — 21.4 MiB including a 9.0 MiB `macmon pipe` child, 0.39 % of a core — are in the changelog.

| Claim | Value | How it was measured |
|---|---|---|
| Memory | ≈12.9 MiB | `ri_phys_footprint` via `libproc` — physical footprint, not RSS; single process; three 15 s runs |
| CPU, menu closed | 0.26 % of a core | Multiple 15 s windows, Mach-tick-corrected; old two-process build measured the same way at 0.39 % |
| CPU, menu open | 0.28 % of a core | same (2026-10-19 session) |
| Terminal route | ≈75 MiB / 0.62 % | Terminal.app 72.2 MiB + macmon TUI 2.7 MiB |
| Power | ≈2.3 mW | Derived from CPU time × on-machine calibration (8.60 W idle, 19.13 W at 12-thread full load) |
| GPU | 0.000 % | Pure AppKit 2D, rasterized on the CPU |
| Refresh default | 2 s | 1 s → 0.36 %; 2 s → 0.26 %; 5 s → 0.07 % (memory flat at ≈13 MiB across all three) |
| Readout parity | bit-identical | macmon 0.9.0 `pipe` vs native C, sample-by-sample: temps Δ = 0.0000 °C, GPU ratio within window jitter — [docs/macmon.md](docs/macmon.md#readout-parity-with-macmon) |
| Bar width | 230 pt | Sum of slots sized from measured font metrics |

Full methodology: [docs/performance.md](docs/performance.md). The `NSMenu` event-loop bug: [docs/how-it-works.md](docs/how-it-works.md). Colour systems and width: [docs/design.md](docs/design.md).
