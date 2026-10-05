%%% @doc One episode: one procedure under one scenario for T windows,
%%% scored with the fitness vector.
%%%
%%% The loop mirrors the live sense → decide → act cadence: the policy
%%% sees the sim's stats for the window that just closed (the same
%%% shape a `denials_observed' fact carries), its move applies for the
%%% windows that follow, and the traffic of each window then runs
%%% against the moved posture. Window 0 gets no sense step — there is
%%% no prior window to report, exactly as a fresh service has nothing
%%% to alert on.
%%%
%%% Ground truth is free here and only here: every call is tagged
%%% `legit' or `attacker' by the scenario, so containment and admission
%%% are measured directly, not inferred from the guard's own counters.
-module(mcl_sec_trainer_episode).

-export([run/1, run/2]).

-export_type([policy/0, report/0]).

-type policy() :: fun((map()) -> none | map()).
-type report() :: map().

%% @doc The default-length episode (60 windows, seed 0) of one
%% scenario, driven by the given policy.
-spec run(atom()) -> report().
run(Scenario) ->
    run(Scenario, #{}).

%% Opts: `policy' (required — fun(Ctx) -> none | Overrides, where Ctx is
%% `#{proc, stats}'), `policy_name' (recorded in the report),
%% `windows', `seed', `procedure', `guardian_id' (the caller recorded
%% on audit entries), `limits' (the declare-able capability limits;
%% defaults to the scenario's own).
-spec run(atom(), map()) -> report().
run(Scenario, Opts) when is_map(Opts) ->
    Policy = maps:get(policy, Opts, undefined),
    case Policy of
        Fun when is_function(Fun, 1) -> ok;
        _Missing -> error({missing_policy, Scenario})
    end,
    T = maps:get(windows, Opts, 60),
    Seed = maps:get(seed, Opts, 0),
    Proc = maps:get(procedure, Opts, atom_to_binary(Scenario, utf8)),
    GuardianId = maps:get(guardian_id, Opts, <<"guardian">>),
    CapLimits = maps:get(limits, Opts, mcl_sec_trainer_scenarios:limits(Scenario)),
    World0 = mcl_sec_trainer_sim:declare(
               mcl_sec_trainer_sim:new(#{seed => Seed}), Proc, CapLimits),
    Baseline = maps:get(limits, mcl_sec_trainer_sim:get(World0, Proc)),
    Script = mcl_sec_trainer_scenarios:windows(Scenario, #{windows => T, seed => Seed}),
    Acc0 = #{window => -1, prev_stats => undefined,
             att_attempted => 0, att_admitted => 0,
             leg_attempted => 0, leg_admitted => 0,
             leg_win_attempted => 0, leg_win_admitted => 0,
             applies => 0, churn => 0.0, envelope_violations => 0,
             hot_windows => 0, last_hot => undefined,
             starved_run => 0, starved_max => 0,
             pinned_run => 0, pinned_max => 0},
    {World, Acc} = loop(World0, Proc, Script, Policy, GuardianId, Baseline, Acc0),
    report(Scenario, Proc, T, Seed, maps:get(policy_name, Opts, unknown),
           World, Acc).

loop(World, _Proc, [], _Policy, _GuardianId, _Baseline, Acc) ->
    {World, Acc};
loop(World, Proc, [Calls | Rest], Policy, GuardianId, Baseline, Acc) ->
    K = maps:get(window, Acc) + 1,
    {World1, Acc1} =
        decide(World, Proc, Policy, GuardianId, K, maps:get(prev_stats, Acc), Acc),
    {World2, Acc2} = traffic(World1, Proc, Calls, Acc1),
    Stats = mcl_sec_trainer_sim:stats(World2, Proc),
    Acc3 = window_end(World2, Proc, K, Baseline, Stats, Acc2),
    World3 = mcl_sec_trainer_sim:advance(World2, Proc),
    loop(World3, Proc, Rest, Policy, GuardianId, Baseline,
         Acc3#{window => K, prev_stats => Stats}).

%% Sense (the window that just closed), decide, apply. Window 0 has
%% nothing to sense; a guardian-tier move that the envelope refuses is
%% counted, not applied — the attempt itself disqualifies the episode.
decide(World, _Proc, _Policy, _GuardianId, _K, undefined, Acc) ->
    {World, Acc};
decide(World, Proc, Policy, GuardianId, _K, PrevStats, Acc) ->
    case Policy(#{proc => Proc, stats => PrevStats}) of
        none ->
            {World, Acc};
        Overrides when is_map(Overrides) ->
            apply_move(World, Proc, GuardianId, Overrides, Acc)
    end.

apply_move(World, Proc, GuardianId, Overrides, Acc) ->
    Before = mcl_sec_trainer_sim:get(World, Proc),
    case mcl_sec_trainer_sim:apply(World, Proc, Overrides,
                                   #{tier => guardian, caller => GuardianId}) of
        {ok, World1} ->
            Churn = maps:get(churn, Acc)
                + churn_of(Before, mcl_sec_trainer_sim:get(World1, Proc)),
            {World1, Acc#{applies := maps:get(applies, Acc) + 1, churn := Churn}};
        {error, _Reason} ->
            {World, Acc#{envelope_violations := maps:get(envelope_violations, Acc) + 1}}
    end.

traffic(World, Proc, Calls, Acc) ->
    lists:foldl(
      fun(#{caller := Caller, payload := Payload, role := Role}, {W, A}) ->
              {Verdict, W1} = mcl_sec_trainer_sim:call(W, Proc, Caller, Payload),
              {W1, tally(Role, Verdict, A)}
      end, {World, Acc}, Calls).

tally(attacker, allow, Acc) ->
    Acc#{att_attempted := maps:get(att_attempted, Acc) + 1,
         att_admitted := maps:get(att_admitted, Acc) + 1};
tally(attacker, {deny, _}, Acc) ->
    Acc#{att_attempted := maps:get(att_attempted, Acc) + 1};
tally(legit, allow, Acc) ->
    Acc#{leg_attempted := maps:get(leg_attempted, Acc) + 1,
         leg_admitted := maps:get(leg_admitted, Acc) + 1,
         leg_win_attempted := maps:get(leg_win_attempted, Acc) + 1,
         leg_win_admitted := maps:get(leg_win_admitted, Acc) + 1};
tally(legit, {deny, _}, Acc) ->
    Acc#{leg_attempted := maps:get(leg_attempted, Acc) + 1,
         leg_win_attempted := maps:get(leg_win_attempted, Acc) + 1}.

%% The window's aftermath: was it hot (any denial)? Was legit traffic
%% shut out entirely (starvation run)? Does the posture sit at an
%% envelope floor the baseline does not (runaway run, counted only
%% after all pressure ended)?
window_end(World, Proc, K, Baseline, Stats, Acc) ->
    Hot = maps:get(denied_rate, Stats) > 0 orelse maps:get(denied_size, Stats) > 0,
    Starved = maps:get(leg_win_attempted, Acc) > 0
        andalso maps:get(leg_win_admitted, Acc) =:= 0,
    Acc1 = runs(Starved, starved_run, starved_max, Acc),
    Acc2 = case Hot of
               true ->
                   Acc1#{hot_windows := maps:get(hot_windows, Acc1) + 1,
                         last_hot => K, pinned_run => 0};
               false ->
                   pinned_update(pinned(World, Proc, Baseline), Acc1)
           end,
    Acc2#{leg_win_attempted := 0, leg_win_admitted := 0}.

pinned_update(true, Acc) ->
    Run = maps:get(pinned_run, Acc) + 1,
    Acc#{pinned_run := Run, pinned_max := erlang:max(maps:get(pinned_max, Acc), Run)};
pinned_update(false, Acc) ->
    Acc#{pinned_run := 0}.

runs(true, RunKey, MaxKey, Acc) ->
    Run = maps:get(RunKey, Acc) + 1,
    Acc#{RunKey := Run, MaxKey := erlang:max(maps:get(MaxKey, Acc), Run)};
runs(false, RunKey, _MaxKey, Acc) ->
    Acc#{RunKey := 0}.

%% A key pinned at its envelope floor that the baseline (the human
%% declared limits) does not sit at: the policy tightened it there and
%% nothing has returned it. A baseline that legitimately sits at the
%% floor is not pinning.
pinned(World, Proc, Baseline) ->
    #{limits := Limits, envelope := Envelope} = mcl_sec_trainer_sim:get(World, Proc),
    lists:any(fun({Key, #{min := Min}}) ->
                      maps:get(Key, Limits) =:= Min
                          andalso maps:get(Key, Baseline) > Min
              end, maps:to_list(Envelope)).

%% The stability ingredient: total RELATIVE change across all applied
%% moves, each key's delta divided by its envelope range (or the
%% declared value when the envelope does not cover the key).
churn_of(#{limits := Before, envelope := Envelope}, #{limits := After}) ->
    lists:foldl(
      fun(Key, Sum) -> Sum + delta(Key, Before, After, Envelope) end,
      0.0, maps:keys(After)).

delta(Key, Before, After, Envelope) ->
    B = maps:get(Key, Before),
    case maps:get(Key, After) of
        B -> 0.0;
        A -> abs(A - B) / range(Key, B, Envelope)
    end.

range(Key, Declared, Envelope) ->
    case maps:get(Key, Envelope, undefined) of
        #{min := Min, max := Max} -> erlang:max(Max - Min, 1);
        undefined -> erlang:max(Declared, 1)
    end.

report(Scenario, Proc, T, Seed, PolicyName, World, Acc) ->
    Measurements = measurements(T, World, Proc, Acc),
    Score = mcl_sec_trainer_fitness:score(Measurements,
                                          mcl_sec_trainer_fitness:config()),
    maps:merge(#{scenario => Scenario, procedure => Proc, windows => T,
                 seed => Seed, policy => PolicyName,
                 measurements => Measurements},
               Score).

measurements(T, World, Proc, Acc) ->
    #{attacker_attempted => maps:get(att_attempted, Acc),
      attacker_admitted => maps:get(att_admitted, Acc),
      legit_attempted => maps:get(leg_attempted, Acc),
      legit_admitted => maps:get(leg_admitted, Acc),
      hot_windows => maps:get(hot_windows, Acc),
      quiet_windows => quiet_windows(T, maps:get(last_hot, Acc)),
      applies => maps:get(applies, Acc),
      churn => maps:get(churn, Acc),
      starvation_windows => maps:get(starved_max, Acc),
      runaway_windows => maps:get(pinned_max, Acc),
      envelope_violations => maps:get(envelope_violations, Acc),
      final_limits => maps:get(limits, mcl_sec_trainer_sim:get(World, Proc))}.

%% Windows from the last hot one until two consecutive quiet windows
%% (denied_rate and denied_size both zero). Never hot: already quiet.
%% Fewer than two windows remain after the pressure: recovery was never
%% observed — the whole episode counts, so R reads zero.
quiet_windows(_T, undefined) ->
    0;
quiet_windows(T, LastHot) ->
    case T - (LastHot + 1) >= 2 of
        true -> 2;
        false -> T
    end.
