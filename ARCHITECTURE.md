# mac-sitrep — Architecture

How the system is built and why. [SPEC.md](SPEC.md) is the source of truth for
*what* it does; this document covers structure, technical decisions, and their
rationale. Sections are marked **built** or **designed** — designed sections
record decisions already made for subsystems that do not exist yet, so the
reasoning survives even though the code has not landed. Milestone status lives in
[ROADMAP.md](ROADMAP.md).

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
  logic and links no CLI code. `sitrep` (CLI) and, from Milestone 3, `sitrepd`
  (daemon) are thin shells over it.
- **External dependencies** — two Apple/swiftlang packages
  (`swift-argument-parser`, `swift-testing`) and one system library
  (`libsqlite3`). No network dependency at runtime.

Future shapes stay cheap because measurement is isolated behind samplers and
persistence behind a storage layer: a local HTTP API and web dashboard
(Milestone 6+) become a third executable target over the same `SitrepCore`, and
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

## Module Layout

**Built** (Milestone 0):

```
Package.swift                       # SwiftPM manifest; dependency policy comments
Sources/
  SitrepCore/                       # all measurement, storage, rendering logic
    Version.swift                   # package version constant
    Model/
      Machine.swift                 # machine identity; embedded in every profile
    Support/
      Sysctl.swift                  # typed sysctlbyname(3) wrappers
  sitrep/
    SitrepCommand.swift             # CLI root + `version` health-check subcommand
Tests/
  SitrepCoreTests/
    MachineTests.swift              # Machine + Sysctl suites (9 tests)
```

**Dependency rule.** `SitrepCore` imports only Darwin, Foundation, and IOKit —
never `ArgumentParser`, never CLI concerns. Executable targets depend on
`SitrepCore`; `SitrepCore` depends on neither. This is what allows the daemon and
a future HTTP server to be added as peers rather than as forks of the CLI.

**Designed**, arriving with the milestones named in [ROADMAP.md](ROADMAP.md):

```
SitrepCore/
  Sampling/                         # M1–M2
    Capability.swift                #   what this Mac can measure, and why not
    SystemSampler.swift             #   host_statistics64, sysctl, thermalState
    ProcessSampler.swift            #   proc_listpids + proc_pid_rusage(V4)
    GPUSampler.swift                #   IOKit AGXAccelerator PerformanceStatistics
    DiskSampler.swift               #   statfs + IOBlockStorageDriver
    NetworkSampler.swift            #   getifaddrs / if_data64
  Storage/                          # M3
    Database.swift                  #   SQLite, WAL, batched writes
    Rollup.swift                    #   retention tiers
  Profiling/                        # M4
    Attribution.swift               #   own tree + external-service delta
    ProfileRun.swift                #   N runs, median/range, contention flag
  Export/                           # M5
    MarkdownRenderer.swift
    ReadmeInjector.swift            #   marker-scoped replacement
    BadgeRenderer.swift             #   shields.io endpoint JSON
Sources/sitrepd/                    # M3 — LaunchAgent daemon
```

## Measurement sources — built

`Support/Sysctl.swift` is the only path to `sysctlbyname(3)` in the package.
`Sysctl.integer` reads the kernel's declared width and widens, rather than
assuming a width: a key whose kernel width is neither 4 nor 8 bytes returns `nil`
instead of a truncated or byte-swapped value. That is why
`Sysctl.integer("vm.swapusage")` correctly declines — `vm.swapusage` is a struct,
and is read properly in Milestone 2.

`Model/Machine.swift` composes `hw.model`, `machdep.cpu.brand_string`,
`hw.memsize`, `hw.logicalcpu`, and `kern.osversion` with Foundation's version
info. Individual fields degrade to `"unknown"` or a Foundation fallback rather
than failing the read: an unidentifiable machine should still be measurable, and
`sitrep doctor` surfaces the gap.

## Capability disclosure — designed

The following are confirmed readable **unprivileged** on `Mac16,10` (verified
during design):

| Metric | Source |
|--------|--------|
| Memory | `host_statistics64` / `HOST_VM_INFO64`; `sysctl vm.swapusage` |
| Memory pressure | `kern.memorystatus_vm_pressure_level` (1 normal / 2 warn / 4 critical) |
| Swap rate | `vm.compressor.swapouts_pressure`, `.swapins_pressure`, `.pages_swapped_pressure` |
| CPU | `host_processor_info` / `PROCESSOR_CPU_LOAD_INFO` deltas |
| Thermal | `ProcessInfo.thermalState`; `pmset -g therm` |
| GPU | IOKit `AGXAccelerator` → `PerformanceStatistics` → `Device Utilization %`, `Alloc system memory` |
| Per process | `proc_pid_rusage(RUSAGE_INFO_V4)` — footprint, lifetime peak, disk I/O, CPU time |
| Process tree | `proc_listpids` + `proc_bsdinfo.pbi_ppid`, `proc_pidpath` |
| Disk | `statfs`; IOKit `IOBlockStorageDriver` → `Statistics` |
| Network (system-wide) | `getifaddrs` + `if_data64` |
| Sleep/wake/reboot | `pmset -g log` |

Unavailable without root, and reported as such by `sitrep doctor` rather than
omitted: CPU die temperature, fan RPM, package power, per-process network I/O,
and other users' process statistics. See decision #4.

Two exceptions to decision #1's no-subprocess rule: `pmset -g therm` and
`pmset -g log` have no public API equivalent. Both are polled infrequently
(thermal on state change, sleep/wake on daemon start and hourly), never in the
sampling loop.

## Storage schema — designed

Lands in Milestone 3.

```sql
machine(id, hw_model, cpu_brand, ram_bytes, core_count, os_version, os_build,
        first_seen, last_seen)

sample(ts, resolution, mem_free, mem_active, mem_inactive, mem_wired,
       mem_compressed, swap_used, swap_ins, swap_outs, pressure_level,
       thermal_state, cpu_user, cpu_system, cpu_idle, gpu_util, gpu_mem_alloc,
       gpu_mem_inuse, disk_read, disk_write, disk_free, net_rx, net_tx)

process_sample(ts, pid, ppid, name, path_id, phys_footprint,
               peak_phys_footprint, cpu_user_ns, cpu_system_ns,
               diskio_read, diskio_write, start_time)

path(id, path)                    -- dictionary; long paths stored once
event(ts, kind, detail)           -- sleep, wake, reboot, jetsam_kill

profile_run(id, project, scenario, version, machine_id, started_at, ended_at,
            exit_code, command, run_index, contention_flag,
            overhead_ram, overhead_cpu)
profile_metric(run_id, metric, value)
```

Key properties encoded by the schema:

- **`sample.resolution` drives retention**, not a separate table per tier. Values
  are `raw` (10 s), `minute`, `hour`; rollup prunes `raw` beyond 48 h, `minute`
  beyond 30 d, `hour` beyond 1 y. Without this the "lightweight telemetry" of
  SPEC §19 would grow unbounded and the monitor would become a disk problem it
  is supposed to detect.
- **`profile_metric` is long-form** so adding a measured metric needs no
  migration. `profile_run` holds only the fields every run has.
- **`path` is a dictionary table** because executable paths are long, highly
  repetitive across samples, and would otherwise dominate the database size.
- **`profile_run.overhead_ram` / `overhead_cpu` are stored per run**, so
  mac-sitrep's own cost can be subtracted from a published requirement. See
  SPEC's observer-effect requirement.
- **`event` records what the OS did**, including jetsam kills, so incidents can
  distinguish "we acted" from "macOS acted first".

Writes are batched — the daemon buffers roughly 60 s of samples and flushes once
— so that a tool reporting disk I/O is not itself a meaningful source of it.

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
