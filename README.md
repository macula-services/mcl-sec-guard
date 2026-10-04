# mcl-sec-guard
An intelligent security guard service

Design and plans live in [`plans/`](plans/): the guardian architecture and the
control surface (`get_limits` / `set_limits`) it actuates.

## P0 shadow (current)

The service observes, proposes and records — it applies nothing. No guardian
tier, no `set_limits` anywhere in its namespace; the worst a compromised P0
guardian can do is write a bad proposal into its own log.

- **Sense:** subscribes to `denials_observed` (the alert facts guarded
  services publish once per window with activity, mcl-om#13).
- **Propose:** the placeholder rule behind `mcl_sec_guard_proposer`
  (configurable via `{mcl_sec_guard, proposer}`); the model-backed proposer
  replaces it once the loop is proven.
- **Record:** one `~0p` line per proposal in the append-only log
  (`{mcl_sec_guard, proposal_log}`).

## Building

The OTP is pinned in `.tool-versions` (installed with asdf in this house);
commands run from the repo directory use the pinned VM via the asdf shims:

    rebar3 compile
    rebar3 eunit
    rebar3 lint
