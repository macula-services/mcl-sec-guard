# The guardian control surface: `limits.get` / `limits.set`

This exists so one guardian reads and retunes the inbound limits of every mesh service through
one gated, audited, self-describing interface — and so no service invents a second one.

**Kind:** BUILD. **Status:** design. The local half ships with mcl-echo#11
(`mcl_echo_limits:get/0,set/1`, `mcl_echo_limiter:set_limits/1,stats/0`); the mesh half rides on
the mcl-om#13 pipeline. **Decision (Raf, 2026-10-04):** one control surface, not three.

## The pair

Every service (pipeline or hand-rolled) exposes, in its org namespace:

- `<org>/limits.get` — limits in effect + current-window stats. Public facts (deliberately
  `open`): no secrets, no caller-specific data.
- `<org>/limits.set` — partial overrides. `auth => {realm_member_required, RealmDid, Tier}` at
  a guardian tier; a human tier exists for out-of-envelope and envelope changes.

## Wire shapes

- No booleans on the wire (mesh rule): numbers only; errors as atoms/binaries.
- `limits.set` request: the override map — the keys `mcl_echo_limits` validates today
  (`max_payload_external_size`, `window_ms`, `per_caller_max`, `global_max`); the mcl-om#13
  pipeline may extend the list per stage.
- `limits.set` reply: `{ok, effective}` or `{error, Reason}` with reasons
  `unknown_key`, `not_a_positive_integer`, `per_caller_above_global`, `envelope_exceeded`,
  `rate_limited`.
- `limits.get` reply: the `mcl_echo_limiter:stats/0` map (limits, current window, global
  count/max, distinct callers, callers over limit, top callers) plus per-stage denial
  counters once the pipeline lands.

## Semantics

- Partial merge over the effective values; validated before apply; a rejected set changes
  nothing; an unchanged set is a no-op (no audit entry, no counter clear).
- A `window_ms` change clears the counters — renumbered window keys are un-sweepable
  otherwise; mcl-echo#11's behavior, adopted as the contract.
- The apply path is identical for the guardian and for a human operator. The guardian is a
  caller, not a special case.

## Envelope

- Per parameter, per service, human-only: min/max clamps. A guardian-tier `limits.set` beyond
  the envelope fails with `envelope_exceeded`; a human-tier set applies and is audited.
- The envelope is part of the service's deploy config (startup); it changes at runtime through
  the human tier only.

## Audit

- Every APPLIED change: caller, service, before, after, envelope, timestamp. First consumer of
  the register's `Security audit log` row (`todo` today). Failed sets are counted, not logged
  as changes.

## Anti-thrash contract (callers)

- Minimum interval between applies per (caller, service): 10 s to start; identical set = no-op.
- These bounds are service-side: services must not rely on the guardian behaving.

## Where each piece lives

| Piece | Today | Tomorrow |
|---|---|---|
| Limits storage + validation | mcl-echo#11 (`mcl_echo_limits`, persistent_term) | mcl-om#13 pipeline, per-capability defaults |
| Stats | mcl-echo#11 (`mcl_echo_limiter:stats/0`) | per-stage denial counters in the pipeline |
| Gated `limits.set` | — | mcl-om#13 (`{realm_member_required, ...}`) |
| Envelope + audit | — | mcl-om#13; register row update rides with it |
| Station limits | #40/#41 counters | same pair names, same contract |

## References

- mcl-echo#11, mcl-om#13, macula-station#40/#41, macula-io/macula#60
- macula-architecture#3 and register rows: Edge admission limits, Inbound call bounds,
  Security audit log, DoS test campaign
- PLAN_GUARDIAN_ARCHITECTURE.md (this repo)
