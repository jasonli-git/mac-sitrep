# Changelog

All notable changes to mac-sitrep. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [0.1.0] — 2026-08-23

### Added

- **Milestone 0** — scaffolding: SwiftPM package targeting macOS 14 in Swift 6
  language mode, split into a `SitrepCore` library and a `sitrep` executable so
  the daemon and a future HTTP server can be added as peers rather than forks of
  the CLI. `Support/Sysctl.swift` provides width-aware typed wrappers over
  `sysctlbyname(3)` and is the single path to sysctl in the package — no metric
  read shells out to a subprocess. `Model/Machine.swift` resolves hardware
  identity (`hw.model`, CPU brand, RAM, cores, macOS version and build) and is
  `Codable` for embedding in profile artifacts. `sitrep version` is the health
  check, exercising CLI → core → sysctl in one command, with `--json`. 9 tests
  passing across two suites, asserting against the real machine rather than
  fixtures since the sysctl bridge is what is under test.
- Project documentation: [SPEC.md](SPEC.md), [ARCHITECTURE.md](ARCHITECTURE.md),
  [ROADMAP.md](ROADMAP.md), [TODO.md](TODO.md), and this changelog. `SPEC.md`
  captures the full product intent revised from the original brainstorm —
  notably redefining zero-swap as a *rate* policy, adding the unprivileged
  constraint as a first-class principle, and recording explicit non-goals.
