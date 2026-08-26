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

**v0.4.0 — Milestone 3 of 5 complete.** Live measurement and background history
both work: a collector records state continuously and reports what it costs to
do so. Workload profiling is next. See
[ROADMAP.md](ROADMAP.md) for what is planned and [CHANGELOG.md](CHANGELOG.md)
for what has shipped.

## What works today

- **`sitrep`** — current memory, swap, pressure, CPU, GPU, thermal state, disk,
  and network, rolled up to a 🟢/🟡/🔴 health state that names the conditions
  behind its verdict. Takes two readings a moment apart, since CPU and I/O
  figures are cumulative counters that cannot yield a rate from one read.
- **`sitrep processes`** — top consumers by physical footprint (Activity
  Monitor's "Memory", not RSS) or CPU, with `--limit` and `--sort`. Always
  reports how many processes could not be read without root.
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

Measured over a 45-second collector run on this machine: **4.1 MB peak
footprint against its declared 100 MB budget, 0.0% CPU.** The tool holds itself
to the rule it applies to everything else.

Everything below is specified and designed but not yet built — see
[ROADMAP.md](ROADMAP.md):

- **`sitrep run --project X -- cmd`** — profile a workload across five runs,
  attributing memory held by external services like Ollama or LM Studio
- **`sitrep export --inject README.md`** — write a measured requirements block
  into a README, with `--check` as a CI drift gate
- **`sitrep can-i-run X`** — predict whether a workload fits in currently
  available memory

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
