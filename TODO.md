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

## Milestone 2 — Live snapshot ⬜

- [ ] `Model/Sample.swift` — one typed system sample: memory, swap, pressure,
      CPU, GPU, thermal, disk, network
- [ ] `Sampling/SystemSampler.swift` — composes the Support readers into a
      `Sample`, computing CPU utilization from a tick delta over an interval
- [ ] `Sampling/ProcessSampler.swift` — per-process rows sorted by physical
      footprint, with process-tree parentage
- [ ] `sitrep` default subcommand — current status, replacing `doctor` as the
      default
- [ ] `sitrep processes` — top consumers, `--limit`
- [ ] `--json` on both
- [ ] Tests: utilization sums to ~100% across states, footprint ordering is
      stable, a known process (self) appears with a plausible footprint

## Parked / needs user input

- Full Xcode is not installed, so `swift test` depends on the vendored
  `swift-testing` package. No action needed unless you would rather install Xcode
  (~10 GB) and drop the dependency.
- Verifying Milestone 4's external-service delta attribution will want a real
  local-inference workload. Ollama is installed; confirm which model to profile
  against when we get there.
