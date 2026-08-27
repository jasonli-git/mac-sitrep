# MacSitrep

A macOS observability and resource-accountability tool. It measures what software
actually costs to run, and publishes those measurements.

Steam is moving the same direction: its Framerate Estimator, in beta, predicts a
game's FPS on *your* hardware from measured player telemetry rather than from the
minimum and recommended specs a developer typed in by hand. mac-sitrep applies
that philosophy at the source. It profiles a workload across repeated runs and
generates a requirements block your project can commit — measured, reproducible,
and verifiable in CI. It holds itself to the same rule: a tool that reports the
cost of other software discloses its own.

It runs **entirely unprivileged**. No root daemon, no privileged helper, no
kernel extension. Metrics that would require root are omitted and disclosed
rather than silently dropped.

For what it should do and why, see [SPEC.md](SPEC.md). For how it is built, see
[ARCHITECTURE.md](ARCHITECTURE.md).

## Status

**v1.0.0 — all five milestones complete.** Measure a workload, attribute what it
really costs, publish it, and prove in CI that the published numbers still match.
Incidents, policy enforcement, and remote access are specified in
[SPEC.md](SPEC.md) and staged after v1 — see [ROADMAP.md](ROADMAP.md) for what
is planned and [CHANGELOG.md](CHANGELOG.md) for what has shipped.

## What works today

- **`sitrep`** — current memory, swap, pressure, CPU, GPU, thermal state, disk,
  and network, rolled up to a 🟢/🟡/🔴 health state that names the conditions
  behind its verdict. Takes two readings a moment apart, since CPU and I/O
  figures are cumulative counters that cannot yield a rate from one read.
- **`sitrep processes`** — top consumers by physical footprint (Activity
  Monitor's "Memory", not RSS) or CPU, with `--limit` and `--sort`. Always
  reports how many processes could not be read without root.
- **`sitrep run`** — profiles a workload across repeated runs and writes a JSON
  artifact under `.sitrep/profiles/`. Measures the process *group*, so work that
  outlives an intermediate parent still counts, and measures declared external
  services as their increase over a pre-run baseline. `sitrep init` creates a
  starter config.
- **`sitrep daemon install`** — runs a background collector as a user
  LaunchAgent. No root, no privileged helper, no password prompt. `uninstall`
  and `status` do what they say; `status` reports what the collector has cost.
- **`sitrep history --since 24h`** — what happened over a window: worst health
  reached, memory and CPU averages and peaks, top consumers, events, and
  mac-sitrep's own footprint. Reads the store directly, so it works whether or
  not the collector is currently running.
- **`sitrep doctor`** — reports all 21 metrics it knows how to look for: which
  are readable on this Mac (with a live sample value), and which are not (with
  the reason and the alternative to use instead). Each is established by
  attempting a real read, never by consulting a table. Add `--gaps-only` to see
  just the limitations, or `--json` to script against it. Exits non-zero if a
  metric that should work does not.
- **`sitrep export --inject README.md`** — renders a committed profile as a
  requirements block and writes it between markers, leaving the rest of the file
  untouched. `--check` writes nothing and exits non-zero on drift.
- **`sitrep compare v1.0 v1.1`** — diffs two profiles and reports regressions.
- **`sitrep can-i-run`** — predicts whether a profiled workload fits in memory
  available right now.
- **`sitrep version`** — version plus machine identity, in text or `--json`.

```
$ sitrep
🟢 HEALTHY

MEMORY        11 GB / 16 GB         68.0% used
  compressed  4.7 GB                wired 2.0 GB
  swap        0 B used              no swap-out activity
  pressure    normal

CPU           7.9%                  10 cores · user 4.7% · sys 3.1%
GPU           4.0%                  6.9 GB allocated
THERMAL       nominal

DISK          28 GB free            read idle · write idle
NETWORK                             in idle · out idle
```

Two reporting choices worth knowing about. Memory *used* is active + wired +
compressed, which runs several GB below what `top` shows — `top` counts cache the
kernel reclaims on demand. And swap is judged on its **rate**, not the swap file
size: macOS grows that file and never cleanly shrinks it, so a level-based
zero-swap policy would read as permanently violated.

`sitrep doctor` also reports what it *cannot* measure, and why:

```
– thermal.temperature           CPU die temperature
    SMC access requires root or private frameworks. mac-sitrep never
    uses root by design, so this is declined rather than unavailable.
    → use thermal.state instead
```

Why the process-group and external-service handling matters — profiling
`ollama run` against a 4B model on this machine:

```
peak RAM        427 MB
  own tree       11 MB     ← the command you actually ran
  external      416 MB     ← the model server that was already running
```

97% of the cost lives in a daemon outside the process tree. Attribution by
parent chain reports 11 MB and is wrong by 38×.

The collector holds itself to the same rule it applies to everything else:
**4.1 MB peak against its declared 100 MB budget**, measured by itself and
reported by `sitrep daemon status`.

### Publishing, and proving it stayed true

`sitrep export` renders from the committed JSON artifact and nothing else — not
the clock, not the machine — so the same artifact always produces identical
bytes. That is what makes the gate work:

```bash
sitrep run                              # measure locally, commit the artifact
sitrep export --inject README.md        # publish the block
sitrep export --inject README.md --check  # in CI: exits 1 if it drifted
```

**CI never needs a Mac.** It re-renders from the committed artifact and compares.
Injection only ever touches the region between its markers, and refuses outright
if those markers are malformed rather than risking your hand-written prose.

The block at the bottom of this README was generated this way, by mac-sitrep
profiling itself.

## Tech stack

| Component | Choice |
|-----------|--------|
| Language | Swift 6, targeting macOS 14+ |
| Build | SwiftPM |
| Metrics | `libproc`, `sysctl`, IOKit, Mach — read directly, never by spawning subprocesses in the sampling loop |
| Storage | SQLite (system `libsqlite3`) for local history; committed JSON artifacts for published requirements |
| Dependencies | `swift-argument-parser` and `swift-testing` — Apple/swiftlang only, by policy |

## Setup

Requires macOS 14 or later and the Swift toolchain (Xcode Command Line Tools is
sufficient — full Xcode is not needed).

```bash
git clone https://github.com/jasonli-git/mac-sitrep.git
cd mac-sitrep
swift build
swift run sitrep
```

Run the test suite:

```bash
swift test
```

<!-- sitrep:requirements:start -->
<!-- generated by sitrep — do not edit by hand -->

### Resource Requirements

Measured, not estimated — 5 runs of `sitrep processes --limit 10`.

| | Measured |
|---|---|
| **Recommended RAM** | 8.0 MB |
| Peak RAM | 2.3 MB _(2.3 MB – 2.3 MB)_ |
| Peak CPU | 31% _(19% – 31%)_ |
| Wall clock | 0.57 s _(0.56 s – 0.59 s)_ |
| Disk read | 0 B _(0 B – 32 KB)_ |
| Peak swap-out rate | 0 — no swapping |

Measured on Mac16,10 · Apple M4 · 16 GB · 10 cores · macOS 26.6.2 (25G83).

> Other work used 14% CPU during measurement, so these figures are soft.
> Not measured on this machine: `thermal.temperature`, `thermal.fan`, `network.per_process`, `process.other_users`, `power.package` — see `sitrep doctor`.

<sub>Generated by [mac-sitrep](https://github.com/jasonli-git/mac-sitrep) 1.0.0 from `1.0.0` on 2026-08-27.</sub>

<!-- sitrep:requirements:end -->
