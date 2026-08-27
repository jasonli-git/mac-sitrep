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

Two reporting choices worth knowing about. Memory *used* is app memory + wired +
compressed, which **matches Activity Monitor** and runs several GB below what
`top` shows — `top` counts the file cache the kernel reclaims on demand. And swap
is judged on its **rate**, not the swap file size: macOS grows that file and
never cleanly shrinks it, so a level-based zero-swap policy would read as
permanently violated.

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

The block at the bottom of this README was generated by mac-sitrep profiling
itself, and CI can prove it has not drifted — see [Usage](#usage).

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
swift build -c release
```

Install both binaries somewhere stable on your `PATH`. The background collector
is registered by absolute path, so pointing it into `.build/` would break the
next time you clean:

```bash
install -m 755 .build/release/sitrep .build/release/sitrepd ~/.local/bin/
sitrep version
```

Run the test suite:

```bash
swift test
```

## Usage

### Checking this Mac right now

```bash
sitrep                          # current state, health, and why
sitrep --interval 2             # longer sample, steadier CPU figure
sitrep processes --sort cpu     # top consumers; --sort ram|cpu, --limit N
sitrep doctor                   # what can and cannot be measured here
sitrep doctor --gaps-only       # just the limitations
```

`sitrep` blocks for about half a second: CPU, disk, and network are cumulative
counters since boot, so a current rate needs two reads. Every command takes
`--json`.

### Running the background collector

```bash
sitrep daemon install     # register and start the LaunchAgent
sitrep daemon status      # running? and what has it cost?
sitrep daemon uninstall   # stop and remove; --purge-history deletes the DB
```

No root, no privileged helper, no password prompt. Once it has been collecting:

```bash
sitrep history --since 24h      # windows take 30m, 24h, 7d
```

You get the worst health reached, memory and CPU averages and peaks, top
consumers, events, and mac-sitrep's own footprint. It reads the database
directly, so it works whether or not the collector is currently running.

### Profiling a project

```bash
cd ~/Developer/PROJECTS/your-project
sitrep init
```

That writes `.sitrep/project.json`. Edit the `command` array — it is argv, not a
shell string.

**If your workload talks to a model server, declare it.** This is the part that
changes the answer:

```json
"externalServices": [
  { "name": "ollama", "executableContains": "ollama" }
]
```

Without it, profiling `ollama run` reports 11 MB instead of 427 MB, because the
model lives in a daemon that was already running before your command started.

```bash
sitrep run                                 # use the config
sitrep run --runs 10                       # more runs, tighter median
sitrep run --label v1.4                    # version label for the artifact
sitrep run --dry-run                       # measure without writing
sitrep run --timeout 60                    # kill a run that hangs
sitrep run -- python3 train.py --epochs 3  # override the command after --
```

Three warnings are worth reading rather than skipping. *Timed out* means the run
measured a hang. *Finished too fast to measure* means too few samples landed to
characterize it. *Contention* means other work was running and the numbers are
soft.

### Publishing measured requirements

```bash
sitrep export                              # print the block
sitrep export --inject README.md           # write it between the markers
sitrep export --badge .sitrep/badge.json   # shields.io endpoint JSON
sitrep export --inject README.md --check   # CI gate: writes nothing, exits 1 on drift
```

Injection only ever touches the region between
`<!-- sitrep:requirements:start -->` and its matching `:end`. A file with no
markers gets a section appended; one with malformed or duplicated markers is
refused rather than repaired, since a wrong guess would eat your prose.

Rendering reads the committed JSON artifact and nothing else — not the clock, not
the machine — so the same artifact always produces identical bytes. **That is why
CI never needs a Mac**: profile locally, commit `.sitrep/`, and let CI re-render
and compare.

### Comparing and predicting

```bash
sitrep compare v1.0 v1.1                        # median deltas, regressions flagged
sitrep compare v1.0 v1.1 --fail-on-regression   # exits 1 on a regression
sitrep can-i-run                                # will it fit right now?
```

`compare` uses medians rather than peaks, so one unlucky run does not read as a
regression, and warns when two profiles are not really comparable — different
machines, scenarios, or commands.

```
$ sitrep can-i-run
🟢 mac-sitrep · processes · 1.0.0
   4.1 GB available, needs 2.3 MB — fits with 4.1 GB to spare.
```

Available means free plus inactive pages: what the kernel can hand over without
swapping. This is a claim about *this* machine only — mac-sitrep does not predict
across hardware.

### Exit codes

Several commands are built to be scripted:

| Command | Exits non-zero when |
|---------|---------------------|
| `sitrep doctor` | a metric that should work on this Mac failed to probe |
| `sitrep run` | any run exited non-zero |
| `sitrep export --check` | the target file has drifted from the artifact |
| `sitrep compare --fail-on-regression` | a regression was found |
| `sitrep can-i-run` | the workload is predicted to swap |

<!-- sitrep:requirements:start -->
<!-- generated by sitrep — do not edit by hand -->

### Resource Requirements

Measured, not estimated — 5 runs of `sitrep processes --limit 10`.

| | Measured |
|---|---|
| **Recommended RAM** | 8.0 MB |
| Peak RAM | 2.2 MB _(2.2 MB – 2.3 MB)_ |
| **CPU load** | **Negligible** — 0.6% of a 10-core machine |
| CPU time | 0.036 s _(0.022 s – 0.044 s)_ |
| Peak CPU | 29% _(18% – 30%)_ of one core <sub>(per 50 ms window)</sub> |
| Wall clock | 0.578 s _(0.567 s – 0.596 s)_ |
| Disk read | 0 B _(0 B – 48 KB)_ |
| Peak swap-out rate | 0 — no swapping |

Measured on Mac16,10 · Apple M4 · 16 GB · 10 cores · macOS 26.6.2 (25G83).

> Not measured on this machine: `thermal.temperature`, `thermal.fan`, `network.per_process`, `process.other_users`, `power.package` — see `sitrep doctor`.

<sub>Generated by [mac-sitrep](https://github.com/jasonli-git/mac-sitrep) 1.1.0 from `1.1.0` on 2026-08-27.</sub>

<!-- sitrep:requirements:end -->
