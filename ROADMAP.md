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
- Menu-bar status indicator
