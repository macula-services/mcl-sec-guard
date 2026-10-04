# The guardian control surface: `get_limits` / `set_limits`

This exists so one guardian reads and retunes the inbound limits of every mesh service through
one gated, audited, self-describing interface — and so no service invents a second one.

**Kind:** BUILD. **Status:** shipped in mcl_om 0.37.1, house-rule names (verb-first
snake_case). **Decision (Raf, 2026-10-04):** one control surface; the guardian tier gates
`set_limits`; humans use deploy config and the service's own admin UI — there is no operator
mesh capability.

## The alert facts (services → guardian)

Sensing is push, not poll: a guarded service reports what it observed; the guardian
subscribes and decides. `get_limits` stays for bootstrap and post-apply verification.

- **Topic:** `denials_observed` — one well-known fact topic per realm (configurable per
  service via `{mcl_om, inbound_guard, #{alert_topic => ...}}`); the guardian subscribes to
  it.
- **Payload** (binaries and numbers only, no booleans):

  `#{procedure, window_start_ms, denied_rate, denied_size, callers_over_limit, global_count,
     global_max, per_caller_max}`

- **Cadence:** once per window per procedure, and only when that window saw a denial or an
  over-limit caller — an attacker cannot use a quiet service as a fact amplifier, and a
  flood of denials collapses into one fact per window. Window starts are wall-clock, so the
  guardian can correlate across services.

## The pair

Every service (pipeline or hand-rolled) exposes, in its org namespace:

- `<org>/get_limits` — limits in effect + current-window stats. Public facts (deliberately
  `open`): no secrets, no caller-specific data.
- `<org>/set_limits` — partial overrides. `auth => {realm_member_required, RealmDid,
  GuardianTier}`, advertised only when `inbound_guard.guardian` config names the realm DID
  and the tier.

## Wire shapes

- No booleans on the wire (mesh rule): numbers only; errors as atoms/binaries.
- `set_limits` request: the override map — the keys `mcl_om_guard_limits` validates
  (`max_payload_external_size`, `window_ms`, `per_caller_max`, `global_max`).
- `set_limits` reply: `{ok, effective}` or `{error, Reason}` with reasons
  `unknown_key`, `not_a_positive_integer`, `per_caller_above_global`, `envelope_exceeded`,
  `rate_limited`.
- `get_limits` reply: the `mcl_om_guard:stats/1` map (limits, envelope, current window,
  global fill, callers over limit, top callers, denial counters, audit ring) for one
  procedure, or every declared one.

## Semantics

- Partial merge over the effective values; validated before apply; a rejected set changes
  nothing; an unchanged set is a no-op (no audit entry, no counter clear).
- A `window_ms` change clears the counters — renumbered window keys are un-sweepable
  otherwise.
- The apply path is identical for the guardian and for a local operator call. The guardian
  is a caller, not a special case.

## Envelope

- Per parameter, per service, human-only: min/max clamps declared in the capability's
  `limits` (deploy config). A guardian-tier `set_limits` beyond the envelope fails with
  `envelope_exceeded`; the envelope itself is never settable over the mesh. Humans change it
  in deploy config or through the service's own admin surface.

## Audit

- Every APPLIED change: caller, tier, before, after, timestamp, on the guard's audit ring
  and in the log. Failed sets are counted, not logged as changes. The tamper-evident stream
  is still owed (register `Security audit log` row).

## Anti-thrash contract (callers)

- Minimum interval between applies per (caller, service): 10 s to start; identical set =
  no-op. These bounds are service-side: services must not rely on the guardian behaving.

## Where each piece lives

| Piece | Shipped | Note |
|---|---|---|
| Limits storage + validation | mcl-om 0.37.1 (`mcl_om_guard_limits`, persistent_term) | per-procedure, envelope in the capability's `limits` |
| Stats | mcl-om 0.37.1 (`mcl_om_guard:stats/1`) | window starts are wall-clock |
| Gated `set_limits` | mcl-om 0.37.1 | `{realm_member_required, RealmDid, GuardianTier}` |
| Alert facts | mcl-om 0.37.1 | `denials_observed` per window with activity |
| Station limits | station #40/#41 PRs | same pair names later |

## References

- mcl-om#13, mcl-echo#13 (adopted the pipeline), macula-station#40/#41, macula-io/macula#60
- macula-architecture#3 and register rows: Edge admission limits, Inbound call bounds,
  Security audit log, DoS test campaign
- PLAN_GUARDIAN_ARCHITECTURE.md (this repo)
