# mac-sitrep — Architecture

How the system is built and why. [SPEC.md](SPEC.md) is the source of truth for
*what* it does; this document covers structure, technical decisions, and their
rationale. Every section describes code that exists as of v1.0.0; decisions
recorded for subsystems not yet built are marked as such in the log. Milestone
status lives in [ROADMAP.md](ROADMAP.md).

## System Shape

A single-user, local-first macOS command-line tool with a background sampling
daemon.

- **Runtime** — Swift 6, targeting macOS 14+. Built with SwiftPM.
- **Privilege** — entirely unprivileged. No root daemon, no `SMJobBless` helper,
  no kernel extension. Runs as a user `LaunchAgent`.
- **Storage** — SQLite (system `libsqlite3`) in the user's Application Support
  directory for local history; committed JSON artifacts in each profiled
  project's repo for published requirements.
- **Boundaries** — `SitrepCore` holds all measurement, storage, and rendering
  logic and links no CLI code. `sitrep` (CLI) and `sitrepd` (daemon) are thin
  shells over it. They communicate only through the SQLite file: the daemon
  writes, the CLI opens read-only. There is no IPC layer (decision #21).
- **External dependencies** — two Apple/swiftlang packages
  (`swift-argument-parser`, `swift-testing`) and one system library
  (`libsqlite3`). No network dependency at runtime.

Future shapes stay cheap because measurement is isolated behind samplers and
persistence behind a storage layer: a local HTTP API and web dashboard
(Milestone 11) become a third executable target over the same `SitrepCore`, and
an alternative store would replace the storage layer without touching samplers.
The AI explanation layer is deliberately a consumer of finished incident reports,
never a participant in the sampling path, so it can be absent entirely.

## Decisions Log

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Swift, with all metrics read through `libproc` / `sysctl` / IOKit and **no subprocess spawning in the sampling loop** | The self-imposed budget is 100 MB and 2% CPU (SPEC principle 6). Shelling out to `ps` or `vm_stat` every few seconds costs more CPU than the sampling itself and perturbs the very measurement being taken. Python was rejected: a bare interpreter is ~40 MB before measuring anything, which would make principle 6 embarrassing. Rust was rejected on setup cost — no toolchain installed, and IOKit needs binding work Swift gets for free. `Support/Sysctl.swift` is the seam every metric read passes through. |
| 2 | Dependency policy: Apple/swiftlang-maintained packages and system libraries only | SPEC principle 1 demands core functionality work with no credits and no network. A third-party YAML parser or SQLite wrapper (GRDB) would add supply chain and update cadence the project does not control. Costs: hand-written SQL, and JSON rather than YAML config (#8). |
| 3 | Take an explicit `swift-testing` package dependency | Command Line Tools vendors neither XCTest nor the toolchain's bundled `Testing` module — both ship only with full Xcode, which is not installed. Verified: `import XCTest` and bare `import Testing` both fail to resolve. The package build works and emits a deprecation warning saying the module is toolchain-bundled; that guidance does not apply without Xcode. Seam: if full Xcode is ever installed, delete the dependency — the `import Testing` test code is unchanged. |
| 4 | Unprivileged only — no root, ever | SPEC principle 11. The tool's most dangerous capability is autonomous process termination; running unprivileged means the kernel caps the blast radius at the user's own processes rather than trusting a denylist to be correct. Costs CPU temperature, fan RPM, package power, and per-process network I/O — all disclosed rather than silently omitted. Rejected: a minimal root helper for sensors only, because it reintroduces an installer, code-signing burden, and the exact risk surface the principle exists to remove. |
| 5 | Per-process memory is `ri_phys_footprint`, never RSS | `ps`/`top` RSS overcounts shared pages, so a published requirement based on it would be wrong. Physical footprint is what Activity Monitor reports. `proc_pid_rusage` also yields `ri_lifetime_max_phys_footprint` — kernel-tracked exact peak RAM, free and without polling — which is strictly better than sampling for peak capture. |
| 6 | Zero-swap is defined on swap **rate**, not swap level | macOS compresses before swapping, so gigabytes can be compressed at zero swap; and swap file size is sticky, never cleanly returning to zero without a reboot. A level-based policy would be permanently violated and therefore useless. The signal is sustained swap-*out* activity plus memory pressure level. |
| 7 | SQLite for local history; committed JSON artifacts for published requirements | One file, zero ops, transactional, and in the base system so it costs no dependency. The split matters: SQLite holds the machine's history and is disposable, while the JSON artifact is committed to the profiled project's repo and is the source of truth for what is published. That is what lets CI re-render and verify a README without needing a Mac runner. |
| 8 | Project config is JSON at `.sitrep/project.json` | `JSONDecoder` is built in, so this costs no dependency (#2). YAML would read better by hand but needs a third-party parser or a hand-rolled subset that mis-handles edge cases. Mitigated by generating the file with `sitrep init` rather than hand-typing it. Cost: no comments in config. |
| 9 | Minimum target macOS 14 | Every API used is far older, so nothing is lost, and it keeps the tool runnable on Intel and older Apple Silicon if profiles are ever compared across machines. Targeting only macOS 26 would remove availability annotations but make the tool unrunnable for anyone else. |
| 10 | Attribution is the wrapped process tree **plus declared external services measured by delta** | Naive tree attribution is wrong for exactly the workloads this project exists to measure: when a project calls Ollama or LM Studio, the model's memory lives in a pre-existing daemon outside the tree, so the wrapped client shows near-zero RAM. External services are declared per project and attributed by before/during/after delta. |
| 11 | Profiles default to five runs and publish median with range | Peak RAM varies with thermal state, page-cache warmth, quantization, context length, and background load. A single sample is barely better than a guess, which would undercut SPEC principle 4. A contention flag records when other significant workloads were active. |
| 12 | The policy engine ships dry-run and must be explicitly armed | Enforcement is the riskiest subsystem, and arming it against unvalidated baselines invites kill/restart loops. It logs `would have …` until `sitrep arm`. Recorded now so the posture is not relitigated when the subsystem is built in a later milestone. |
| 13 | Capabilities are established by **probing** — attempting a real read — never by consulting a static table | A table of what ought to work is a claim, not a measurement, and SPEC principle 11 makes honest gaps a correctness property rather than a nicety. This paid for itself immediately: the first `memory.swap_rate` implementation named `vm.compressor.swapouts_pressure`, which does not exist (the real key has a `.swapper.` component). A static table would have shipped that error into published profiles silently. Cost: `doctor` does real I/O, so it is not free to run. |
| 14 | System-wide network I/O reads `sysctl NET_RT_IFLIST2`, not `getifaddrs(3)` | The `if_data` struct `getifaddrs` returns carries **32-bit** byte counters that wrap every 4 GB — unusable for cumulative I/O in a monitoring tool, and a bug that only shows up after the machine has been up a while. `NET_RT_IFLIST2` returns `if_msghdr2`, whose embedded `if_data64` counters are 64-bit. Same source `netstat -ib` uses. Loopback is excluded via `IFF_LOOPBACK`, so local development traffic does not read as network load. |
| 15 | The self-budget verdict tests **lifetime peak** footprint, not instantaneous | A process that spiked to 400 MB and has since settled to 40 MB is not within a 100 MB budget; testing the instantaneous value would let it report compliance. `ri_lifetime_max_phys_footprint` makes the honest check as cheap as the dishonest one (#5). |
| 16 | Page size comes from `sysconf(_SC_PAGESIZE)`, not the `vm_kernel_page_size` global | Swift 6 rejects the global as shared mutable state, but the substantive reason is correctness: the compile-time `PAGE_SIZE` constant reports 4 KB while Apple Silicon actually uses 16 KB pages. Since `host_statistics64` returns counts in pages, getting this wrong would divide every memory figure by four. A test asserts agreement with `hw.pagesize`. |
| 17 | Qualifies #5 — a derived peak is `max(ri_lifetime_max_phys_footprint, observed samples)`, not the kernel field alone | #5 claimed the kernel's high-water mark was "strictly better than sampling for peak capture". That is too strong. The field is refreshed at task-accounting boundaries rather than synchronously with `ri_phys_footprint`, so during rapid growth it can read *lower* than the live footprint — caught by a test on an M4 reporting peak 4,800,824 against footprint 4,833,592. `Rusage` still returns raw kernel values; `SelfFootprint` and, later, the profiler take the max. Erring toward over-reporting is the safe direction for both a budget check and a published requirement. Had this gone unnoticed, Milestone 4 would have under-reported peak RAM in exactly the fast-allocating workloads the project exists to measure. |
| 18 | Reported "memory used" is active + wired + compressed, deliberately smaller than `top`'s total − free | macOS has no authoritative "used" figure. `top` counts inactive and file-backed cache the kernel reclaims on demand, which reads ~15 GB on a 16 GB Mac and implies a crisis that is not happening; cross-checked against `top -l 1` during development, where the wired and compressor components matched exactly and only the definition differed. Excluding reclaimable pages makes this the better predictor of approaching swap, which is what the project cares about. Every component is reported separately so a reader wanting `top`'s definition can compute it. Cost: someone comparing to `top` will see a smaller number and may think the tool is wrong. |
| 19 | Total memory comes from `hw.memsize`, not the sum of page buckets | Summing active + inactive + wired + compressed + free reported a 16 GB Mac as 15 GB, because `host_statistics64` also tracks speculative and purgeable pages outside those five categories. Every percentage derived from the total would have been inflated by ~6%. A regression test pins total to `hw.memsize` and asserts it is at least the bucket sum. |
| 20 | Per-process CPU utilization is uncapped at 1.0; system-wide utilization is capped | They answer different questions. A process using four cores fully reports 4.0, matching `top`'s 400% convention and making a parallel workload visible at a glance. System-wide, a figure that could reach 1000% on a 10-core machine is more confusing than useful, so it is normalized to the machine. |
| 21 | The CLI reads SQLite directly; no IPC socket | Previously designed as a Unix domain socket. WAL gives concurrent readers alongside the daemon's single writer, so `sitrep history` needs no protocol to design, version, or keep compatible — and it keeps working when the daemon is not running, which a socket would not. Supersedes the socket in the System Shape section. Seam: a socket becomes necessary when there are *control* operations to carry (start a profiling run, arm enforcement); reads will never need one. |
| 22 | Process history stores the top ~20 consumers per tick, not every process | ~500 readable processes at the resting cadence is ~4.3 M rows/day, which would make the monitor the disk problem it exists to detect. Top 15 by footprint plus the top 5 by CPU is ~130 k rows/day. The union matters: ranking on memory alone would make a busy compile invisible. Cost: a process that is never in either leaderboard leaves no trace in history. |
| 23 | Adaptive cadence keys off health state, not profiling runs | The original design said 1 s "while a `sitrep run` is active", but that arrives in Milestone 4. Health is a better trigger and available now — it gives high resolution exactly during an incident, which is when timeline detail is worth paying for, and costs nothing while the machine is fine. |
| 24 | Hysteresis is asymmetric: 15 s to escalate, 60 s to de-escalate | Escalate promptly, de-escalate reluctantly. A machine that looks clear for two seconds mid-incident has not recovered, and a symmetric threshold would let a value oscillating around a boundary produce an alert on every tick. Verified by a test that alternates states every 5 s for two minutes and asserts zero confirmed changes. |
| 25 | Rollups average rates, take the max of peaks, and keep the *worst* level | The mean of "normal" and "critical" is not a state, and an hour averaged to 30% CPU hides a minute at 100% — which is usually the interesting part. Level columns are ranked explicitly in SQL because text ordering puts 'critical' before 'healthy' and would silently return the wrong answer. Aggregate rows are keyed on the deterministic bucket start, which makes rollup idempotent. |
| 26 | Attribution follows the **process group**, not the parent chain | When an intermediate parent exits its children are re-parented to launchd, severing any ppid walk back to the workload root — so a build script that backgrounds work would lose it. `sitrep run` spawns via `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, and descendants are matched on pgid, which survives re-parenting. Setting the group with `setpgid` after `Process` launches races the child's `exec`, which is why Foundation's `Process` is not used. |
| 27 | Kernel lifetime-peak footprint is used for the spawned group and **not** for external services | For a process this run started, the kernel's high-water mark covers exactly the run. For a pre-existing daemon it includes history from before we attached — profiling against an Ollama instance that had already served a large model would attribute that earlier peak to this run. Services are measured from observed samples against a pre-run baseline instead. |
| 28 | `ri_user_time` and `ri_system_time` are **mach absolute time units**, not nanoseconds | Despite the field names. They tick at 24 MHz on Apple Silicon, so dividing by 1e9 under-reports CPU by 41.67×: a busy loop that should read 100% read 2.4%, and the daemon reported its own CPU as 0.0%. Converted once in `Rusage` via `mach_timebase_info` so every consumer is correct. Verified by burning a known second of CPU and checking the ratio. |
| 29 | A run's peak is reported as unmeasured rather than zero when too few samples land | A 280 ms workload reported "0 B peak" simply because nothing was observed between spawn and exit. Presenting "we saw nothing" as "it used nothing" is the worst failure available to a measurement tool. Sampling is 50 ms and any run under three samples is flagged, not silently averaged in. |
| 30 | External services are followed until their footprint **stops growing**, not for a fixed window | An inference server keeps loading after the client that asked it returns: `ollama run` against a cold model captured 349 MB while the server settled far higher. A fixed post-run window has no principled length, since load time depends on the model. Watching until growth stops supports a claim the tool can defend — *we watched until it stopped growing* — with a 30 s cap that is recorded when hit. |
| 31 | Every run is bounded by a timeout that kills the process **group** | A profiler that can hang forever is a bad profiler. Not hypothetical: `ollama run` inherits stdin, and with stdin on a pipe that never closed it slept for seventeen minutes instead of answering. Killing the group rather than the pid is why the group exists — signalling the leader alone would orphan its children. Timed-out runs are recorded as such, since they measured a hang rather than the work. |
| 32 | During a run, full process-table scans happen every 5th sample; targeted reads in between | The full scan costs ~4 syscalls across ~800 processes. At 50 ms that was ~13% CPU — enough for the profiler to distort the CPU-bound workloads it exists to measure. Known group members are re-read directly between scans, which cut overhead 57% (0.861 s → 0.373 s CPU on the same workload) with identical results. Contention is only accumulated from full scans, since a targeted read sees nothing outside the workload. |
| 33 | The rendered block reads **only** the artifact, never the clock or the machine | Re-rendering the same artifact must be byte-identical, or `--check` reports drift on every run and the CI gate is worthless. So the block carries the profile's `generatedAt`, not the render time, and its date is day-precision — time of day would add churn for information no reader can use. This is the practical payoff of #7's artifact-as-source-of-truth. A test asserts the block does not contain today's date. |
| 34 | `--check` and `--inject` share one implementation | A drift gate that compared against a second, subtly different renderer would report drift that does not exist, and a repo would never go green. `ReadmeInjector.apply` produces the document that *would* be written; `--inject` saves it, `--check` compares it. |
| 35 | Injection refuses unbalanced, duplicated, or reversed markers rather than repairing them | The file is hand-written and the block is a guest in it. Any automatic repair of markers we cannot interpret risks eating someone's prose, and the failure is cheap to fix by hand. Missing markers are the one safe case: a section is appended rather than inserted at a guessed position, since inserting would reorder the document. |
| 36 | `compare` uses medians, and calls newly-introduced swap out separately | Comparing peaks would let one unlucky run read as a regression, which is the reason profiles carry a distribution at all. Swap is handled apart from the percentage comparisons because a ratio against a zero baseline is meaningless — going from no swapping to any swapping is categorical. The 10% significance floor sits above the spread a stable measurement shows. |
| 37 | `can-i-run` defines available memory as free + inactive | Inactive pages are reclaimable on demand, and macOS deliberately keeps very little memory actually free — using `free` alone would report that nothing fits on a perfectly healthy machine. Deliberately a claim about *this* machine only; predicting fit on unseen hardware is a permanent non-goal. |
| 38 | Recommended-RAM rounding granularity scales with magnitude | Rounding everything up to whole gigabytes reported "1.0 GB recommended" for a tool whose measured peak was 2.2 MB — technically true, useless in practice, and corrosive to the credibility of every other number printed beside it. Steps are 8 MB below 64 MB, 64 MB below 1 GB, and 1 GB above. |
| 39 | Injection markers are recognized only when alone on a line | Found by this project's own README: the Usage section explains the marker syntax in a sentence, and a substring scan counted that as a second start marker and refused to inject. Any project documenting how injection works would hit the same wall. Our writer always emits markers on their own line, so requiring it costs nothing. Indented markers still count; markers inside prose do not. |
| 40 | Supersedes #18 — used memory is **app memory + wired + compressed**, matching Activity Monitor | #18 excluded reclaimable pages, which was the right instinct applied with the wrong proxy. It used `active`, but `inactive` is not uniformly reclaimable: it holds file-backed pages (free to drop) *and* anonymous pages owned by processes and dirty, which cost a compression or a swap to reclaim. Excluding the latter under-reported by 1.2 GB on a real 16 GB Mac — 11 GB against Activity Monitor's 12.8 GB — for no defensible reason. App memory is `internal_page_count − purgeable_count`; verified against `vm_stat` at 4.9 GB vs 4.88 GB. Matching Activity Monitor is a feature, not a coincidence: a reader can cross-check against a tool they already trust. Still below `top`'s total − free, which counts the file cache. |
| 41 | Available memory is total − used, replacing free + inactive | Same error in the same place: counting `inactive` as available treats anonymous dirty pages as free when obtaining them costs a swap. Deriving available from used keeps `sitrep` and `can-i-run` telling the same story, and means one definition governs both. |
| 42 | Redefining a stored metric bumps the schema and clears the affected rows | The v1 → v2 change altered what `mem_used` means. No arithmetic recovers the missing pages after the fact, and a `history --since 7d` spanning the change would silently average two different quantities — the invisible wrongness this project exists to prevent. Samples are dropped; machine identity, events, and self-measurements survive, and an event records why the gap is there. History is disposable by design (#7), which is what makes this affordable. |
| 43 | Profiles report exact CPU time from `wait4` rusage, with sampled peak CPU labelled by its window | A sampled peak is a property of the sampling rate as much as of the workload: `sitrep processes` consumes 0.035 s of CPU in bursts shorter than the 50 ms sampling window, so the window averages a near-full core down to 31%. Published as an unqualified "Peak CPU 31%" that reads as a heavy tool, which it is not. `wait4` returns the child's rusage on exit — exact, sampling-independent — so CPU *time* leads the published table and peak follows with "(per 50 ms window)" attached. Sampling could never produce the exact figure; nothing is lost by taking it from the kernel. |
| 44 | A plain-language CPU label is derived from **machine share**, never from peak CPU, and never appears without its number | "Peak CPU 31%" is opaque, and the fix is a word — but the word cannot hang off peak. Peak is a share of *one core*, a denominator most readers will not supply, and it is averaged down by the sampling window, so identical software sampled faster would earn a heavier label. `cpuSeconds ÷ wallClock ÷ coreCount` has neither problem: exact, and a fraction of a well-defined whole. Thresholds are published rather than hidden, and the label is always rendered beside the percentage and the core count — a word alone invites trust in a judgement whose scale the reader cannot see. Same software can score differently on different hardware; that is intended, since one core of four is a bigger imposition than one core of ten, and every profile records its machine. |
| 45 | Threshold scales are validated against real workloads, not reasoned about | The first pass put the light/moderate boundary at a flat 10% of the machine, which looked defensible and reported a core pinned solid for two seconds on a 10-core Mac as *Light*. Running an actual CPU-bound workload through the scale is what surfaced it. The boundary now sits near "occupies one whole core" — 10% on a ten-core machine, 25% on a four-core one. Any future classifier (incident severity, cost bands) gets the same treatment before it ships. |
| 46 | The running binary is located with `_NSGetExecutablePath`, never `argv[0]` | `argv[0]` is whatever the caller typed. Invoked through `PATH` it is the bare word `sitrep`, which resolves against the *current directory* — so `daemon install` looked for `sitrepd` inside whatever project the user happened to be standing in and failed for everyone who did not invoke it by absolute path. It passed every test and every manual check, because both had used a full path. `_NSGetExecutablePath` returns the real path regardless of invocation. |
| 47 | `daemon status` reports the running daemon's version, from its own start event | Replacing the binary on disk does not restart a running daemon, so the CLI and collector drift apart silently — the confusion that surfaced #46. The daemon stamps its version into a `daemon_start` event, so the CLI can read it back and flag a mismatch. Known rough edge: for a second or two after install the last recorded event is still the previous daemon's, so a fresh install can briefly warn about skew that no longer exists. Self-correcting, and the remedy it suggests is idempotent. |

## Module Layout

**Built** (Milestones 0–5):

```
Package.swift                       # SwiftPM manifest; dependency policy comments
Sources/
  SitrepCore/                       # all measurement, storage, rendering logic
    Version.swift                   # package version constant
    Model/
      Machine.swift                 # machine identity; embedded in every profile
      SelfFootprint.swift           # mac-sitrep's own cost + declared budget
      ThermalState.swift            # shared thermal enum
      Sample.swift                  # SystemReading (raw) + Sample (derived rates)
      ProcessSample.swift           # ProcessReading, ProcessSample, ProcessSnapshot
      HealthState.swift             # 🟢/🟡/🔴 from named thresholds
      ProjectConfig.swift           # .sitrep/project.json
      Profile.swift                 # Statistic, RunResult, the artifact
    Health/
      HealthTracker.swift           # hysteresis over successive samples
    Storage/
      Database.swift                # SQLite C API: connection, statements
      Schema.swift                  # DDL and versioned migration
      SampleStore.swift             # writes and history queries
      Rollup.swift                  # aggregation and retention
    Export/
      MarkdownRenderer.swift        # requirements block from an artifact
      ReadmeInjector.swift          # marker-scoped replacement + BadgeRenderer
      ProfileComparison.swift       # regression diff, fit prediction, discovery
    Profiling/
      Attribution.swift             # pgid group + external-service delta
      ProfileRun.swift              # settle, spawn, sample, aggregate
    Daemon/
      DaemonPaths.swift             # Application Support locations
      Collector.swift               # the tick loop, testable in-process
      LaunchAgent.swift             # plist, install, uninstall, status
    Sampling/
      Capability.swift              # capability identity, status, typed reasons
      CapabilityRegistry.swift      # all 21 probes; the disclosure contract
      SystemSampler.swift           # read() for the daemon, sample() for the CLI
      ProcessSampler.swift          # per-process readings, derived CPU, sorting
    Support/
      Sysctl.swift                  # typed sysctlbyname(3) wrappers
      MachHost.swift                # host_statistics64, host_processor_info
      Rusage.swift                  # proc_pid_rusage RUSAGE_INFO_V4
      ProcessList.swift             # proc_listpids, proc_pidpath, ppid
      IOKitRegistry.swift           # IOAccelerator, IOBlockStorageDriver
      NetworkInterfaces.swift       # NET_RT_IFLIST2 64-bit counters
      SwapUsage.swift               # vm.swapusage + pressure/compressor counters
      CommandRunner.swift           # bounded subprocess; pmset only
      Format.swift                  # byte/second/percent rendering at the edge
      Spawn.swift                   # posix_spawn into a new process group
  sitrep/
    SitrepCommand.swift             # CLI root
    StatusCommand.swift             # `sitrep` status rendering (default)
    ProcessesCommand.swift          # `sitrep processes` table
    DoctorCommand.swift             # `sitrep doctor` rendering + exit code
    HistoryCommand.swift            # `sitrep history` window summary
    DaemonCommand.swift             # `sitrep daemon` install/uninstall/status
    RunCommand.swift                # `sitrep run` and `sitrep init`
    ExportCommand.swift             # `sitrep export`, `compare`, `can-i-run`
  sitrepd/
    main.swift                      # run loop, signals, rollup schedule
Tests/
  SitrepCoreTests/
    MachineTests.swift              # Machine + Sysctl suites
    CapabilityTests.swift           # registry, measurement sources, budget, format
    SamplingTests.swift             # system + process sampling, health thresholds
    StorageTests.swift              # database, store, rollup
    DaemonTests.swift               # hysteresis, collector, launch agent
    ProfilingTests.swift            # statistic, config, spawn, attribution, artifact
    ExportTests.swift               # rendering, injection, badge, compare, fit
```

164 tests across twenty-six suites.

**Dependency rule.** `SitrepCore` imports only Darwin, Foundation, and IOKit —
never `ArgumentParser`, never CLI concerns. Executable targets depend on
`SitrepCore`; `SitrepCore` depends on neither. This is what allows the daemon and
a future HTTP server to be added as peers rather than as forks of the CLI.

All of v1 is built. The post-v1 subsystems named in [ROADMAP.md](ROADMAP.md) —
incidents, the policy engine, the HTTP API and dashboard, the AI explanation
layer, and cost accounting — have no modules yet.

## Measurement sources — built

`Support/Sysctl.swift` is the only path to `sysctlbyname(3)` in the package.
`Sysctl.integer` reads the kernel's declared width and widens, rather than
assuming a width: a key whose kernel width is neither 4 nor 8 bytes returns `nil`
instead of a truncated or byte-swapped value. That is why
`Sysctl.integer("vm.swapusage")` correctly declines — `vm.swapusage` is a struct,
and gets a purpose-built reader in `Support/SwapUsage.swift`.

The rest of the access layer sits beside it in `Support/`: `MachHost` for Mach
host statistics, `Rusage` for `proc_pid_rusage`, `ProcessList` for `libproc`
enumeration, `IOKitRegistry` for registry property lookups, `NetworkInterfaces`
for the route sysctl, and `SwapUsage` for the struct-valued swap keys. These are
deliberately thin — they return kernel data, not derived metrics. Rates and
utilization percentages need two reads over an interval and belong to the
samplers in Milestone 2.

`CommandRunner` is the quarantine for the one rule-breaking case. It exists so
that subprocess use is visible in one file and has to be justified when a caller
is added, rather than spreading quietly.

`Model/Machine.swift` composes `hw.model`, `machdep.cpu.brand_string`,
`hw.memsize`, `hw.logicalcpu`, and `kern.osversion` with Foundation's version
info. Individual fields degrade to `"unknown"` or a Foundation fallback rather
than failing the read: an unidentifiable machine should still be measurable, and
`sitrep doctor` surfaces the gap.

## Capability disclosure — built

Probed live by `sitrep doctor`. The following are confirmed readable
**unprivileged** on `Mac16,10`, each verified by an actual read rather than by
appearing in this table:

| Metric | Source |
|--------|--------|
| Memory | `host_statistics64` / `HOST_VM_INFO64`; `sysctl vm.swapusage` |
| Memory pressure | `kern.memorystatus_vm_pressure_level` (1 normal / 2 warn / 4 critical) |
| Swap rate | `vm.compressor.swapper.swapouts_total`, `.swapins_total`, `.swapouts_pressure` |
| CPU | `host_processor_info` / `PROCESSOR_CPU_LOAD_INFO` deltas |
| Thermal | `ProcessInfo.thermalState`; `pmset -g therm` |
| GPU | IOKit `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %`, `Alloc system memory` |
| Per process | `proc_pid_rusage(RUSAGE_INFO_V4)` — footprint, lifetime peak, disk I/O, CPU time |
| Process tree | `proc_listpids` + `proc_bsdinfo.pbi_ppid`, `proc_pidpath` |
| Disk | `statfs`; IOKit `IOBlockStorageDriver` → `Statistics` |
| Network (system-wide) | `sysctl NET_RT_IFLIST2` → `if_msghdr2` (64-bit counters) |
| Sleep/wake/reboot | `pmset -g log` |

Unavailable without root, and reported as such by `sitrep doctor` rather than
omitted: CPU die temperature, fan RPM, package power, per-process network I/O,
and other users' process statistics. See decision #4.

Two exceptions to decision #1's no-subprocess rule: `pmset -g therm` and
`pmset -g log` have no public API equivalent. Both are polled infrequently
(thermal on state change, sleep/wake on daemon start and hourly), never in the
sampling loop.

## Sampling — built

Two types, because the one-shot CLI and the daemon need different things from
the same sources.

```
SystemSampler.read()  ──▶  SystemReading   (instantaneous; cumulative counters)
                                │
        two readings + elapsed  ▼
                            Sample         (derived; carries per-second rates)
                                │
                                ▼
                          HealthState      (🟢/🟡/🔴 + reasons)
```

CPU ticks, disk and network byte totals, and swap counters are all **cumulative
since boot**. A single read of any of them yields an average over machine uptime,
which is useless as a "right now" figure. `Sample.init(from:to:)` turns two
readings and the elapsed time between them into rates.

The CLI takes two readings 500 ms apart and discards the first, which is why
`sitrep` blocks briefly and why `--interval` exists. The daemon (Milestone 3)
will instead hold the previous reading in memory and delta on each tick, never
sleeping — same types, no wasted wall-clock. That is the reason for the split;
collapsing it into one "get a sample" call would force the daemon to sleep too.

Counter deltas clamp at zero. The kernel's counters should only rise, but an
interface disappearing between readings can make a total drop, and a negative
rate would be nonsense rather than informative.

`HealthState` classifies from a single sample with **no hysteresis**. That is
correct for a one-shot command, which cannot flap, but insufficient for a
continuously updating display: a value oscillating around a threshold would
alternate states every tick. Hysteresis needs history and arrives with the
daemon. Thresholds live in `HealthThresholds` as named constants — they are
absolute values, and SPEC's position is that fixed thresholds are not enough, so
learned per-project baselines replace most of them post-v1.

## Storage schema — built

Defined in `Storage/Schema.swift`, version 2.

```sql
machine(id, hw_model, cpu_brand, ram_bytes, core_count, os_version, os_build,
        first_seen, last_seen)                  -- UNIQUE on the identity columns

sample(ts, resolution, interval_seconds, sample_count,
       mem_total, mem_used, mem_used_max, mem_active, mem_wired, mem_compressed,
       mem_free, swap_used, swap_outs_per_sec, swap_outs_per_sec_max, pressure,
       cpu_util, cpu_util_max, cpu_user, cpu_system,
       gpu_util, gpu_mem_alloc, thermal,
       disk_free, disk_read_per_sec, disk_write_per_sec,
       net_rx_per_sec, net_tx_per_sec, health)
       PRIMARY KEY(ts, resolution)

path(id, path)                                  -- UNIQUE dictionary
process_sample(ts, pid, ppid, name, path_id, footprint, peak_footprint,
               cpu_util, disk_read, disk_written)   PRIMARY KEY(ts, pid)
event(id, ts, kind, detail)
daemon_sample(ts, footprint, peak_footprint, cpu_util, within_budget)
```

Key properties encoded by the schema:

- **One `sample` table for every tier**, discriminated by `resolution`
  (`raw`/`minute`/`hour`), rather than a table per tier. A query spanning tiers
  stays a single `SELECT`, and retention is a `DELETE` with a `WHERE` clause.
- **Paired average and max columns** on the values where a peak matters, because
  an hour averaged to 30% CPU hides a minute at 100%. For raw rows the pair is
  equal; the distinction only becomes meaningful after a rollup (decision #25).
- **`path` is a dictionary table.** Executable paths are long and repeat on every
  tick; storing them once keeps process history from dominating the file.
  Orphans are dropped when the rows referencing them are pruned.
- **`daemon_sample` is separate from `process_sample`** and carries the budget
  verdict. Self-observability is a requirement, not an incidental row
  (SPEC principle 6).
- **`event` records discrete happenings**, as distinct from sampled levels. This
  is what lets a gap in the timeline be explained rather than mysterious.

History is disposable by design — it describes one machine and rebuilds by
running longer — so migrations favour clarity over preserving every past row.
That would be the wrong trade for the committed profile artifacts, which are the
published source of truth (#7).

## Daemon — built

```
launchd ──▶ sitrepd ──▶ Collector.tick()
                            │
                 SystemSampler.read() ──▶ SystemReading
                            │  (delta against the previous reading — no sleep)
                            ▼
                         Sample ──▶ HealthTracker (hysteresis)
                            │
                            ▼
                       SampleStore ──▶ SQLite (WAL)
                            ▲
                            │ read-only
                       sitrep history
```

`Collector` holds no process-management or signal concerns, so `tick(at:)` runs
synchronously in tests. `sitrepd` owns only the run loop, `SIGTERM`/`SIGINT`
handling, and the rollup schedule.

The first tick produces no sample — it only primes the delta — which is why the
daemon's first row appears one interval after start.

A failed tick logs and continues rather than exiting. A transient SQLite lock or
a momentarily failing sysctl should cost one sample, not the whole history;
persistent failure shows up as a gap plus log lines.

Rollup runs on a wall-clock schedule (every 10 minutes) rather than a tick count,
so its cost does not scale with the alert cadence.

## Profiling — built

```
sitrep run ──▶ settle (baseline declared services)
                   │
                   ▼
           Spawn.launch ──▶ new process group
                   │
                   ▼
     sample every 50 ms ──┬── own group  (pgid match)
                          ├── services   (substring match)
                          └── everything else → contention
                   │  full table scan every 5th sample
                   ▼
           poll(WNOHANG) ──▶ exited? ──▶ follow services until stable
                   │                            │
                   ▼                            ▼
              RunResult ──── × N runs ───▶ Statistic (median, min, max)
                                                 │
                                                 ▼
                                    .sitrep/profiles/<project>/<version>-<scenario>.json
```

The two populations are measured differently on purpose. The spawned group can
use the kernel's lifetime-peak footprint, because those processes were started by
this run. Declared services cannot — their high-water mark predates us — so they
are measured as observed peak minus a pre-run baseline (#27).

That distinction is the whole point. Profiling `ollama run` against a 4B model
measured **11 MB in the spawned group and 416 MB in the external service**: 97% of
the cost lives in a daemon that was already running, which naive process-tree
attribution reports as zero.

Three things bound the loop, each learned the hard way and each recorded as a
decision: exit is detected with `waitpid(WNOHANG)` rather than a liveness check
(#31 context — a zombie answers `kill(pid, 0)` forever), every run has a timeout
that kills the group (#31), and services are followed until they stop growing
rather than for a fixed window (#30).

## Publishing — built

```
.sitrep/profiles/<project>/<version>-<scenario>.json   (committed)
                    │
                    ▼
          MarkdownRenderer  ──▶ requirements block
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
  ReadmeInjector          BadgeRenderer
   --inject → write        shields.io endpoint JSON
   --check  → compare, exit non-zero on drift
```

Rendering reads the artifact and nothing else — not the clock, not the machine
(#33). That is what makes `--check` a usable CI gate: the same artifact always
produces the same bytes, so a difference means the README genuinely drifted
rather than that time passed.

Because the artifact is committed and the renderer is pure, **CI never needs a
Mac**. Profile locally, commit the JSON, and let CI re-render and compare.

`--check` and `--inject` run the same code path (#34); the gate answers "would
injecting change anything?" rather than reimplementing the comparison.

The block carries its own caveats — contention, instability across runs, thermal
throttling, timed-out or under-observed runs, and the capability gaps from
`doctor`. A requirements table with no caveats would imply a confidence the
measurement does not always have.

`compare` reads two artifacts and reports median deltas beyond a 10% floor,
warning when the two are not really comparable — different machines, scenarios,
or commands (#36). `can-i-run` inverts the published figure against memory
available right now (#37), which is what makes a number in a README actionable
rather than decorative.

## Known limitations

- **Tests require the vendored `swift-testing` package** on a machine without
  full Xcode. This is decision #3, not an oversight. `swift test` prints a
  deprecation warning advising removal of the dependency; following that advice
  breaks the build on Command Line Tools.
- **`Sysctl.integer` silently declines keys whose kernel width is not 4 or 8
  bytes**, returning `nil`. This is deliberate — the alternative is truncation —
  but it means a caller cannot distinguish "key absent" from "key is a struct".
  Struct-valued keys like `vm.swapusage` get purpose-built readers instead.
- **Machine identity degrades to `"unknown"` rather than failing.** A profile
  artifact from an unidentifiable machine is less useful but still valid; the
  alternative is refusing to measure at all.
- **The `power.sleep_wake` probe checks reachability, not the read.** It confirms
  `/usr/bin/pmset` is executable rather than running `pmset -g log`, whose output
  is megabytes and which would make `doctor` slow and memory-hungry for no gain.
  This is the one capability whose "available" is weaker than the others' — the
  parse itself lands with the daemon in Milestone 3, and could fail then despite
  probing clean now.
- **`IOKitRegistry` reads the first matching service only.** On a Mac with more
  than one accelerator or block device, GPU and disk figures describe the primary
  one rather than the total. Correct for the single-GPU Apple Silicon target;
  summing across services would double-count on machines with an internal and
  external GPU, so the fix is per-service reporting rather than aggregation.
- **The kernel's lifetime-peak footprint can lag the live value.**
  `ri_lifetime_max_phys_footprint` is refreshed at task-accounting boundaries,
  so a fast-growing process can briefly report a peak below its current
  footprint. `Rusage` returns the raw field; every consumer must derive a peak
  with `max()`. Decision #17.
- **Reported memory used matches Activity Monitor but not `top`.** `top` counts
  the reclaimable file cache and reads ~15 GB on a 16 GB Mac; ours excludes it
  (#40). Every component is reported separately so `top`'s definition stays
  recomputable.
- **`sitrep` and `sitrep processes` block for the sampling interval.**
  Unavoidable for a one-shot rate; 500 ms by default, tunable with `--interval`.
  Shorter intervals make CPU utilization noisy as scheduler quanta start to
  dominate the tick delta.
- **Process listings omit processes owned by other users.** Roughly 284 of ~800
  on a typical Mac. The count is always disclosed, but it does mean the memory
  total across listed processes is far below the machine's actual usage, and
  `sitrep processes` cannot be used to account for all of RAM.
- **The daemon's `synchronous = NORMAL` accepts losing the last commit on power
  loss.** Correct for disposable telemetry and it avoids an fsync every few
  seconds, but a hard crash can drop the most recent samples.
- **Process history only covers the leaderboards.** A process never in the top 15
  by memory or top 5 by CPU leaves no trace, so history cannot account for all of
  RAM (decision #22).
- **A destructive migration is the only upgrade path.** `Schema.migrate` refuses
  to run against an unknown older version and tells the user to delete the file.
  Acceptable while history is disposable; the first real forward migration slots
  in as a version-to-version step.
- **Sleep and wake are not yet recorded.** `pmset -g log` parsing is still
  unbuilt, so a gap in the sample timeline caused by the Mac sleeping is
  currently indistinguishable from the daemon having been stopped. The `event`
  table has the `sleep`/`wake` kinds ready for it.
- **Peak figures for mmap-backed model weights understate resident memory.**
  Physical footprint excludes file-backed pages, so a `llama-server` showing 3.3 GB
  RSS reported 628 MB footprint. That is the correct answer for "how much memory
  does this need exclusively" and the wrong one for "how much RAM is this
  occupying". Weights loaded by `mmap` are reclaimable, so counting them would
  overstate the requirement — but a reader comparing against Activity Monitor
  will see a large gap.
- **A workload shorter than a few sample intervals cannot be characterized.**
  Flagged rather than reported as zero (#29), but the floor is real: profiling
  something that runs in 100 ms will not produce a usable peak.
- **External-service attribution is substring matching on the executable path.**
  A declared service of `ollama` also matches anything else with that substring.
  Adequate for the real cases and cheap to reason about; a project needing
  finer matching would want a bundle id or listening port instead.
- **Peak CPU cannot see a burst shorter than the sampling window.** Reported at
  50 ms granularity, so a 15 ms burst at full core reads as roughly a third of
  one. `cpuSeconds` is exact and carries no such caveat, which is why it leads
  the published table (#43).
- **Disk-read comparisons are page-cache sensitive.** A second run of the same
  workload often reads nothing, which `compare` reports as a large improvement.
  It never produces a false *regression*, so it is left in as informative rather
  than excluded, but it is a poor regression signal on its own.
- **`sitrep export` publishes one scenario per marker block.** A project with
  several meaningfully different workloads can only publish one of them into a
  given file. Multiple blocks would need distinct marker names, which is not
  built.
- **`--check` proves the README matches the artifact, not that the artifact is
  current.** Nothing detects that the code changed and nobody re-profiled. That
  gap is real and belongs to whoever wires `sitrep run` into their release
  process.
- **`doctor` performs real I/O.** Probing is what makes the report trustworthy
  (#13), but it means the command reads sysctls, walks the IOKit registry,
  enumerates ~800 processes, and spawns `pmset`. It is cheap — roughly 30 ms and
  3 MB — but it is not free, and it is not something to call in a loop.
