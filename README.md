# mcl-sec-guard
An intelligent security guard service

Plans live in GitHub issues labelled `plan`: the guardian architecture
(#19), the autonomous guardian's fitness, environment and learner (#20),
and the trainer console (#21). The control surface it actuates
(`get_limits` / `set_limits`, the `denials_observed` facts) is built in
mcl-om and documented there, in
[`docs/design/GUARDIAN_CONTROL_SURFACE.md`](https://github.com/macula-services/mcl-om/blob/main/docs/design/GUARDIAN_CONTROL_SURFACE.md).

## P0 shadow (current)

The service observes, proposes and records — it applies nothing. No guardian
tier, no `set_limits` anywhere in its namespace; the worst a compromised P0
guardian can do is write a bad proposal into its own log.

- **Sense:** subscribes to `denials_observed` (the alert facts guarded
  services publish once per window with activity, mcl-om#13).
- **Propose:** the placeholder rule behind `mcl_sec_guard_proposer`
  (configurable via `{mcl_sec_guard, proposer}`); the TWEANN-backed proposer
  (`faber_tweann`, evolved in `apps/mcl_sec_trainer`) replaces it once the
  loop is proven.
- **Record:** one `~0p` line per proposal in the append-only log
  (`{mcl_sec_guard, proposal_log}`).

## The trainer (`apps/mcl_sec_trainer`)

A second OTP application, not a service: the pure simulator world, the
eight-scenario suite, the episode runner and the versioned fitness vector —
held to the real mcl_om guard by a conformance test. Off by default, out of
the release until in-service training is wanted. The incumbent placeholder
rule is scored as the baseline every genome must beat.

## The console

The LAN admin UI (`MCL_SEC_GUARD_ADMIN_PORT`, default 8458, every
interface, no auth — the dev-fleet posture), an audit window in both
directions: it observes and decides nothing.

- `/` — the proposal log
- `/proposals.ndjson` — the log raw
- `/trainer` — the scoreboard: run-set artifacts (`{mcl_sec_guard,
  trainer_runs}`, default `trainer_runs/`) rendered as one row per
  scenario, plus the candidate-vs-incumbent diff and the fitness vector
- `/trainer.ndjson` — the raw feed, one JSON line per episode
- `/trainer/episode?scenario=...` — one episode's drill-down

Run sets are written by `mcl_sec_trainer_reporter` (see #21).

## Building

The OTP is pinned in `.tool-versions` (installed with asdf in this house);
commands run from the repo directory use the pinned VM via the asdf shims:

    rebar3 compile
    rebar3 eunit
    rebar3 lint
