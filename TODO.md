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

## Milestone 1 — Capability disclosure ⬜

- [ ] `Sampling/Capability.swift` — a probe per metric returning available, or
      unavailable with a machine-readable reason
- [ ] `sitrep doctor` rendering both lists, never omitting the unavailable ones
- [ ] Probes for the root-gated metrics that report *why* they are unavailable
      rather than simply being missing
- [ ] Self-budget line: mac-sitrep's own footprint against 100 MB / 2%
- [ ] `--json` output
- [ ] Tests asserting that every metric in ARCHITECTURE's capability table is
      probed, and that root-gated metrics report unavailable-with-reason

## Parked / needs user input

- Full Xcode is not installed, so `swift test` depends on the vendored
  `swift-testing` package. No action needed unless you would rather install Xcode
  (~10 GB) and drop the dependency.
- Verifying Milestone 4's external-service delta attribution will want a real
  local-inference workload. Ollama is installed; confirm which model to profile
  against when we get there.
