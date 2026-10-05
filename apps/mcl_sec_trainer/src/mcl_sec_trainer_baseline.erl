%%% @doc The incumbent scored: the P0 placeholder rule, driven in the
%%% simulator exactly as the live loop drives it.
%%%
%%% The baseline every genome must beat (PLAN_AUTONOMOUS_GUARDIAN.md,
%%% "The first build", step 2). The rule is mcl_sec_guard_proposer_rule,
%%% the deterministic timidity that already taught its lesson live (the
%%% 449 probe proposals of 2026-10-04/05): a window that saw denials
%%% proposes lowering `per_caller_max' to the over-limit count, and
%%% proposes nothing else, ever — including nothing that would ever
%%% return a tightened limit to baseline. The sim's stats become the
%%% alert-fact shape the rule matches on, and its proposal becomes the
%%% guardian-tier move the episode applies.
-module(mcl_sec_trainer_baseline).

-export([policy/1, run/0, run/1]).

%% @doc The incumbent as an episode policy: none on a quiet window,
%% `#{per_caller_max => max(over_limit, 1)}' on a hot one.
-spec policy(map()) -> none | map().
policy(#{proc := Proc, stats := Stats}) ->
    Limits = maps:get(limits, Stats),
    Fact = #{procedure => Proc,
             window_start_ms => maps:get(current_window, Stats),
             denied_rate => maps:get(denied_rate, Stats),
             denied_size => maps:get(denied_size, Stats),
             callers_over_limit => maps:get(callers_over_limit, Stats),
             global_count => maps:get(global_count, Stats),
             global_max => maps:get(global_max, Limits),
             per_caller_max => maps:get(per_caller_max, Limits),
             distinct_callers => maps:get(distinct_callers, Stats),
             top_callers => maps:get(top_callers, Stats)},
    case mcl_sec_guard_proposer_rule:propose(Fact) of
        none -> none;
        Proposal -> maps:get(proposed, Proposal)
    end.

%% @doc The incumbent's report on the whole fixed scenario table, at
%% default length and seed — the baseline numbers every genome must
%% beat, recorded per session.
-spec run() -> [map()].
run() ->
    run(#{}).

%% Opts pass through to mcl_sec_trainer_episode:run/2 (windows, seed,
%% procedure, limits, ...).
-spec run(map()) -> [map()].
run(Opts) ->
    PolicyOpts = Opts#{policy => fun ?MODULE:policy/1, policy_name => incumbent},
    [mcl_sec_trainer_episode:run(Name, PolicyOpts)
     || Name <- mcl_sec_trainer_scenarios:names()].
