# mac-sitrep — Specification

Source of truth for scope. What the system should do and why. How it is built
lives in [ARCHITECTURE.md](ARCHITECTURE.md); when things land lives in
[ROADMAP.md](ROADMAP.md).

---

## Vision

A macOS observability and resource-accountability system that continuously
monitors the machine, profiles software workloads, detects resource incidents and
regressions, publishes measured resource requirements, optionally explains
incidents with an external AI model, and enforces configurable resource policies
such as zero-swap operation.

It answers four questions:

1. **What is happening?**
2. **Why is it happening?**
3. **How much does this software actually cost to run?**
4. **What should happen if it exceeds its limits?**

The organizing idea is **resource transparency**, and Steam is the closest
existing model — not as a counterexample, but as a project moving the same
direction.

Steam has long required developers to declare minimum and recommended specs,
which are estimates written by the developer. Valve's **Framerate Estimator**,
in beta on SteamOS devices as of 2026, replaces that with prediction from
measured data: anonymized opt-in telemetry from players on comparable hardware,
rendered as an expected-FPS chart against the specs of *your* machine. The shift
is from a declared guess to a measurement.

mac-sitrep mirrors that philosophy from the opposite vantage point. Steam
measures from the player fleet, after release, and aggregates across machines to
predict for a hardware class. mac-sitrep measures at the source, during
development, on the machine that ran the workload — and deliberately does not
generalize across hardware (see non-goals). The two are complements: fleet-side
prediction and source-side disclosure, both replacing an estimate with a number
somebody actually recorded.

Both also have to be honest about what the measurement cannot control for.
Steam's estimator cannot account for in-game graphics settings or background
load. mac-sitrep's equivalents are the scenario definition, the contention flag,
and the recorded thermal state — the same problem, named rather than hidden.

And mac-sitrep holds itself to the rule it applies to others. A tool that
measures the cost of other software must disclose its own.

---

## Core principles

| # | Principle | What it means in practice |
|---|-----------|---------------------------|
| 1 | **Zero external dependency for core functionality** | Monitoring, profiling, incidents, and enforcement work with no API credits and no network. |
| 2 | **AI is optional** | An external model is called only when natural language adds value, never in the monitoring path. |
| 3 | **Deterministic first** | The system decides *whether* something is wrong. AI only explains it. |
| 4 | **Measure, don't guess** | Requirements come from real profiling runs, never from developer estimates. |
| 5 | **Software should disclose its footprint** | Any project can publish measured requirements. |
| 6 | **mac-sitrep must disclose its own footprint** | The monitor is subject to every rule it applies to others, including its own resource budget. |
| 7 | **Observe before enforcing** | Workloads get warned, throttled, and asked to stop before they are killed. |
| 8 | **Remote, but secure** | Tailscale provides the private network. SSH stays as administrative fallback, never a dependency. |
| 9 | **Project-aware** | It understands *AI-PKS*, not just "Python". |
| 10 | **Don't become iStat Menus** | Raw system monitoring is the foundation, not the product. |
| 11 | **Runs unprivileged** | No root daemon, no privileged helper, no kernel extension. Where a metric requires elevated access, mac-sitrep does without it and says so. |
| 12 | **Telemetry stays local** | Nothing leaves the machine unless the user explicitly asks, and then only a scoped, redacted incident report. |

Principle 11 is not a limitation dressed as a virtue. mac-sitrep's most dangerous
capability is autonomous process termination; running unprivileged means the
kernel caps the blast radius at the user's own processes rather than relying on a
denylist being correct. Every comparable tool (iStat Menus, TG Pro, Macs Fan
Control) installs a root daemon. This one does not.

---

## What gets measured

### System

RAM, swap *usage and rate of change*, memory pressure, CPU utilization, GPU
utilization and allocated GPU memory, thermal state, disk capacity, disk I/O,
network I/O, running processes, per-process resource consumption, and
sleep/wake/reboot markers.

Health rolls up to a single state, with hysteresis so it cannot flap:

```
🟢 HEALTHY    🟡 WARNING    🔴 CRITICAL
```

### Per process

RAM (physical footprint), peak RAM, CPU, disk I/O, process lifetime, and process
tree.

**RAM means physical footprint, not RSS.** `ps` and `top` report RSS, which
overcounts shared pages; physical footprint is the number Activity Monitor shows
and the only defensible basis for a published requirement.

### Deliberately not measured

These require root, and principle 11 says we do without and disclose it:

| Metric | Why not | What we use instead |
|--------|---------|---------------------|
| CPU die temperature | SMC access requires root or private frameworks | Thermal *state* (nominal/fair/serious/critical) and the OS performance-limit flag |
| Fan RPM | Same | — |
| Package power (watts) | `powermetrics` requires root | — |
| Per-process network I/O | No public per-PID API exists on macOS | System-wide network I/O |
| Other users' process stats | Requires root | Everything the user owns, which on a single-user Mac is every workload that matters |

Per-process *disk* I/O **is** collected — it arrives in the same kernel structure
as physical footprint at no additional cost.

`sitrep doctor` lists both what is available and what is not, with the reason.
Silent omissions are a defect.

---

## Zero-swap, correctly defined

The original goal was "maintain 0 swap". Taken literally against the swap *file*
size, that goal is unachievable and misleading:

- macOS compresses memory before it swaps. Gigabytes can be compressed with zero
  swap, and the compressor is doing real work the swap number never shows.
- Swap file size is sticky. Once macOS grows it, it does not cleanly return to
  zero without a reboot.

So the policy is defined on the **rate**, not the level: sustained swap-*out*
activity is the violation, corroborated by memory pressure level. A machine that
touched swap once at 3am and has been quiet since is healthy. A machine writing
swap continuously is not, regardless of the total.

---

## Workload profiling

The central feature. mac-sitrep wraps a workload and measures its real footprint:

```
sitrep run --project AI-PKS -- python main.py
```

Captured: runtime, average and peak CPU, average and peak RAM, swap rate,
memory pressure, thermal state, GPU utilization and allocated GPU memory, disk
reads and writes, system-wide network, process tree, and subprocesses.

### Attribution

Naive process-tree attribution is wrong for exactly the workloads this project
exists to measure. When a project talks to Ollama or LM Studio, the model's
memory lives in a **pre-existing daemon outside the wrapped process tree**. The
wrapped client shows near-zero RAM while several gigabytes sit elsewhere.

Attribution is therefore: **the wrapped process tree, plus external services
declared per project and measured by before/during/after delta.**

### Reproducibility

A single run is a bad basis for a published requirement. Peak RAM varies with
thermal state, page-cache warmth, model quantization, context length, and what
else is running. So:

- Default to **five runs**, publish **median and range**, never a lone number.
- Record a **contention flag** when other significant workloads were active.
- Record machine, macOS build, project version, scenario name, and the exact
  command — a requirement without its workload definition is nearly as useless as
  a guess.
- **Subtract mac-sitrep's own overhead** from the run. Measurement perturbs the
  thing measured; the profiler accounts for itself.

Profiles are comparable across versions, which makes resource regressions
detectable:

```
AI-PKS v1.4   Peak RAM 9.7 GB   Peak swap 0
AI-PKS v1.5   Peak RAM 12.3 GB  Peak swap 480 MB

⚠️  Peak RAM +27%, swap newly introduced
```

---

## Publishing requirements

Any project can carry a standardized, generated requirements block:

```
sitrep export AI-PKS --format markdown --inject README.md
```

The published block is rendered from a committed JSON artifact, so:

- The README block is regenerable and verifiable.
- `--check` fails when the block has drifted from the latest profile, making it a
  pre-commit hook or a CI gate.
- CI cannot measure a Mac, but it *can* re-render from the committed JSON and
  fail on drift — so verification needs no Mac runner.

The inverse operation is equally useful, and is what makes published
requirements actionable rather than decorative:

```
sitrep can-i-run AI-PKS
→ 6.2 GB available; AI-PKS needs 9.7 GB peak. This will swap.
```

---

## Incidents

mac-sitrep detects *events*, not just numbers. Candidate incidents: swap-out rate
becomes sustained, memory pressure stays elevated, RAM exceeds a project budget,
CPU stays excessively high, thermal state degrades, disk approaches capacity,
process memory jumps suddenly, network spikes, the Mac becomes unreachable, or
mac-sitrep exceeds its own budget.

Each incident records timestamp, duration, trigger, telemetry, processes
involved, project involved, and resolution — and gets a chronological timeline,
so it is useful for debugging rather than merely alarming.

Two design requirements:

- **Attribute by delta, not by size.** The largest consumer is often not the
  cause. The signal is *who grew* in the window before pressure rose.
- **Observe the OS rather than duplicate it.** macOS jetsam already kills
  processes under sustained pressure. When it does, that is recorded as an
  incident — free telemetry, and it reveals when our own policy engine was too
  slow.

### Baselines

Fixed thresholds are not enough. A project's normal profile is learned and stored
so regressions are caught before any absolute limit is crossed:

```
AI-PKS normal peak RAM 9.1 GB · today 13.8 GB
⚠️  +52% vs. baseline
```

---

## Policy and enforcement

Projects declare resource contracts:

```
AI-PKS: max_ram 12GB · max_swap_rate 0 · max_cpu 90% · action terminate
```

Enforcement escalates rather than jumping to termination:

```
notify → throttle → suspend → graceful shutdown → SIGTERM → wait → SIGKILL
```

**Throttle** and **suspend** are the steps that matter. Moving a process to the
background QoS band throttles its CPU and I/O reversibly; suspending it stops the
bleeding instantly while preserving state for inspection. Both are undoable.
Killing destroys work and is the last resort.

Projects may register a safe shutdown command so mac-sitrep can stop them
cleanly.

### Enforcement guardrails

This is the most dangerous part of the system and is specified defensively:

- **Dry-run by default.** The policy engine logs `would have …` and takes no
  action until explicitly armed.
- **Allowlist only.** Enforcement applies solely to explicitly registered
  projects, never to arbitrary processes.
- **Hard denylist**, regardless of allowlist.
- **Circuit breaker.** Repeated firing within a window disarms the engine and
  notifies, so a kill/restart loop cannot run away.
- **Append-only audit log** recording every action and the telemetry that
  justified it.

---

## Optional AI explanation

AI is an explanation layer over a structured incident or run report — never part
of the monitoring path. It answers "explain what happened", "why did this
regress", "summarize this workload".

Provider-independent, with Gemini the preferred first target for its free tier
and DeepSeek an attractive low-cost alternative. Exact pricing and limits are
checked at implementation time, never baked into project assumptions.

Cost model:

```
monitoring · incident detection · profiling · enforcement   →  $0
AI explanation                                              →  optional API usage
```

Because telemetry is intimate — process names and paths reveal projects,
usernames, and directory structure — outbound reports are redacted, and
`sitrep explain --dry-run` prints the exact payload before anything leaves the
machine.

---

## Interfaces

**CLI is the primary interface** and should feel like a developer utility:
`sitrep`, `sitrep processes`, `sitrep incidents`, `sitrep run`, `sitrep sensors`,
`sitrep doctor`, `sitrep status <project>`, `sitrep explain <project>`,
`sitrep export`, `sitrep compare`, `sitrep can-i-run`, and `--json` everywhere.

The status display updates in place rather than printing a new line every few
seconds.

**Remote access** is a mobile-friendly web dashboard reached over Tailscale —
current state, active workloads, incidents and their timelines, historical
metrics, profiles, policies, and remote control. Destructive actions require
explicit confirmation. The listener binds to localhost or the Tailscale interface
only, never `0.0.0.0`. SSH remains an emergency path for when mac-sitrep itself
is broken; normal operation never requires it.

A native iPhone app is not required. A menu-bar indicator is a late nicety.

---

## Self-observability

Not an optional feature. mac-sitrep monitors itself in every mode — its own RAM,
peak RAM, CPU, disk footprint, runtime, and trend — and holds itself to a
declared budget:

```
mac-sitrep: max_ram 100MB · max_cpu 2%
```

Exceeding its own budget is an incident like any other. If the real measured
figure turns out to exceed the budget, **the budget is corrected to the truth and
disclosed**, never quietly dropped. A monitor that hides its own cost has failed
its own thesis.

---

## Non-goals

The highest-value section. These are out of scope for v1 and, where noted, out of
scope permanently.

| Non-goal | Why |
|----------|-----|
| **Root, privileged helpers, kernel extensions** | Permanent. Principle 11. |
| **Temperature and fan sensing** | Permanent as a core feature. Requires root or a dependency on another vendor's root daemon. Thermal *state* covers the actionable need. |
| **Per-process network I/O** | Permanent. No public API exists. |
| **Fan or system control of any kind** | Permanent. This is an observability tool, not a tuning tool. |
| **Being a general system monitor** | Principle 10. iStat Menus exists and is good at this. |
| **A native GUI application** | The CLI is the product. A web dashboard covers remote; a menu-bar indicator is optional and late. |
| **A native iPhone app** | The mobile web dashboard over Tailscale is sufficient. |
| **Public-facing network endpoints** | Tailscale is the network boundary. Nothing binds to a public interface. |
| **Continuous AI analysis of telemetry** | Principles 2 and 3, and it would destroy the $0 cost model. |
| **Cross-machine requirement normalization** | Profiles record the machine they were measured on. Predicting an M1 8 GB result from an M4 16 GB run is out of scope; the machine is reported, not abstracted away. This is the deliberate divergence from Steam's Framerate Estimator, which predicts across a hardware class by aggregating fleet telemetry. That requires a fleet. A single-machine tool that extrapolated from one sample would be publishing a guess with a measurement's authority — the exact failure this project exists to avoid. |
| **Windows or Linux support** | The entire value is in macOS-specific instrumentation. |

---

## Success criteria

mac-sitrep is working when:

1. A project's README carries measured requirements that were never typed by
   hand, and CI fails when they drift.
2. `can-i-run` correctly predicts whether a workload will fit before it is
   started.
3. A resource regression between two versions is caught by the tool rather than
   by the machine getting slow.
4. mac-sitrep's own published footprint is real, measured by itself, and within
   its declared budget — or the budget was corrected in public.
