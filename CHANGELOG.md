# Changelog

All notable changes to mac-sitrep. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [0.4.0] — 2026-08-26

### Added

- **Milestone 3** — history and self-observability: `sitrepd`, a user
  LaunchAgent that records system state continuously, and `sitrep history` to
  summarize any window of it. `sitrep daemon install|uninstall|status` manages
  the agent — no root, no privileged helper, no password prompt.
- SQLite storage written against the C API directly, with WAL so the CLI reads
  while the daemon writes. Retention tiers roll raw 10-second samples into
  minutes after 48 hours and hours after 30 days, keeping a year of history from
  a store that would otherwise grow without bound. Rollups average rates, keep
  the max of peaks, and keep the *worst* of levels — the mean of "normal" and
  "critical" is not a state, and an hour averaged to 30% CPU hides a minute
  at 100%.
- `HealthTracker` adds hysteresis: 15 seconds to escalate, 60 to de-escalate.
  Escalate promptly, de-escalate reluctantly — a machine clear for two seconds
  mid-incident has not recovered. A test alternates states every 5 seconds for
  two minutes and asserts zero confirmed changes.
- The daemon derives rates from its previous reading rather than sleeping, which
  is what the Milestone 2 reading/sample split existed to enable. Cadence
  tightens from 10 s to 1 s while health is degraded, so timeline detail is paid
  for only during an incident.
- Self-measurement on every tick, including the sustained CPU figure a one-shot
  CLI structurally cannot produce. Exceeding the 100 MB / 2% budget is recorded
  as an event like any other. Measured over a 45-second run: 4.1 MB peak, 0.0%
  CPU.
- 95 tests across sixteen suites, including rollup aggregation against real
  SQLite rather than a fake.

### Changed

- The CLI and daemon communicate only through the SQLite file — the daemon
  writes, the CLI opens read-only. The Unix domain socket previously described
  in `ARCHITECTURE.md` is not built: WAL makes it unnecessary for reads, and
  history queries keep working when the daemon is stopped.

### Fixed

- Reported database size sums the `-wal` and `-shm` sidecars. In WAL mode the
  main file can sit at 4 KB while the log holds 200 KB+ uncheckpointed, so the
  previous figure under-stated mac-sitrep's own disk footprint by roughly 50×.

## [0.3.0] — 2026-08-26

### Added

- **Milestone 2** — live snapshot: `sitrep` (now the default subcommand) reports
  current memory, swap, pressure, CPU, GPU, thermal state, disk, and network,
  rolled up to a 🟢/🟡/🔴 health state that names the specific conditions behind
  its verdict rather than just asserting one. `sitrep processes` lists top
  consumers by physical footprint or CPU, with `--limit` and `--sort`.
- A split between `SystemReading` (instantaneous, carrying cumulative counters)
  and `Sample` (derived, carrying per-second rates). CPU ticks, disk and network
  byte totals, and swap counters are all cumulative since boot, so a rate needs
  two readings and the time between them. The CLI takes two readings 500 ms
  apart; the daemon in Milestone 3 will hold the previous reading and delta on
  each tick without sleeping. Both use the same types.
- `HealthState` with thresholds as named constants, classifying from a single
  sample. Explicitly without hysteresis, which needs history and arrives with the
  daemon.
- `ThermalState` as a shared enum, replacing an inline string array in
  `CapabilityRegistry`.
- `sitrep processes` always reports how many processes could not be read without
  root — 284 of ~800 on a typical Mac. A top-N list that silently omitted
  root-owned processes would misattribute the machine's memory.
- `--json` and `--interval` on both commands; 61 tests across ten suites.

### Fixed

- Total memory reads `hw.memsize` rather than summing page buckets, which
  under-reported a 16 GB Mac as 15 GB and inflated every derived percentage by
  roughly 6%. `host_statistics64` tracks speculative and purgeable pages outside
  the five categories that were being summed.

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
