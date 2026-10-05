%%% @doc The fitness vector (PLAN_AUTONOMOUS_GUARDIAN.md, §2).
%%%
%%% "Better" is machine-optimisable, and the definition is a CLAIM owned
%%% and versioned by a human. One episode (one procedure, one scenario,
%%% T windows) measures four concerns, each normalised to [0, 1]:
%%%
%%%     C (containment) = 1 - attacker_calls_admitted / attacker_calls_attempted
%%%     A (admission)   = legit_calls_admitted / legit_calls_attempted
%%%     R (recovery)    = 1 - min(1, quiet_windows / recovery_budget)
%%%     S (stability)   = 1 - min(1, (applies + churn) / churn_budget)
%%%
%%%     fitness = wc*C + wa*A + wr*R + ws*S
%%%
%%% Hard gates, not weights — any one fails and the genome is rejected,
%%% with the failing gate named in the report: envelope (an out-of-
%%% envelope or invalid move was attempted), starvation (legit callers
%%% shut out entirely while they kept calling), runaway (a limit pinned
%%% at its envelope floor long after the pressure ended), and health
%%% (not measurable at rung 0: the sim has no handler-level health, so
%%% this gate reads ok and the rung that can measure it is the canary).
%%%
%%% Weights, budgets and thresholds live in versioned config —
%%% `{mcl_sec_guard, fitness, #{version, weights, budgets, thresholds}}'
%%% — and every report records the version it was scored under. Changing
%%% the vector is a new version; genomes are not comparable across
%%% versions without re-evaluation.
-module(mcl_sec_trainer_fitness).

-export([config/0, defaults/0, version/1, score/2]).

-type measurements() :: map().
-type config() :: map().

%% @doc The active vector config: the app env's `{mcl_sec_guard,
%% fitness, ...}', or the defaults (version 1) when none is set.
-spec config() -> config().
config() ->
    application:get_env(mcl_sec_guard, fitness, defaults()).

%% @doc Version 1: equal weights, generous budgets, generous thresholds.
%% Start generous, tighten with evidence (the plan's promotion gates).
-spec defaults() -> config().
defaults() ->
    #{version => 1,
      weights => #{containment => 0.25, admission => 0.25,
                   recovery => 0.25, stability => 0.25},
      budgets => #{recovery_windows => 10, churn => 10},
      thresholds => #{starvation_windows => 5, runaway_windows => 10}}.

-spec version(config()) -> pos_integer().
version(Config) ->
    maps:get(version, Config).

%% @doc Score one episode's measurements. Returns a report map with the
%% full vector and per-gate verdicts; `fitness' is the weighted scalar,
%% or `rejected' when any hard gate failed (the failing gate names
%% itself and its evidence).
-spec score(measurements(), config()) -> map().
score(Measurements, Config) ->
    Vector = vector(Measurements, Config),
    Gates = gates(Measurements, Config),
    Fitness = case [G || G <- maps:values(Gates), G =/= ok] of
                  [] ->
                      weighted(Vector, maps:get(weights, Config));
                  _FailedGates ->
                      rejected
              end,
    #{vector => Vector, gates => Gates, fitness => Fitness,
      fitness_version => version(Config)}.

vector(Measurements, Config) ->
    Budgets = maps:get(budgets, Config),
    #{containment => containment(Measurements),
      admission => admission(Measurements),
      recovery => recovery(Measurements, maps:get(recovery_windows, Budgets)),
      stability => stability(Measurements, maps:get(churn, Budgets))}.

containment(#{attacker_attempted := Attempted, attacker_admitted := Admitted})
  when Attempted > 0 ->
    1 - Admitted / Attempted;
containment(_Measurements) ->
    1.0.

admission(#{legit_attempted := Attempted, legit_admitted := Admitted})
  when Attempted > 0 ->
    Admitted / Attempted;
admission(_Measurements) ->
    1.0.

recovery(#{quiet_windows := Quiet}, Budget) ->
    1.0 - min(1.0, Quiet / Budget).

stability(#{applies := Applies, churn := Churn}, Budget) ->
    1.0 - min(1.0, (Applies + Churn) / Budget).

gates(Measurements, Config) ->
    Thresholds = maps:get(thresholds, Config),
    #{envelope => envelope_gate(Measurements),
      starvation => starvation_gate(Measurements,
                                    maps:get(starvation_windows, Thresholds)),
      health => ok,
      runaway => runaway_gate(Measurements,
                              maps:get(runaway_windows, Thresholds))}.

envelope_gate(#{envelope_violations := Violations}) when Violations > 0 ->
    {fail, #{envelope_violations => Violations}};
envelope_gate(_Measurements) ->
    ok.

starvation_gate(#{starvation_windows := Starved}, Threshold) when Starved > Threshold ->
    {fail, #{starvation_windows => Starved}};
starvation_gate(_Measurements, _Threshold) ->
    ok.

runaway_gate(#{runaway_windows := Pinned}, Threshold) when Pinned > Threshold ->
    {fail, #{runaway_windows => Pinned}};
runaway_gate(_Measurements, _Threshold) ->
    ok.

weighted(Vector, Weights) ->
    maps:fold(fun(Key, Weight, Acc) ->
                      Acc + Weight * maps:get(Key, Vector)
              end, 0.0, Weights).
