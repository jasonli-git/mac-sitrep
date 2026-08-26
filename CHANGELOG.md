# Changelog

All notable changes to mac-sitrep. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [0.2.0] — 2026-08-26

### Added

- **Milestone 1** — capability disclosure: `sitrep doctor` reports every metric
  this Mac can measure and every one it cannot, with a typed reason. 21 probes
  across memory, CPU, GPU, thermal, disk, network, process, and power, each
  attempting a real read and reporting a live sample value rather than a
  checkmark. Root-gated metrics (die temperature, fan RPM, package power, other
  users' process stats) report as *declined by design* with the alternative to
  use instead; per-process network I/O reports as having no public API at any
  privilege level, since root would not unlock it. Adds the unprivileged access
  layer the rest of the project reads through: `MachHost` (`host_statistics64`,
  `host_processor_info`), `Rusage` (`proc_pid_rusage` V4, including the kernel's
  own lifetime peak footprint), `ProcessList` (`libproc` enumeration),
  `IOKitRegistry` (GPU and block-storage counters), `NetworkInterfaces`
  (`NET_RT_IFLIST2`), and `SwapUsage` (swap plus compressor counters).
  `SelfFootprint` measures mac-sitrep through the same path any other process
  gets and checks it against the declared 100 MB budget — currently 3.3 MB peak.
  `--json` on every output; non-zero exit when a probe that should work fails,
  making `doctor` usable as a scripted health check. 36 tests across seven
  suites.

### Fixed

- Swap-rate counters read `vm.compressor.swapper.swapouts_total` and siblings.
  The previous names in `ARCHITECTURE.md` omitted the `.swapper.` path component
  and did not exist; probing caught it before any consumer depended on them.
- System-wide network I/O reads 64-bit counters via `NET_RT_IFLIST2` rather than
  the 32-bit `if_data` that `getifaddrs(3)` returns, which wraps every 4 GB.
- Derived peak footprint takes `max(kernel high-water mark, live footprint)`.
  `ri_lifetime_max_phys_footprint` is refreshed at task-accounting boundaries and
  can read below the live value during rapid growth, which would have
  under-reported peak RAM in published profiles.

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
