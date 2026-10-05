# The AI-augmented security guardian (mcl-sec-guard)

This exists so that inbound limits across the mesh retune themselves within minutes — inside
bounds a human set, with every change on the record.

**Kind:** BUILD. **Status:** P0 scaffolded (2026-10-04): the service exists — it subscribes to
the alert topic, runs the placeholder rule behind the proposer seam, and records proposals to
an append-only log. It applies nothing and holds no tier. **Decision (Raf, 2026-10-04):** the
guardian
is a new mcl-* service; its plans live here; inbound limits across the stack are hot-mutable
for it (mcl-echo#11, mcl-om#13, macula-station#40/#41); the first sensing surface ships with
mcl-echo#11 (`mcl_echo_limiter:stats/0`). **The guardian is deliberately independent of
mcl-warden and mcl-sentinel**: those two are the host-threat commons subsystem; the guardian is
a control-plane service with its own inputs and outputs, and nothing in its design consumes
warden facts or sentinel campaigns.

**Added (Raf, 2026-10-05):** the deciding step becomes a TWEANN (`faber_tweann`), and it
splits — evolution stays central in this service, execution grows a local tighten-only
reflex seam in mcl-om. The console's approve/reject is demoted to an audit window, not a
gate: the human owns the envelope, not each proposal. See *Where the SecOps brain lives*,
below.

## What it is

A control-plane service that (1) READS each service's limit telemetry — `get_limits`: limits
in effect, window fill, callers over their budget, top callers, denial counters; (2) PROPOSES
limit changes inside a human-set envelope; (3) APPLIES them through `set_limits`, logging every
applied change. It is AI-augmented: a model proposes; the envelope, the audit trail and the
the envelope, the audit trail and the admin UI keep it bounded.

## Sensing (inputs)

**Alert facts, pushed to the mesh.** Every service on the mcl-om#13 pipeline (and mcl-echo
with #11 until then) publishes an aggregated fact per window per procedure when it saw
denials or over-limit callers — see PLAN_GUARDIAN_CONTROL_SURFACE.md for the exact contract
(`_mesh.guard.`, fact type `denials_observed`). The guardian subscribes to that topic and
acts — or not — on what arrives. `get_limits` remains the on-demand truth (bootstrap, and
verification after an apply), not the driving signal.

- Station counters later, once #40/#41 land: call bounds, verify-charge throttles/closes,
  payload-cap and rate-limit counters.
- (Open) any further signal sources are out of scope until the control loop is proven. It is
  explicitly NOT fed from the warden/sentinel threat commons.

## Deciding (the AI part)

- A human sets the **policy envelope** per service and parameter (min/max), plus a playbook
  ("a caller over its limit for N minutes ⇒ lower `per_caller_max` to X, never below Y").
- The model only ever PROPOSES changes within the envelope; the service applies them. An
  out-of-envelope proposal is a human-approval item — the same shape as the "ask" contact
  policy — never an autonomous apply.
- Everything the model produces is data, never instruction: proposals go through the same
  validation and apply path an operator's change does.

## Acting (actuators)

- `<org>/set_limits` on every service shipping the mcl-om#13 pipeline (guard + stats + gated
  control surface). mcl-echo is the first actuator: local API now (mcl-echo#11), the gated
  mesh capability with mcl-om#13.
- Station limits (payload cap, per-NodeId call rate) once #40/#41 land — same pair, same
  contract (see PLAN_GUARDIAN_CONTROL_SURFACE.md).

## Where the SecOps brain lives: central evolution, local reflex (added 2026-10-05)

The split exists so the mesh tightens its own defenses at the speed of the traffic, inside
bounds a human set, and without a human in the loop. The deciding step splits in two:
**evolution stays central in this service; execution grows a local reflex in mcl_om.** The
model is a TWEANN (`faber_tweann` on hex), replacing the placeholder rule.

Rejected alternatives, for the record. **The full brain inside mcl-om** — every service
evolving locally — puts a changing, experimental control system in the estate's
most-depended-on library, forfeits the cross-service view that is the security value, and
makes every policy change a library release; one bad mutation touches everyone at once.
**Evaluator-only in mcl-om** (evolution distributed, P5-shaped) is a scale answer to a
problem not yet large, and it belongs to the search programme, not the guardian. mcl-om
gains the reflex *runtime*; this service keeps the *learner* and the *audit*.

### The reflex seam (mcl-om)

- **`mcl_om_guard_policy`** (working name) — a behaviour with one pure callback,
  `decide(Stats, Genome) -> [Move]`, `Move = #{procedure := P, limits := Overrides}`; the
  default is `[]`, so an unconfigured service behaves exactly as today.
- Evaluated on the **same tick that publishes `denials_observed`**
  (`mcl_om_guard:report_window_denials/1`), per declared procedure, against the same `Stats`
  map the fact carries. No new sensor, no new cadence.
- Moves apply through the **same `set_limits` path an operator uses**: envelope-checked,
  validated, anti-thrashed, audited with `tier => reflex`. A local move needs no realm tier:
  a service tuning its own limits is not a new privilege — a popped service can ignore its
  limits entirely; the envelope is the human clamp.
- **The genome is data.** App env `{mcl_om, guard_policy, #{module, genome}}` first; later a
  signed `guard_policy_updated` fact accepted only from the configured guardian node id, the
  last genome surviving mesh loss. The substrate gains a **minimal evaluator for a distilled,
  fixed-shape policy** (weights/taus), never the faber engine: faber may search topologies
  freely in the guardian, but the reflex it ships is distilled to a shape mcl-om can run in a
  few hundred dependency-free lines. Local topology evolution is earned only if a fixed shape
  cannot express the champion.
- **The asymmetry.** A reflex may tighten, or return a limit to the human baseline; it may
  not go looser than the baseline. Only the central brain (aggregate view, one tier, one
  audit) may hold a posture below baseline, and it can disable a service's reflex. A wrong
  or popped reflex can only lean the safe way.

### The brain (this service)

- Evolves genomes with `faber_tweann` against recorded/simulated episodes and the aggregate
  `denials_observed` stream; ships the distilled champion to services and observes outcomes.
- The reward vector and the evaluation environment are the keystone work — a guardian is only
  as good as its definition of "better" — and get their own plan
  (`PLAN_AUTONOMOUS_GUARDIAN.md`, to be written next).
- One audit view: the console renders the timeline (input window, reflex/brain move, reward),
  not an approval queue.

### Two writers, one procedure (open)

The reflex and the guardian can both write one procedure's limits, and anti-thrash is per
(caller, service), which does not separate them. Settle before enabling both: a central
apply wins for a cooldown the service can read; a reflex yields to any central apply within
N windows; the audit tier names the writer and the console shows both.

### Phasing (refines the phases above)

| Phase | What | Where |
|---|---|---|
| 0 | shadow: facts → placeholder proposals, apply nothing (today) | guard |
| 1 | policy seam + offline evolution harness over recorded episodes | mcl-om seam, guard brain |
| 2 | shadow reflex: genome evaluated, moves recorded, not applied; compared against the rule | mcl-om + guard |
| 3 | central apply within envelope; the `guardian` tier minted | guard → services |
| 4 | reflex enabled (tighten-only, opted-in services); genome distribution | mcl-om |
| 5 | station actuators (#42/#43) | station |

## Guardrails (non-negotiable)

- **Envelope, enforced server-side.** The guardian tier may only set within configured
  min/max per parameter; the envelope itself is human-only. A compromised guardian cannot
  weaken a defense beyond the human's bound.
- **Audit.** Every applied change is logged (caller, service, before, after, envelope). The
  register's `Security audit log` row is `todo` today; a guardian makes it a prerequisite.
- **Anti-thrash.** Idempotent sets (unchanged = no-op, no audit entry), a minimum interval
  between applies per (caller, service), and convergence (an oscillating proposal is dropped).
- **Prompt-injection resistance.** The guardian's own calls are UCAN-bound
  (macula-mcp PLAN_AGENT_IDENTITY_UCAN.md); its realm scope names only the actions it needs
  (`mcl_om_service:identity_spec/0`); nothing it reads from the mesh is treated as
  instruction; it cannot edit its own envelope.
- **Fail-safe.** Guardian absent ⇒ defaults hold. Guardian crash ⇒ services keep the last
  applied limits (`persistent_term` survives, and mcl-echo#11's boot load merges env over the
  effective values, so a service restart does not undo the guardian's last change).

## Deployment shape

- An mcl-om service like its siblings: realm identity, provider-authorization row, health
  endpoint, org `mcl-sec-guard`.
- **Store: yes** — the audit trail of applied changes is event-sourced in its own store
  (mcl-om#10 means the wiring is explicit). Decide store vs append-only file in step 1.
- One guardian per realm to start: the actuator role is an ownership problem, not a scale
  problem.

## Phases

- **P0 — shadow.** Observe (`get_limits` stats), compute proposals, log them, apply nothing.
  Needs: sensing surfaces only.
- **P1 — tune within envelope.** Auto-apply for services on the mcl-om#13 pipeline. Needs:
  pipeline + gated `set_limits` + audit.
- **P2 — station actuators.** Retune relay-level limits (#40/#41).

## Open questions

1. Store from day one, or an append-only audit file until P1?
2. **Envelope policy — DECIDED (Raf, 2026-10-04):** hard server-side clamps. The guardian tier may
   only set within the per-parameter envelope; humans change limits and the envelope through
   deploy config and the service's admin UI — there is no operator mesh capability, and every
   human change is audited.
3. **Tier naming — DECIDED (Raf, 2026-10-04):** one realm-wide actuator tier `guardian`
   (plain lowercase, wire-safe), held by exactly one guardian identity. No operator tier:
   humans use deploy config and the service's admin UI.
4. **One guardian per realm — DECIDED (Raf, 2026-10-04):** one writer per realm (the
   single-writer problem); partition by service set later if the role grows, with per-service
   tiers as the natural key.
5. Playbook format: declarative rules with LLM proposals on top, or LLM-only inside rule
   guardrails?
6. `get_limits` is public facts — keep it `open`, gate only `set_limits`?
7. Signal sources beyond limit telemetry and station counters — deliberately deferred until
   the control loop is proven, and deliberately NOT warden/sentinel.
