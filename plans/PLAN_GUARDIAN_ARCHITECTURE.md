# The AI-augmented security guardian (mcl-sec-guard)

This exists so that what the wardens see changes the fleet's defenses within minutes — inside
bounds a human set, with every change on the record.

**Kind:** BUILD. **Status:** design, no code yet. **Decision (Raf, 2026-10-04):** the guardian
is a new mcl-* service; its plans live here; inbound limits across the stack are hot-mutable
for it (mcl-echo#11, mcl-om#13, macula-station#40/#41); the first sensing surface ships with
mcl-echo#11 (`mcl_echo_limiter:stats/0`).

## Where it sits in the ecosystem

- **mcl-warden** SENSES — host-level intrusion attempts on a public box become
  `attacker_sighted` / `attacker_ensnared` facts.
- **mcl-sentinel** CORRELATES — warden sightings become campaigns, published enriched.
- **mcl-sec-guard** RESPONDS — this service: it reads the sightings and each service's limit
  telemetry, and retunes the inbound limits every mesh service exposes. Today nothing acts on
  a warden sighting beyond the warden's own decoys.

## Sensing (inputs)

1. Warden facts: `attacker_sighted`, `attacker_ensnared` — the publisher is macula-verified
   and nothing a payload says about its own sender is believed (sentinel's rule, kept).
2. Sentinel campaigns (second-warden correlations).
3. Per-service limit telemetry via `limits.get`: starting with `mcl_echo_limiter:stats/0`
   (mcl-echo#11) and the mcl-om#13 pipeline's per-stage denial counters.
4. Station counters: call bounds, verify-charge throttles/closes (existing), payload-cap and
   rate-limit counters once #40/#41 land.
5. Later: enrichment (ensnare durations, usernames tried, campaign geography).

## Deciding (the AI part)

- A human sets the **policy envelope** per service and parameter (min/max), plus a playbook
  ("a caller over its limit for N minutes ⇒ lower `per_caller_max` to X, never below Y").
- The model only ever PROPOSES changes within the envelope; the service applies them. An
  out-of-envelope proposal is a human-approval item — the same shape as the "ask" contact
  policy — never an autonomous apply.
- Everything the model produces is data, never instruction: proposals go through the same
  validation and apply path an operator's change does (`mcl_echo_limits:validate/1` today).

## Acting (actuators)

- `<org>/limits.set` on every service shipping the mcl-om#13 pipeline (guard + stats + gated
  control surface). mcl-echo is the first actuator: local API now (mcl-echo#11), the gated
  mesh capability with mcl-om#13.
- Station limits (payload cap, per-NodeId call rate) once #40/#41 land — same pair, same
  contract (see PLAN_GUARDIAN_CONTROL_SURFACE.md).
- Warden caps (`MCL_WARDEN_MAX_CONNS` and the ensnare thresholds), later.

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

- **P0 — shadow.** Observe (warden facts + stats), compute proposals, log them, apply nothing.
  Needs: sensing surfaces only.
- **P1 — tune within envelope.** Auto-apply for services on the mcl-om#13 pipeline. Needs:
  pipeline + gated `limits.set` + audit.
- **P2 — station actuators.** Retune relay-level limits (#40/#41).
- **P3 — campaign-driven.** Fold sentinel campaigns into proposals.

## Open questions

1. Store from day one, or an append-only audit file until P1?
2. **Envelope policy — DECIDED (Raf, 2026-10-04):** hard server-side clamps. The guardian tier may
   only set within the per-parameter envelope; a human tier may set beyond it, and every such
   change is audited.
3. **Tier naming — DECIDED (Raf, 2026-10-04):** one realm-wide actuator tier `guardian`
   (plain lowercase, wire-safe), held by exactly one guardian identity; a separate `operator`
   tier for out-of-envelope and envelope changes.
4. **One guardian per realm — DECIDED (Raf, 2026-10-04):** one writer per realm (the
   single-writer problem); partition by service set later if the role grows, with per-service
   tiers as the natural key. Sentinel/warden already provide redundant observation.
5. Playbook format: declarative rules with LLM proposals on top, or LLM-only inside rule
   guardrails?
6. `limits.get` is public facts — keep it `open`, gate only `limits.set`?
