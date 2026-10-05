# The autonomous guardian: fitness, environment, and the road to no human in the loop

This exists so the guardian can be *measurably* better at defending the mesh than the
placeholder rule — a machine-optimisable definition of "better" a human can audit, and a
world in which genomes are evaluated before they touch a live service.

**Kind:** BUILD (the simulator, the harness, the learner) wrapped around a CLAIM (the
fitness vector — a choice of what to value, owned and versioned by a human). **Status:**
draft, 2026-10-05. Follows *Where the SecOps brain lives* in
[PLAN_GUARDIAN_ARCHITECTURE.md](PLAN_GUARDIAN_ARCHITECTURE.md): evolution central in
mcl-sec-guard, reflex local in mcl_om, humans own the envelope. **Decision (Raf,
2026-10-05):** the deciding step is a TWEANN (`faber_tweann`).

## The lesson the placeholder rule already taught

The P0 rule optimised a proxy — "a window saw denials ⇒ lower `per_caller_max` to the
over-limit count" — that is wrong in the calm case: it would ratchet a service to
`per_caller_max = 1` on probe noise and starve legitimate callers. The 449 recorded
proposals are exactly that failure at small scale. A TWEANN without a better definition of
"better" will find the same degenerate policy faster and more convincingly. Everything
else in this plan is plumbing around that fact: **the fitness vector is the work.**

## 1. What "better" means

| Concern | Question | Ground truth (sim) | Live proxy (shadow) |
|---|---|---|---|
| **Containment** | Did attack pressure get denied before the handler? | attacker calls admitted / attempted | denials during attack windows; handler never sees the flood |
| **Admission** | Were legitimate calls preserved? | legit admitted / attempted | admitted count vs baseline throughput; no starvation windows |
| **Recovery** | How fast does the service return to quiet and to baseline limits? | windows until `denied_rate` is 0 twice consecutively | same, from the fact stream |
| **Stability** | How much did the posture move, and did it oscillate? | applies + total relative change | audit ring |
| **Constraint safety** | Envelope, starvation, service health | hard gates, see §2 | same + `/health` verdict |

## 2. The fitness vector

An **episode** is one procedure under one scenario for T windows (first cut T = 60), with
ground truth from the simulator. Per episode:

```
C (containment) = 1 - attacker_calls_admitted / attacker_calls_attempted
A (admission)   = legit_calls_admitted / legit_calls_attempted
R (recovery)    = 1 - min(1, quiet_windows / recovery_budget)
S (stability)   = 1 - min(1, (applies + churn) / churn_budget)

fitness = wc*C + wa*A + wr*R + ws*S
```

**Hard gates, not weights** — any one fails and the genome is rejected, with the failing
gate named in the report:

- **Envelope**: a move outside a key's `[min, max]`. A well-formed policy cannot produce
  one (the service refuses it), but the attempt is counted and disqualifies the episode.
- **Starvation**: `legit_admitted = 0` while `legit_attempted > 0` for more than `K`
  consecutive windows. This is the trap the placeholder rule falls into.
- **Health**: the service's health verdict degrades during the episode.
- **Runaway**: a limit pinned at the envelope floor for more than `F` windows after all
  pressure ended.

Weights, budgets and thresholds live in versioned config —
`{mcl_sec_guard, fitness, #{version, weights, budgets, thresholds}}` — and **a genome
records the fitness version it won under**. Changing the vector is a new version; genomes
are not comparable across versions without re-evaluation.

**Gaming is expected and reviewed.** The obvious cheats — inducing denials to look busy,
rejecting everyone to look contained, pinning the floor to look decisive — are exactly what
the gates and the scenario mix exist to catch. Every vector version gets an adversarial
pass (faber's gate style, three ranked changes, no unbounded review) whose findings become
scenarios, not prose.

## 3. What the policy sees (observations)

One policy for all procedures to start; per-class features can come later. Per window,
per procedure, all from `mcl_om_guard:stats/1` / the `denials_observed` payload:

| Feature | Source | Normalised by |
|---|---|---|
| `denied_rate`, `denied_size` | window counters | window attempts / `global_max` |
| `callers_over_limit`, `distinct_callers` | window counters | distinct/attempts budgets |
| `global_count` | window counter | `global_max` |
| offender shape: `n_offenders`, max/mean offender count | `top_callers` | `per_caller_max` |
| limits in effect: `max_payload_external_size`, `window_ms`, `per_caller_max`, `global_max`, `max_distinct_callers` | `mcl_om_guard_limits:get/1` | log / envelope max |
| envelope bounds per key | `mcl_om_guard_limits:get/1` | defaults |
| time since last move, last direction, applies in last M windows | audit ring | fixed windows |
| the last K windows of the above (or LTC state) | history buffer | as above |

The feature contract is versioned (`feature_version`): a genome is never run against a
different input shape. Framework defaults for context: 64 KiB / 10 s / 600 / 6000 / 1024.

## 4. What the policy does (actions)

First cut: **three posture scalars** in `[0, 1]`, mapped across each key's envelope:

```
rate_tightness       -> per_caller_max, global_max   (global stays >= per_caller)
size_tightness       -> max_payload_external_size
diversity_tightness  -> max_distinct_callers
```

- **Deadband**: a move applies only when the mapped value differs from the effective one
  by at least one quantile step (start 10% of the envelope range) — hysteresis, on top of
  the service-side anti-thrash.
- **`window_ms` is human-only** at first: changing it renumbers the counters' windows and
  changes the observation cadence, which invalidates the history features mid-episode.
- Alternatives recorded, not chosen: absolute per-key values (more outputs, same
  expressiveness in practice); deltas (harder to bound); a single global tightness
  (cannot separate size floods from rate floods).

## 5. The environment

Evaluation lives in mcl-sec-guard; nothing here ships to services.

**Rung 0 — synthetic world (`mcl_guard_sim`).** A pure, fast, seedable simulation of the
window arithmetic, reusing the *semantics* of `mcl_om_guard`'s counters and
`mcl_om_guard_limits`' validation/envelope. A conformance test replays identical synthetic
traffic through the real `mcl_om_guard` (short windows, one real pool) and the sim and
asserts identical allow/deny/counters — the faber convention: a pure reference held to the
real path by test. Episodes are independent and run concurrently (faber_neuroevolution's
parallel evaluation), so evolution gets its thousands of evaluations without a mesh.

| Scenario | Population | What it teaches (and punishes) |
|---|---|---|
| `calm` | legit only | no-op; churn is punished |
| `legit_spike` | legit burst | the false-positive trap: over-blocking starves |
| `uniform_flood` | 1 attacker, steady | rate posture |
| `bursty_flood` | 1 attacker, on/off | recovery and spring-back |
| `size_ladder` | escalating payloads | size posture |
| `sybil` | many ids, few calls each | diversity bound |
| `coordinated` | sybil + rate + size | mixed posture |
| `probe_then_quiet` | one probe, then nothing | no ratchet on noise (the recorded session's shape) |

**Rung 1 — recorded replay.** The 2026-10-04/05 probe session (449 proposals: size ladder
4 KiB → 1 MiB, rate bursts, quiet windows) calibrates realism: model that traffic, run the
sim, and compare the fact stream it would have published with what the log actually holds.
A mismatch is a sim bug, not a licence to tune. Aggregates only; not a fitness source.

**Rung 2 — live shadow.** The champion genome runs on beam00 against real
`denials_observed`: it computes moves, records them with `source => genome`, and applies
nothing. Its trajectory is compared with the incumbent rule's on the same live windows.
Bounded, announced campaigns supply pressure (see *Measurement, labels, and campaigns*).

**Rung 3 — canary apply.** Central apply within envelope on mcl-echo, bounded window,
auto-revert (stop applying; the last limits persist), then widen service by service. The
reflex waits until this is boring (see the architecture plan's phasing).

### Measurement, labels, and campaigns

The optimizer must not measure its own success. Containment and admission are ground truth
only in the simulator; live, the guard's own counters cannot tell a defended attack from a
self-inflicted starvation. Live fitness evidence therefore comes from outside the actuated
domain, in three separable artifacts:

| Artifact | Ground truth | Shape |
|---|---|---|
| **Canary / witness** | known-benign calls: attempted vs admitted | a small client with a pinned identity, or a fovea-style observer probing on a schedule and signing what it saw; harmless service-shaped |
| **Campaign harness** | which traffic was hostile, and how much reached the handler | scripts plus a signed manifest, run from a box under human scheduling — not an always-on mesh service |
| **Labels** | which windows belong to which scenario | the signed manifest itself; the guard consumes it and marks affected windows as campaign, so evaluation data never masquerades as organic pressure |

Operational rules, drawn from the fovea interference hazard:

- **Witnesses are provisioned, not guessed.** A canary's and fovea's node ids get
  per-caller budgets that survive tightening, and a probe refused by design (the KX
  challenge closed before CONNECT) is not counted as a denial — otherwise the defense
  starves its own witness and the guardian reads the witness's failures as pressure.
- **A campaign is announced before it runs, signed, and bounded**: allowlisted targets,
  envelope-bounded intensity and duration, a kill switch, signed results. Campaign windows
  are excluded from organic fitness and used as labelled evaluation only.
- **No attacker service on the shared mesh.** An always-on flooder is a weapon with a
  release pipeline, contaminates the telemetry it exists to measure, and points at shared
  stations carrying real traffic. If the role ever needs a service shape, it is a
  lab-realm, tier-gated coordinator whose name does not read as "we ship an attacker" —
  and the traffic-generating half stays a client.

**Coevolution is the strong version.** The fixed scenario table above comes first; once the
harness is trustworthy, attacker policies can be evolved against the defender inside
`mcl_guard_sim` (faber's P7 shape) — adaptive attacks, free and labelled, no live risk.
Live campaigns then measure transfer, not discovery.

## 6. The learner

- **Dependency**: `faber_tweann` in mcl-sec-guard only — never mcl-om.
- **Baseline first**: `sep_cma_es` on the distilled fixed shape (a small feedforward over
  the observation vector; LTC taus as an option to test, not assume). P1's result stands:
  a capability pays only when the task needs it, and topology evolution was a large cost
  where it was not needed.
- **Then the TWEANN experiment**: topology evolution against the same fitness and budget —
  does it beat the fixed shape? That is a signed result (faber insight style), not an
  assumption.
- **Distillation for deployment**: the champion phenotype is exported to the fixed genome
  format mcl-om's minimal evaluator runs (architecture plan, *The reflex seam*). The guard
  may search any phenotype; the substrate ships only what it can run dependency-free.
- **Scale**: parallel episodes locally first; P5-style mesh-distributed evaluation only
  when local compute binds.

## 7. Safety, ownership, operations

- The **envelope** remains the hard server-side clamp; out-of-envelope moves are refused
  and counted. No envelope, no movement — and therefore no reflex either.
- **Kill switches**: `{mcl_sec_guard, auto_apply, false}` stops shipping/applying;
  guardian absent ⇒ last limits hold (`persistent_term`); reflex absent ⇒ no-op.
- **Audit**: every recorded move names the genome id and `fitness_version`; the console
  shows the timeline (window, move, writer, reward) — the audit window the architecture
  plan demoted approve/reject to.
- **Humans own**: the envelope per service, the fitness vector (weights, scenarios,
  thresholds), and the promotion gates below. Nothing else — there is no per-proposal
  approval in the loop.

## 8. Promotion gates

Numeric thresholds are config, versioned with the fitness; start generous, tighten with
evidence. The report is always the full vector, never the scalar.

| Promotion | Gate |
|---|---|
| offline → shadow | on held-out scenario seeds (N ≥ 200 episodes): zero hard-gate failures; containment and admission at least the incumbent's; strictly better churn or better recovery |
| shadow → canary | shadow trajectory reproduces the offline ranking on live windows; zero would-be envelope violations; no starvation window; the **canary** confirms admission on live traffic |
| canary → wider | one announced, bounded **campaign**: containment from the campaign's labels, admission from the canary, service `/health` green throughout, limits returned to baseline after, rollback exercised at least once |

## 9. The first build

1. `mcl_guard_sim` + the scenario suite + the conformance test against the real guard.
2. Score the incumbent placeholder rule in it — the baseline every genome must beat.
3. The pure fitness module + versioned config + tests.
4. The `sep_cma_es` arm on the distilled shape; first champion numbers, reported as a
   vector.

Small commits; each step's numbers go into the session record, not into prose.

## 10. Open questions

1. `window_ms` in the action space later, or permanently human-only?
2. One policy for all procedures, or per procedure class (size-heavy vs rate-heavy)?
3. Canary/witness details: cadence, per-caller budget, and who runs it — fovea's observer
   role, or a dedicated canary identity? And is a bounded raw trace (sizes/rates, public
   caller ids) worth recording for rung 2, or do the canary and campaign labels suffice?
4. Vector review cadence: adversarial pass per version bump, or on a schedule?
5. Genome distribution and rollback exactly (signed fact vs gated RPC; who countersigns).

## References

- [PLAN_GUARDIAN_ARCHITECTURE.md](PLAN_GUARDIAN_ARCHITECTURE.md) — the split this plan
  serves; *Where the SecOps brain lives*
- [PLAN_GUARDIAN_CONTROL_SURFACE.md](PLAN_GUARDIAN_CONTROL_SURFACE.md) — the fact and
  `set_limits` contracts
- `faber-ecosystem/plans/SYNTHESIS_P3.md` — the engine this consumes
- `faber-ecosystem/plans/CHARTER_P1_CAPABILITIES.md` — capability value = task-match ×
  budget × optimizer (why the fixed shape is the baseline, not the fallback)
- `macula-architecture/presentations/series-5-autonomous-systems/` — the loop this is an
  instance of
