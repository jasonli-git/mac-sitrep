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

**v0.2.0 — Milestone 1 of 5 complete.** Capability disclosure works: the tool
knows and reports what this Mac can and cannot measure. Live sampling begins in
Milestone 2. See [ROADMAP.md](ROADMAP.md) for what is planned and
[CHANGELOG.md](CHANGELOG.md) for what has shipped.

## What works today

- **`sitrep doctor`** — reports all 21 metrics it knows how to look for: which
  are readable on this Mac (with a live sample value), and which are not (with
  the reason and the alternative to use instead). Each is established by
  attempting a real read, never by consulting a table. Add `--gaps-only` to see
  just the limitations, or `--json` to script against it. Exits non-zero if a
  metric that should work does not.
- **`sitrep version`** — version plus machine identity, in text or `--json`.

Example of the honest-gaps half of `doctor`:

```
– thermal.temperature           CPU die temperature
    SMC access requires root or private frameworks. mac-sitrep never
    uses root by design, so this is declined rather than unavailable.
    → use thermal.state instead
```

Everything below is specified and designed but not yet built — see
[ROADMAP.md](ROADMAP.md):

- **`sitrep` / `sitrep processes`** — live system and per-process state, using
  physical footprint rather than RSS
- **`sitrepd`** — background sampling into a local SQLite history, measuring its
  own footprint against a declared budget
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
swift run sitrep doctor
```

Run the test suite:

```bash
swift test
```
