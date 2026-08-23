# mac-sitrep

A macOS observability and resource-accountability tool. It measures what software
actually costs to run, and publishes those measurements.

Steam requires developers to publish system requirements, and those requirements
are guesses. mac-sitrep profiles a workload across repeated runs and generates a
requirements block your project can commit — measured, reproducible, and
verifiable in CI. It holds itself to the same rule: a tool that reports the cost
of other software discloses its own.

It runs **entirely unprivileged**. No root daemon, no privileged helper, no
kernel extension. Metrics that would require root are omitted and disclosed
rather than silently dropped.

For what it should do and why, see [SPEC.md](SPEC.md). For how it is built, see
[ARCHITECTURE.md](ARCHITECTURE.md).

## Status

**v0.1.0 — Milestone 0 of 5 complete.** The package scaffold, sysctl bridge, and
machine identity work; measurement itself begins in Milestone 1. See
[ROADMAP.md](ROADMAP.md) for what is planned and [CHANGELOG.md](CHANGELOG.md)
for what has shipped.

## What works today

- **`sitrep version`** — prints the version and identifies the machine
  (hardware model, CPU, RAM, cores, macOS version and build), in text or
  `--json`. This is the scaffold's health check, exercising the CLI, core
  library, and sysctl bridge in one command.

Everything below is specified and designed but not yet built — see
[ROADMAP.md](ROADMAP.md):

- **`sitrep doctor`** — every sensor this Mac can read, and every one it cannot,
  with the reason
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
swift run sitrep version
```

Run the test suite:

```bash
swift test
```
