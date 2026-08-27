# mac-sitrep — Roadmap

**v1 is complete as of 2026-08-27.** All five milestones shipped. A milestone is done when its capability
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
| 1 | ✅ done | **Capability disclosure** — `sitrep doctor`: 21 probes each attempting a real read, reporting available-with-sample or unavailable-with-reason; self-budget check; `--json`; non-zero exit on unexpected probe failure; 36 tests |
| 2 | ✅ done | **Live snapshot** — `sitrep` status with health state and reasons, `sitrep processes` sorted by memory or CPU; reading/sample split deriving per-second rates from cumulative counters; unreadable-process count disclosed; `--json` and `--interval` on both; 61 tests |
| 3 | ✅ done | **History and self-observability** — `sitrepd` LaunchAgent with background QoS, SQLite store with 48 h/30 d/1 y retention tiers, health-keyed 10 s/1 s cadence, hysteresis, daemon self-measurement including sustained CPU; `sitrep history` and `sitrep daemon install\|uninstall\|status`; 95 tests |
| 4 | ✅ done | **Workload profiling** — `sitrep run` and `sitrep init`: process-group attribution, external-service delta measured against a pre-run baseline and followed until stable, N runs to median/range, per-run timeout, under-observation and contention flags, JSON artifact; 120 tests |
| 5 | ✅ done | **Publishing** — `sitrep export` with marker-scoped README injection and a `--check` drift gate that needs no Mac in CI, shields.io badge JSON, `sitrep compare` for regressions, `sitrep can-i-run` for fit prediction; mac-sitrep publishes its own measured requirements; 152 tests |

## Post-v1 milestones

Milestone numbering continues from v1 rather than restarting — milestones name
capability slices, not per-version counters, and existing docs already
cross-reference them by number. Versions do a different job: **v1.x for
additive work, 2.0.0 reserved for the first network listener.** The HTTP API is
a genuine posture change in a tool that has never opened a socket, and that is
the boundary worth a major version.

Ordering constraints, planned as of 2026-08-27: cost accounting (M8) must land
before deployment estimation (M9), and the policy engine (M10) is armed only
against baselines that have aged for months — which is why enforcement sits
after the cost track rather than immediately after M7. The cost track as a
whole (M8–M9) can swap ahead of M6–M7 if a real hosting decision becomes
imminent; nothing in it depends on incidents. M12 floats — it can slot anywhere
after M6, and sits last because it is the only item that costs money.

| M | Release | Status | Deliverable |
|---|---------|--------|-------------|
| 6 | v1.2.0 | ⬜ planned | **Incidents** — detection, timelines, notifications; sleep/wake parsing and `sitrep watch` (carried from v1) |
| 7 | v1.3.0 | ⬜ planned | **Baselines** — learned per-project normal profiles, anomaly detection, hysteresis tuning |
| 8 | v1.4.0 | ⬜ planned | **Cost accounting** — API spend reporting protocol, dated pricing tables, time-to-ready |
| 9 | v1.5.0 | ⬜ planned | **Deployment fit and price** — hosting-shape fit/cost from the measured envelope; break-even analysis |
| 10 | v1.6.0 | ⬜ planned | **Policy engine** — the enforcement ladder, shipped dry-run with full guardrails |
| 11 | v2.0.0 | ⬜ planned | **Remote** — HTTP API on loopback/Tailscale, mobile web dashboard, remote control |
| 12 | v2.1.0 | ⬜ planned | **AI explanation** — provider-independent, redacted, `explain --dry-run` |

### Milestone 6 — Incidents

Incident detection over the daemon's history: swap-out rate becoming sustained,
pressure staying elevated, RAM over a project budget, sudden process growth,
thermal degradation, disk approaching capacity, mac-sitrep exceeding its own
budget. Each incident records trigger, duration, telemetry, processes, and
resolution, with a chronological timeline. Cause attribution is **delta-based
("who grew"), never size-based** — the largest consumer is often not the
culprit. Jetsam kills are observed and recorded as incidents: free telemetry,
and a measure of whether our own detection was too slow. macOS notifications
carry deduplication and cooldown. Surfaced by a `sitrep incidents` CLI.

Two items carried from v1 land here because incident timelines depend on them:
`pmset -g log` sleep/wake parsing (a gap in the timeline must be explainable —
"the Mac was asleep" and "the daemon was down" are different facts), and
`sitrep watch`, the in-place updating status display, reading from the store
rather than re-sampling (deferred from Milestone 2 for exactly this reason).

### Milestone 7 — Baselines

A project's normal profile is learned from accumulated history and stored, so
regressions are caught relative to *its* normal rather than an absolute
threshold — `sitrep status <project>` reports today against baseline. Fixed
health thresholds get tuned against real incident data from M6, and anomaly
detection ("+52% vs. baseline") becomes an incident trigger.

Design decision to settle before building: **where baselines live.** A learned
baseline represents months of observation and is not cheaply rebuildable, which
breaks the "history is disposable" premise behind ARCHITECTURE #7 and #42. The
likely answer is a durable, versioned artifact separate from the disposable
SQLite store — mirroring the existing store/committed-artifact split — but it
is an expensive-to-reverse choice and gets decided at design time, not mid-build.

This milestone ships early on purpose: baselines need calendar time to mature,
and M10's arming criterion is baselines with months of age. Starting the clock
here means the cost track can proceed while the data accrues.

### Milestone 8 — Cost accounting

External API spend as a first-class footprint dimension: a reporting protocol
the profiled workload writes token counts to, a date-stamped pricing table, and
cost fields in the profile artifact. Closes a gap in the current definition of
"footprint", which covers RAM, CPU, and disk but not the bill. Also required by
principle 6 — mac-sitrep's own AI layer (M12) would otherwise declare an API
cost it does not measure. Network-level and proxy capture are both rejected:
per-process network I/O needs root, TLS hides tokens from byte counts
regardless, and intercepting credentialed traffic contradicts the
local-telemetry principle. The workload declares what the OS cannot see, the
same pattern as external-service attribution (ARCHITECTURE #10).

**Time-to-ready measurement** lands here too — launch to serving, distinct from
total runtime, requiring a readiness signal from the workload. Prerequisite for
M9, since cold start is what decides whether scale-to-zero hosting is usable.

Prerequisite before the first new artifact field: a **schema compatibility
policy**. Profile JSONs are committed into other projects' repos and outlive
any one version of the tool, so the rule (additive-only plus a schema version;
old artifacts always render) is written down before M8 adds fields, not after
a 1.4 tool chokes on a 1.0 artifact someone committed a year ago.

### Milestone 9 — Deployment fit and price

Given a measured local envelope, which *hosting shapes* fit and what they cost:
scale-to-zero containers priced by GB-second, always-on instances priced by the
hour, serverless functions, and GPU instances. Shape matters more than instance
size for the target use case — a live demo is idle-dominated, so an always-on
box bills continuously while scale-to-zero bills almost nothing until someone
visits. Peak physical footprint is the binding input for GB-second pricing;
time to ready decides whether scale-to-zero is viable at all. Scoped as *fit
and price* only — performance prediction is a permanent non-goal in
[SPEC.md](SPEC.md). "Do not deploy this" must be a supported answer.

**Break-even analysis** completes the track: local, API, and deployment costs
combined into the run rate at which local execution stops being cheaper.

Two constraints on the cost work, recorded so they are not rediscovered later:
pricing tables ship as dated data files updated by an explicit command, never
auto-fetched, since background fetching would break the zero-external-dependency
principle. And coverage stays small and accurate — roughly a dozen curated
instance families with a staleness warning — rather than a large table that
silently goes out of date.

### Milestone 10 — Policy engine

The enforcement ladder — notify, throttle, suspend, graceful shutdown,
`SIGTERM`, wait, `SIGKILL` — shipping dry-run and explicitly armed
(ARCHITECTURE #12), with the full guardrail set: allowlist-only scope, hard
denylist, circuit breaker, append-only audit log. Registered projects may
declare a safe shutdown command. Arming is justified by M7 baselines that have
aged for months, not by thresholds that seemed reasonable — that gap in time is
the reason this milestone sits where it does.

### Milestone 11 — Remote (2.0.0)

A local HTTP API bound to loopback or the Tailscale interface — never
`0.0.0.0` — and a mobile-friendly web dashboard over it: current state, active
workloads, incidents and timelines, history, profiles, policies, and remote
control with explicit confirmation on destructive actions. A third executable
target over the same `SitrepCore`, as the architecture anticipated. This is
also where the control-operations seam from ARCHITECTURE #21 gets exercised:
reads stay on SQLite, control goes over the API.

### Milestone 12 — AI explanation

The optional explanation layer over finished incident and run reports — never
in the monitoring path. Provider-independent; pricing and limits checked at
implementation time. Outbound payloads are redacted, and `explain --dry-run`
prints exactly what would leave the machine before anything does.

### Unscheduled

- Menu-bar status indicator — kept minimal per principle 10
- Distribution: a Homebrew formula, with the signing and notarization it
  implies. `git clone && swift build` is fine for one machine and a bottleneck
  for anyone else's
- Multi-scenario marker blocks, so a project can publish more than one workload
  into the same README (current limit: one block per file)
- Profile staleness gate — `--check` proves the README matches the artifact,
  not that the artifact is current; a `--max-age` flag or a commit-distance
  check would close the last gap in success criterion #1
