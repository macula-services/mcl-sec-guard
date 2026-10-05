# The trainer console: a LAN scoreboard for the guardian's practice gym

**Kind:** BUILD (a read-only web surface for the operator, then a small
run-trigger control, phased against the rungs). **Status:** draft,
2026-10-06. Follows *The autonomous guardian*
([PLAN_AUTONOMOUS_GUARDIAN.md](PLAN_AUTONOMOUS_GUARDIAN.md)) and the
bookclub's LAN-admin-UI doctrine
(`mcl-bookclub/guides/admin_ui.md`, the corpus's only named precedent).
**Open question for Raf:** whether Phase B's "Run evals" button is wanted
before the learner lands — it is the one step that changes the current
"the trainer stays out of the image" decision.

## Why this exists

The trainer scored its first numbers this session, and the score lives in
a commit message — fine for a session record, useless for an operator.
The guardian's whole future is "a genome must beat the baseline, with zero
hard-gate failures, on held-out seeds" (the plan's promotion gates), and
someone on the LAN must be able to *see* that standing without reading
Erlang maps. The console already renders the proposal log; the scoreboard
is the same promise for the practice gym: look, don't guess.

A note on scope, said plainly: the read-only scoreboard (Phase A) is a
modest addition — the existing console is ~60 lines, and this is the same
shape again. The control surface (Phase B) and the live-learner view
(Phase C) are not modest; they are the real project, and each phase below
names its cost and its decision point.

## The doctrine (the corpus's one rule for this)

From `mcl-bookclub/guides/admin_ui.md`:

- The console is a **task-based UI on the box's LAN, served by the
  service itself** on `MCL_ADMIN_PORT`-style config, **not mesh-facing,
  no auth layer of its own** — an operator tool, and the fleet places it
  accordingly. mcl-sec-guard's console (8458) already carries exactly
  this posture; nothing here changes it.
- **The UI can never do what the domain refuses.** The facade owns the
  wire (cowboy routes, codec, rendering); a thin api module turns UI
  params into a call of the same pure functions the tests use; the
  domain's own rules are the last word.
- **The divisions stay pure.** The trainer's modules never import
  cowboy or a JSON codec; the service app's console module is the only
  thing that knows about HTTP.

And from `faber-programmes` (the faber runner discipline, which is
exactly the shape this UI consumes): **a signed insight is always backed
by a raw feed of numbers; the runner that produced the feed is kept.**
The trainer's run reports are that feed. The console must render them,
never replace or re-derive them.

## What exists today

- `mcl_sec_guard_admin` + `mcl_sec_guard_admin_handler`: one ranch
  listener (8458, every interface, no auth), routes `/` (the proposal
  log as an auto-refreshing page) and `/proposals.ndjson` (raw). The
  handler reads the recorder's log file per request — no state, no
  processes beyond the listener.
- `apps/mcl_sec_trainer`: pure, process-free, dep-free
  (kernel+stdlib), **absent from the release**. Runs produce report
  maps in memory and print them; nothing is written anywhere.

## The shape: a scoreboard over run artifacts

Phase A does not put the trainer in the image and does not start any
process. It only says: *a run that happened somewhere becomes a file,
and the console renders files.* Exactly how the console already reads
`proposals.log`.

**The artifact.** A new pure module in the trainer,
`mcl_sec_trainer_reporter`:

- `write_runset(Dir, [Report])` — one run set (a baseline, or one
  candidate's episodes) written as an Erlang-term file
  (`file:consult/1`-readable), newest first, capped (keep N run sets),
  one directory per the app env `{mcl_sec_guard, trainer_runs}` default
  `trainer_runs/`. Terms, not JSON: the reporter must stay dependency-free,
  and the wire codec is irrelevant — this file never leaves the box.
- Every report already records what the scoreboard needs: scenario,
  seed, windows, policy name, measurements, the full vector, per-gate
  verdicts, `fitness_version`, `final_limits`. The reporter adds the
  run's provenance: commit sha (from the build), wall-clock time, and
  the fitness config it was scored under.
- The runner is a one-liner from the shell (the session-5 kick-off
  command grows `reporter:write_runset` at the end). Nothing runs by
  itself.

**The pages** (all in the existing handler, same read-per-request style):

| Route | What it shows |
|---|---|
| `/` | unchanged: the proposal log (the audit window) |
| `/trainer` | **the scoreboard**: one row per scenario, columns fitness, C, A, R, S, applies, churn, gate verdicts; a second table diffing the latest candidate against the incumbent baseline per scenario; the promotion-gate summary (zero gate failures? at least the incumbent's C and A? strictly better churn or recovery?); the fitness version + weights/budgets/thresholds it was scored under; the conformance marker (which commit's sim, and the CI run that proved it identical to the real guard) |
| `/trainer.ndjson` | the same raw feed, one JSON line per episode (encoded by the service app; jsx already rides the root's dep tree) |
| `/trainer/episode?scenario=...` | one episode's drill-down: measurements, vector, gates, final limits vs envelope |

**The control question, split honestly.** What the operator may *do*
from the browser, and what stays a deliberate act:

- **Phase A (this plan): nothing.** Observe only. Runs are triggered
  from the shell; changing the fitness vector stays a code change — it
  is a versioned human CLAIM, not a slider.
- **Phase B (decision point): a "Run evals" button.**
  `POST /api/trainer/run` → the facade → `mcl_sec_trainer_baseline:run/0`
  (or an episode on chosen seeds) → reporter → redirect to `/trainer`.
  Episodes are milliseconds; no job queue, no background state. The
  COST is real and is the whole point of the decision: the trainer's
  net-free modules must enter the release (relx list gains
  `mcl_sec_trainer`; `enabled` stays false; faber still does not ship).
  This reverses the current "stays out of the image" decision, which is
  why it is flagged for Raf rather than assumed. Alternative if refused:
  Phase A plus a documented one-liner is a complete observation story.
- **Never in the UI, at any phase:** the envelope (deploy config), the
  fitness vector (versioned claim), applying limits (guardian/reflex
  only). The console stays an audit window; the plans already demoted
  approve/reject out of existence, and nothing here reintroduces it.
- **Phase C (after step 4, the learner):** candidate runs appear as
  artifacts from the `sep_cma_es` arm; the scoreboard's diff table is
  the promotion view. If evolution runs grow long, they need a task
  manager (a process holding a run, progress in a file) — a new shape,
  deliberately not designed now.
- **Phase D (rung 2, shadow reflex):** the architecture plan's own row
  — the console renders the audit timeline (input window, reflex/brain
  move, reward) from the audit ring. Separate plan; listed here so the
  console's route map is one picture.

**Posture.** Unchanged from today: LAN, every interface, no auth — the
dev-fleet posture the bookclub and tube UIs already carry, and the
proposal page already exposes far more sensitive data than a scoreboard
does. A run button is the same class of act as bookclub's task UI.

**Stale text cleanup rides along:** the console handler's doc says "P1
adds approve/reject" — that decision is dead (the console is an audit
window), and the README carries the same stale line (handover items 3–4).

## Phasing

| Phase | Rung | Delivers | New processes | Trainer in release? | Cost |
|---|---|---|---|---|---|
| A — scoreboard | 0 | reporter, `/trainer`, `/trainer.ndjson`, episode drill-down | none | no | modest |
| B — run button | 0/1 | `POST /api/trainer/run`; recorded-replay comparison view | none (sync) | **yes, net-free only** (Raf's call) | small, one decision |
| C — learner view | 0/1 | champion-vs-baseline diff, promotion gates, run progress | task manager for long runs | yes | real work |
| D — audit timeline | 2 | reflex/brain move timeline | none | yes | separate plan |

## Open questions

1. **Phase B now or later?** The only question that changes a standing
   decision. Recommend: ship Phase A; take B when the learner exists and
   there is a candidate worth re-running on demand.
2. Artifact location on beam00: a data-dir volume (`trainer_runs/` under
   the deploy's data dir) or next to `proposals.log`? Needs the same
   volume treatment proposals.log gets — check `edge/scripts` compose
   before shipping.
3. Terms vs JSON as the on-disk truth. Terms keep the reporter
   dependency-free; JSON is only for the wire-shaped `/trainer.ndjson`.
   Keeping both (terms on disk, JSON encoded at the edge) is the plan's
   position unless someone objects.
4. Page refresh: poll like the proposal page (5 s) — no SSE, matching
   the console's minimalism. Revisit if Phase C wants live progress.

## References

- `mcl-bookclub/guides/admin_ui.md` — the LAN admin UI doctrine
- `faber-programmes/README.md` — the runner/raw-feed discipline
- [PLAN_AUTONOMOUS_GUARDIAN.md](PLAN_AUTONOMOUS_GUARDIAN.md) — rungs,
  promotion gates, the fitness vector
- [PLAN_GUARDIAN_ARCHITECTURE.md](PLAN_GUARDIAN_ARCHITECTURE.md) — the
  console's audit-timeline row (Phase D)
