%%% @doc The learner stack: the observation vector, the fixed-shape
%%% evaluator, the action mapping, and the sep_cma_es arm's contract.
-module(mcl_sec_trainer_learner_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---- the observation vector ----

the_vector_is_twenty_four_features_test() ->
    ?assertEqual(24, mcl_sec_trainer_features:size()),
    ?assertEqual(24, length(mcl_sec_trainer_features:vector(undefined, undefined))),
    ?assertEqual(lists:duplicate(24, 0.0),
                 mcl_sec_trainer_features:vector(undefined, undefined)).

the_vector_reads_ratios_against_the_limits_test() ->
    Stats = stats(#{denied_rate => 7, denied_size => 2,
                    callers_over_limit => 3, distinct_callers => 9,
                    global_count => 40}),
    [RatePressure, SizePressure, OverLimit, Diversity, Fill | _] =
        mcl_sec_trainer_features:vector(Stats, undefined),
    ?assert(abs(RatePressure - 7 / 100) < 0.0001),
    ?assert(abs(SizePressure - 2 / 100) < 0.0001),
    ?assert(abs(OverLimit - 3 / 64) < 0.0001),
    ?assert(abs(Diversity - 9 / 64) < 0.0001),
    ?assert(abs(Fill - 40 / 100) < 0.0001).

posture_reads_the_envelope_and_defaults_to_neutral_test() ->
    Stats = stats(#{}),
    First12 = lists:sublist(mcl_sec_trainer_features:vector(Stats, undefined), 12),
    [_, _, _, _, _, _, _, _, PerCaller, Global, Size, Diversity] = First12,
    %% declared per_caller 10 in envelope [1, 10]: (10-1)/9 = 1.0
    ?assert(abs(PerCaller - 1.0) < 0.0001),
    ?assert(abs(Global - 1.0) < 0.0001),
    ?assert(abs(Size - (4096 - 1024) / (65536 - 1024)) < 0.0001),
    ?assert(abs(Diversity - (64 - 8) / (64 - 8)) < 0.0001),
    %% a key the envelope does not cover reads neutral
    Bare0 = stats(#{}),
    Bare = Bare0#{envelope := maps:remove(max_distinct_callers,
                                          maps:get(envelope, Bare0))},
    BareVector = mcl_sec_trainer_features:vector(Bare, undefined),
    ?assertEqual(0.5, lists:nth(12, BareVector)).

%% ---- the fixed-shape evaluator ----

the_zero_vector_outputs_the_neutral_half_test() ->
    Zeros = lists:duplicate(mcl_sec_trainer_policy_net:param_count(), 0.0),
    Outputs = mcl_sec_trainer_policy_net:output(
                Zeros, lists:duplicate(mcl_sec_trainer_features:size(), 0.0)),
    ?assertEqual(3, length(Outputs)),
    [?assert(abs(O - 0.5) < 0.0001) || O <- Outputs].

the_net_is_deterministic_and_in_range_test() ->
    Vector = [math:sin(I) / 10 || I <- lists:seq(1, mcl_sec_trainer_policy_net:param_count())],
    Inputs = [math:cos(I) || I <- lists:seq(1, mcl_sec_trainer_features:size())],
    ?assertEqual(mcl_sec_trainer_policy_net:output(Vector, Inputs),
                 mcl_sec_trainer_policy_net:output(Vector, Inputs)),
    [?assert(O > 0 andalso O < 1)
     || O <- mcl_sec_trainer_policy_net:output(Vector, Inputs)].

%% ---- the action mapping ----

the_scalars_map_across_the_envelope_with_deadband_test() ->
    Stats = stats(#{}),
    %% ceiling: per_caller 10 and global 100 are already there, but the
    %% declared size 4096 is below its envelope ceiling — that moves
    ?assertEqual(#{max_payload_external_size => 65536},
                 mcl_sec_trainer_actions:moves(Stats, 1.0, 1.0, 1.0)),
    %% floor: per_caller, global and diversity all move; the size floor
    %% (4096 -> 1024) is inside the 10%-of-range deadband — suppressed
    Moved = mcl_sec_trainer_actions:moves(Stats, 0.0, 0.0, 0.0),
    ?assertEqual(1, maps:get(per_caller_max, Moved)),
    ?assertEqual(10, maps:get(global_max, Moved)),
    ?assertNot(maps:is_key(max_payload_external_size, Moved)),
    ?assertEqual(8, maps:get(max_distinct_callers, Moved)).

window_ms_is_never_moved_test() ->
    Stats = stats(#{}),
    Moved = mcl_sec_trainer_actions:moves(Stats, 0.0, 0.0, 0.0),
    ?assertNot(maps:is_key(window_ms, Moved)).

the_shared_budget_never_sits_below_the_per_caller_one_test() ->
    %% with the scenario envelopes the two map in parallel and never
    %% conflict; craft the conflict: a wide per-caller clamp next to a
    %% narrow global one — the relation is enforced, not assumed
    Crafted = stats(#{}),
    CraftedLimits = (maps:get(limits, Crafted))#{per_caller_max => 50,
                                                 global_max => 15},
    CraftedEnv = (maps:get(envelope, Crafted))#{per_caller_max => #{min => 1, max => 100},
                                                global_max => #{min => 10, max => 20}},
    Stats = Crafted#{limits := CraftedLimits, envelope := CraftedEnv},
    Moved = mcl_sec_trainer_actions:moves(Stats, 1.0, 1.0, 1.0),
    ?assertEqual(20, maps:get(per_caller_max, Moved)),
    ?assertEqual(20, maps:get(global_max, Moved)).

a_move_inside_the_deadband_is_suppressed_test() ->
    %% size maps to ~4895 (t=0.06): 799 from the current 4096, inside
    %% the 6451 deadband — nothing worth moving
    Stats = stats(#{}),
    ?assertEqual(#{}, mcl_sec_trainer_actions:moves(Stats, 1.0, 0.06, 1.0)),
    Moved = mcl_sec_trainer_actions:moves(Stats, 0.7, 1.0, 1.0),
    ?assertEqual(7, maps:get(per_caller_max, Moved)).

%% ---- the genome policy and the learner arm ----

the_genome_policy_returns_a_valid_move_test() ->
    Vector = lists:duplicate(mcl_sec_trainer_policy_net:param_count(), 0.0),
    Policy = mcl_sec_trainer_genome:policy(Vector),
    ?assertEqual(8, byte_size(mcl_sec_trainer_genome:id(Vector))),
    ?assertMatch(<<"genome-", _/binary>>, mcl_sec_trainer_genome:policy_name(Vector)),
    Move = Policy(#{stats => stats(#{}), prev_stats => undefined}),
    ?assert(is_map(Move) orelse Move =:= none),
    Report = mcl_sec_trainer_episode:run(calm, #{policy => Policy,
                                                 policy_name => genome}),
    ?assert(is_float(maps:get(fitness, Report)) orelse maps:get(fitness, Report) =:= rejected).

the_champion_report_has_the_standing_shape_test() ->
    Vector = lists:duplicate(mcl_sec_trainer_policy_net:param_count(), 0.0),
    Report = mcl_sec_trainer_genome:champion_report(Vector, #{windows => 20}),
    ?assertMatch(#{genome_id := _, param_count := _,
                   train := [_ | _], held_out := [[_ | _] | _],
                   summary := #{episodes := _, gate_failures := _}}, Report),
    ?assertEqual(8, length(maps:get(train, Report))),
    ?assertEqual(32, maps:get(episodes, maps:get(summary, Report))).

sep_cma_es_returns_the_learner_contract_test() ->
    Result = mcl_sec_trainer_learner:evolve(
               #{scenarios => [calm], max_generations => 2,
                 lambda => 8, init_sigma => 0.5}),
    ?assertMatch(#{best := _, fitness := _, generations := _,
                   evaluations := _, reason := _}, Result),
    ?assert(is_float(maps:get(fitness, Result))).

suite_fitness_is_a_float_and_rejection_scores_low_test() ->
    Vector = lists:duplicate(mcl_sec_trainer_policy_net:param_count(), 0.0),
    Fitness = mcl_sec_trainer_learner:suite_fitness(Vector, [calm]),
    ?assert(is_float(Fitness)),
    ?assert(Fitness >= -1.0 andalso Fitness =< 1.0).

%% ---- helpers ----

%% The base stats, merged with the caller's overrides.
stats(Overrides) ->
    maps:merge(base_stats(), Overrides).

base_stats() ->
    #{limits => #{max_payload_external_size => 4096,
                  window_ms => 10000,
                  per_caller_max => 10,
                  global_max => 100,
                  max_distinct_callers => 64},
      envelope => #{per_caller_max => #{min => 1, max => 10},
                    global_max => #{min => 10, max => 100},
                    max_payload_external_size => #{min => 1024, max => 65536},
                    max_distinct_callers => #{min => 8, max => 64}},
      denied_rate => 0, denied_size => 0,
      callers_over_limit => 0, distinct_callers => 0,
      global_count => 0, global_max => 100,
      top_callers => [],
      audit => []}.
