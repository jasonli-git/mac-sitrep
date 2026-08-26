# mac-sitrep — Roadmap

Milestone 0 is complete as of 2026-08-23. A milestone is done when its capability
works end to end, `swift build` and `swift test` both pass, the six project
documents reflect what actually exists, and the user has reviewed it.

v1 scope is **measure and publish** — the path from running a workload to a
measured requirements block in a README. Monitoring, incidents, enforcement, and
remote access are real parts of [SPEC.md](SPEC.md) but are deliberately staged
after it, so the policy engine is eventually armed against months of real
baselines rather than guesses.

## v1 Milestones

| M | Status | Deliverable |
|---|--------|-------------|
| 0 | ✅ done | **Scaffolding** — SwiftPM package, `SitrepCore`/`sitrep` split, sysctl bridge, machine identity, `sitrep version` health check, 9 passing tests, project docs |
| 1 | ⬜ planned | **Capability disclosure** — `sitrep doctor`: every sensor reported available, or unavailable with the reason; machine identity; self-budget check |
| 2 | ⬜ planned | **Live snapshot** — `sitrep` and `sitrep processes`: system + per-process state from `host_statistics64`, `proc_pid_rusage`, IOKit GPU/disk, `getifaddrs`; `--json` on both |
| 3 | ⬜ planned | **History and self-observability** — `sitrepd` LaunchAgent, SQLite store with retention tiers, adaptive 10 s/1 s cadence, daemon measuring itself against its declared budget |
| 4 | ⬜ planned | **Workload profiling** — `sitrep run --project X -- cmd`: project config, own-tree + external-service delta attribution, five runs to median/range, overhead subtraction, JSON artifact |
| 5 | ⬜ planned | **Publishing** — `sitrep export --inject` with marker-scoped README replacement and a `--check` drift gate, shields.io badge JSON, `sitrep compare`, `sitrep can-i-run` |

## Post-v1 (not scheduled)

- Incident detection, incident timelines, and macOS notifications with
  deduplication and cooldown
- Learned per-project baselines and anomaly detection against them
- Delta-based attribution ("who grew"), rather than size-based, for incident cause
- Jetsam kill observation recorded as incidents
- Health-state hysteresis tuning
- Policy engine and the enforcement ladder — notify, throttle, suspend, graceful
  shutdown, `SIGTERM`, `SIGKILL` — shipping dry-run and explicitly armed
- Enforcement guardrails: allowlist, hard denylist, circuit breaker, audit log
- Local HTTP API bound to loopback or the Tailscale interface
- Mobile web dashboard over Tailscale, with confirmation on destructive actions
- Optional AI explanation layer, provider-independent, with payload redaction and
  `explain --dry-run`
- **API cost accounting** — external API spend as a first-class footprint
  dimension: a reporting protocol the profiled workload writes token counts to, a
  date-stamped pricing table, and cost fields in the profile artifact. Closes a
  gap in the current definition of "footprint", which covers RAM, CPU, and disk
  but not the bill. Also required by principle 6 — mac-sitrep's own AI layer
  currently declares an API cost it does not measure. Network-level and proxy
  capture are both rejected: per-process network I/O needs root, TLS hides tokens
  from byte counts regardless, and intercepting credentialed traffic contradicts
  the local-telemetry principle. The workload declares what the OS cannot see,
  the same pattern as external-service attribution (ARCHITECTURE #10).
- **Time-to-ready measurement** — launch to serving, distinct from total runtime.
  Requires a readiness signal from the workload. Prerequisite for deployment
  estimation, since cold start is what decides whether scale-to-zero hosting is
  usable
- **Deployment fit and cost estimation** — given a measured local envelope, which
  *hosting shapes* fit and what they cost: scale-to-zero containers priced by
  GB-second, always-on instances priced by the hour, serverless functions, and
  GPU instances. Shape matters more than instance size for the target use case —
  a live demo is idle-dominated, so an always-on box bills continuously while
  scale-to-zero bills almost nothing until someone visits. Peak physical
  footprint is the binding input for GB-second pricing; time to ready decides
  whether scale-to-zero is viable at all. Scoped as *fit and price* only —
  performance prediction is a permanent non-goal in [SPEC.md](SPEC.md).
  "Do not deploy this" must be a supported answer. Depends on API cost
  accounting, time-to-ready, and on local profiles being trustworthy first.
- **Break-even analysis** — combining local, API, and deployment costs into the
  run rate at which local execution stops being the cheaper option
- Menu-bar status indicator

Two constraints on the cost work, recorded so they are not rediscovered later:
pricing tables ship as dated data files updated by an explicit command, never
auto-fetched, since background fetching would break the zero-external-dependency
principle. And coverage stays small and accurate — roughly a dozen curated
instance families with a staleness warning — rather than a large table that
silently goes out of date.
