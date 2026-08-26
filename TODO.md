# mac-sitrep — TODO

Working list for the current milestone. Longer-horizon items live in
[ROADMAP.md](ROADMAP.md).

## Milestone 0 — Scaffolding ✅

- [x] SwiftPM manifest targeting macOS 14, Swift 6 language mode
- [x] `SitrepCore` library / `sitrep` executable split, with `SitrepCore`
      importing no CLI code
- [x] `Support/Sysctl.swift` — typed `sysctlbyname(3)` wrappers, width-aware
- [x] `Model/Machine.swift` — machine identity, `Codable`, degrades to `unknown`
- [x] `sitrep version` health check exercising CLI → core → sysctl, with `--json`
- [x] 9 tests passing across `Machine identity` and `Sysctl bridge` suites
- [x] `.gitignore` covering `.build/`, `.swiftpm/`, `*.xcodeproj`
- [x] Six project documents
- Note: Command Line Tools ships neither XCTest nor the toolchain's bundled
  `Testing` module — both verified failing to resolve. Taking an explicit
  `swift-testing` package dependency instead (ARCHITECTURE #3). `swift test`
  prints a deprecation warning telling us to remove that dependency; following
  it breaks the build here. Revisit only if full Xcode gets installed.
- Note: `sitrepd` is not yet a package target. It arrives in Milestone 3;
  declaring it now would ship an executable that does nothing.
- Note: `Sysctl.integer` cannot distinguish "key absent" from "key is a struct" —
  both return `nil`. Acceptable now because struct-valued keys get purpose-built
  readers, but if a caller ever needs to tell them apart this needs a typed error.

## Milestone 1 — Capability disclosure ✅

Deliverable: `sitrep doctor` reports every metric this Mac can measure and every
one it cannot, with the reason. Probes attempt a real read rather than asserting
availability from a table — a `doctor` that reports from a hardcoded list is a
lie, and honest gaps are the point (SPEC principle 11).

Low-level access layer:

- [x] `Support/MachHost.swift` — `host_statistics64` (HOST_VM_INFO64) and
      `host_processor_info` (PROCESSOR_CPU_LOAD_INFO), with `vm_deallocate` on
      the CPU array
- [x] `Support/Rusage.swift` — `proc_pid_rusage(RUSAGE_INFO_V4)`; needs the
      `rusage_info_t?` optional rebind, verified by spike
- [x] `Support/IOKitRegistry.swift` — matching-service property lookup for
      `IOAccelerator` and `IOBlockStorageDriver`
- [x] `Support/CommandRunner.swift` — bounded subprocess, used only for `pmset`
      (the documented exception to ARCHITECTURE #1)
- [x] `Support/SwapUsage.swift` — struct-valued `vm.swapusage`, which
      `Sysctl.integer` correctly declines

Capability layer:

- [x] `Sampling/Capability.swift` — capability identity plus a status of
      available-with-sample or unavailable-with-typed-reason
- [x] `Sampling/CapabilityRegistry.swift` — all probes, grouped by category
- [x] `Model/SelfFootprint.swift` — mac-sitrep measuring itself via the same
      rusage path other processes get

Interface:

- [x] `sitrep doctor` rendering available and unavailable, never omitting the
      latter, plus the self-footprint line
- [x] `--json` output
- [x] Non-zero exit when a capability expected to work fails to probe, so
      `doctor` is usable as a scripted health check

Tests:

- [x] Every capability in ARCHITECTURE's table is registered and probed
- [x] Root-gated metrics report unavailable with a reason, never absence
- [x] Available capabilities return plausible sample values, cross-checked
      against an independent source where one exists

- Note: probing caught a real error on first run. `memory.swap_rate` named
  `vm.compressor.swapouts_pressure`, which does not exist — the real key is
  `vm.compressor.swapper.swapouts_total`. The same wrong names were in
  ARCHITECTURE's capability table, so a static-table `doctor` would have
  reported the capability working while the read returned nothing. Both fixed;
  a regression test now pins the correct keys.
- Note: `getifaddrs(3)` was the obvious network source and is wrong — its
  `if_data` counters are 32-bit and wrap every 4 GB. Switched to
  `sysctl NET_RT_IFLIST2` for `if_data64`. This would have surfaced as slowly
  corrupting numbers rather than an error.
- Note: the `power.sleep_wake` probe only checks that `/usr/bin/pmset` is
  executable; it does not run `pmset -g log`, whose output is megabytes. Its
  "available" is therefore weaker than every other capability's, and the parse
  could still fail in Milestone 3. Recorded in ARCHITECTURE's limitations.
- Note: a test caught that `ri_lifetime_max_phys_footprint` can read *lower*
  than `ri_phys_footprint` during rapid growth (observed: peak 4,800,824 vs
  footprint 4,833,592). ARCHITECTURE #5 overstated the field as "exact peak RAM";
  #17 qualifies it. Consumers derive peak with `max()`. This would have
  under-reported peak RAM in Milestone 4 for exactly the fast-allocating
  workloads the project targets.
- Note: `IOKitRegistry` reads the first matching service only, so GPU and disk
  figures describe the primary device rather than a total. Correct for this Mac;
  revisit as per-service reporting if a second GPU ever matters.

## Milestone 2 — Live snapshot ✅

Deliverable: `sitrep` shows current system state and `sitrep processes` shows top
consumers, both with `--json`.

The shaping constraint: **CPU, disk I/O, network I/O, and swap are cumulative
counters since boot.** A single read of any of them gives an average over machine
uptime, which is worthless as a "right now" figure. Every one needs two reads
separated by an interval. That forces a split between a cheap instantaneous
*reading* and a derived *sample* carrying rates — and that split is exactly what
the daemon needs in Milestone 3, where it holds the previous reading in memory
and deltas continuously instead of sleeping.

- [x] `Model/ThermalState.swift` — shared thermal enum; refactor
      `CapabilityRegistry` to use it instead of an inline string array
- [x] `Model/Sample.swift` — `SystemReading` (instantaneous, cumulative counters)
      and `Sample` (derived, carries rates), with sub-structs per subsystem
- [x] `Model/ProcessSample.swift` — per-process reading and derived sample
- [x] `Model/HealthState.swift` — 🟢/🟡/🔴 from explicit named thresholds
- [x] `Sampling/SystemSampler.swift` — `read()` for the daemon, plus
      `sample(interval:)` convenience for one-shot CLI use
- [x] `Sampling/ProcessSampler.swift` — two reads to derive per-process CPU;
      must report how many processes were unreadable, not silently show fewer
- [x] `sitrep` status as the default subcommand, replacing `doctor`
- [x] `sitrep processes` — `--limit`, `--sort ram|cpu`
- [x] `--json` and `--interval` on both
- [x] Tests: CPU fractions sum to ~1, rates are non-negative, self appears in the
      process list with a plausible footprint, unreadable count is disclosed,
      health thresholds classify correctly at their boundaries

- Note: total memory was initially summed from page buckets and read 15 GB on a
  16 GB Mac — `host_statistics64` tracks speculative and purgeable pages outside
  those five categories. Now reads `hw.memsize`. Every derived percentage was
  inflated ~6% until this was caught by comparing against the machine's actual
  spec.
- Note: reported "memory used" is intentionally ~4 GB lower than `top`'s. `top`
  counts reclaimable cache; we do not (ARCHITECTURE #18). Cross-checked against
  `top -l 1` — wired and compressor matched exactly, only the definition
  differed. Anyone comparing the two will need this explained.
- Note: no `--watch` mode. SPEC §20 wants a status display that updates in place
  rather than reprinting. Deferred deliberately: once the daemon exists, watch
  should read from it rather than re-sampling per frame, so building it now would
  mean building it twice.
- Note: local AI workload recognition (SPEC §3 — tagging Ollama, LM Studio, MLX
  in the process list) is not here. It belongs with attribution in Milestone 4,
  which needs the same process-matching rules.
- Note: `sitrep processes` accounts for only readable processes, so its memory
  total sits far below the machine's. Not fixable without root; the unreadable
  count is disclosed on every run.

## Milestone 3 — History and self-observability ✅

Deliverable: a background daemon records history, and `sitrep history` answers
"what happened over the last 24 hours". The daemon holds itself to its declared
budget and can now measure the sustained CPU figure a one-shot CLI structurally
cannot.

Three design changes from what was previously documented, each recorded as a
decision rather than made silently:

1. **No IPC socket.** The CLI reads SQLite directly. WAL gives concurrent
   readers alongside the daemon's single writer, so there is no protocol to
   design or version, and history queries keep working when the daemon is not
   running. A socket becomes necessary when there are *control* operations to
   carry; there are none yet.
2. **Per-process history is top-N, not every process.** Storing ~500 readable
   processes every 10 s is ~4.3 M rows/day and would make the monitor a disk
   problem it is supposed to detect. Top 15 by footprint is ~130 k rows/day.
3. **Adaptive cadence keys off health, not profiling runs.** The original design
   said 1 s "while a `sitrep run` is active", but that arrives in Milestone 4.
   Health state is a better trigger available now — high resolution exactly
   during an incident.

Storage:

- [x] `Storage/Database.swift` — SQLite C API wrapper: connection, prepared
      statements, typed binding, transactions
- [x] `Storage/Schema.swift` — DDL and versioned migration
- [x] `Storage/SampleStore.swift` — writes and history queries
- [x] `Storage/Rollup.swift` — 48 h raw / 30 d minute / 1 y hourly

Daemon:

- [x] `Daemon/DaemonPaths.swift` — Application Support locations
- [x] `Daemon/Collector.swift` — the tick loop, testable without process
      management; holds the previous reading and deltas without sleeping
- [x] `Daemon/LaunchAgent.swift` — plist generation, install, uninstall
- [x] `Sources/sitrepd` — entry point, signal handling, background QoS
- [x] `Health/HealthTracker.swift` — hysteresis, now that history exists
- [x] Daemon self-measurement against the 100 MB / 2% budget

Interface:

- [x] `sitrep daemon install|uninstall|status`
- [x] `sitrep history` — window summary, `--since`, `--json`

Tests:

- [x] Round-trip a sample through SQLite unchanged, including large `UInt64`
- [x] Migration is idempotent and versioned
- [x] Rollup aggregates correctly (avg for rates, max for peaks, worst for
      levels) and prunes aged rows
- [x] Hysteresis does not flap: a value oscillating around a threshold holds
      state until the dwell time passes
- [x] Collector produces samples across ticks without sleeping between reads

- Note: reported database size initially counted only the main file — 4 KB while
  the `-wal` held 210 KB uncheckpointed, a ~50× under-statement of mac-sitrep's
  own disk footprint. Now sums the sidecars. Exactly the dishonesty principle 6
  exists to prevent, and it took running the daemon for real to notice.
- Note: `pmset -g log` parsing for sleep/wake did not land. The `event` table has
  the `sleep`/`wake` kinds ready, but until it is built a gap in the timeline
  caused by the Mac sleeping is indistinguishable from the daemon being stopped.
  Carried to Milestone 4 or later.
- Note: two test failures came from stamping rows in the *future* — query
  helpers default `until` to now, so those rows were correctly filtered. Not a
  production issue (nothing writes future timestamps) but the API will silently
  return nothing if a caller ever does.
- Note: the LaunchAgent has not been installed on this machine. `sitrepd` was
  verified by running it in the foreground for 45 seconds. Installing a
  persistent background agent is the user's call.
- Note: no `sitrep watch` yet. The daemon now exists, so the deferral reason from
  Milestone 2 is resolved — watch should read from the store rather than
  re-sampling. Good candidate for a small follow-up.

## Milestone 4 — Workload profiling ⬜

- [ ] `Model/ProjectConfig.swift` — `.sitrep/project.json` decoding
- [ ] `Profiling/Attribution.swift` — wrapped process tree plus declared
      external services measured by before/during/after delta
- [ ] `Profiling/ProfileRun.swift` — N runs, median and range, contention flag,
      overhead subtraction
- [ ] `sitrep run --project X -- cmd` with exact start/end boundaries and exit
      code
- [ ] Profile JSON artifact at `.sitrep/profiles/<project>/<version>.json`
- [ ] Fast cadence hook so a profiling run drives 1 s sampling, alongside the
      health trigger
- [ ] Tests: attribution captures an external service's delta, median/range over
      repeated runs, artifact round-trips

## Parked / needs user input

- Full Xcode is not installed, so `swift test` depends on the vendored
  `swift-testing` package. No action needed unless you would rather install Xcode
  (~10 GB) and drop the dependency.
- Verifying Milestone 4's external-service delta attribution will want a real
  local-inference workload. Ollama is installed; confirm which model to profile
  against when we get there.
