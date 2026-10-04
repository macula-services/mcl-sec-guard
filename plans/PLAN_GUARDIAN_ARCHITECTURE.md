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
