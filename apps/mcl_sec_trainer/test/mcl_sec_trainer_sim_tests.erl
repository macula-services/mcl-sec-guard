%%% @doc Unit tests for the pure sim world: the window arithmetic and
%%% the limits/envelope semantics, mirroring mcl_om 0.37.6. The
%%% conformance test (mcl_sec_trainer_conformance_tests) is the other
%%% half: the same traffic held against the real guard.
-module(mcl_sec_trainer_sim_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---- limits and envelope semantics ----

declare_validates_limits_test() ->
    B = base(),
    ?assertError({mcl_sec_trainer_bad_limits, <<"p">>, {error, {unknown_key, nope}}},
                 mcl_sec_trainer_sim:declare(world(), <<"p">>, B#{nope => 1})),
    ?assertError({mcl_sec_trainer_bad_limits, <<"p">>, {error, {not_a_positive_integer, window_ms, 0}}},
                 mcl_sec_trainer_sim:declare(world(), <<"p">>, B#{window_ms => 0})),
    ?assertError({mcl_sec_trainer_bad_limits, <<"p">>,
                  {error, {per_caller_above_global, 1000, 100}}},
                 mcl_sec_trainer_sim:declare(world(), <<"p">>, B#{per_caller_max => 1000})),
    ?assertError({mcl_sec_trainer_bad_limits, <<"p">>, {error, {unknown_key, nope}}},
                 mcl_sec_trainer_sim:declare(world(), <<"p">>,
                                             B#{envelope => #{nope => #{min => 1, max => 2}}})).

undeclared_procedure_reads_the_defaults_test() ->
    #{limits := Limits, envelope := Envelope} =
        mcl_sec_trainer_sim:get(world(), <<"never-declared">>),
    ?assertEqual(mcl_sec_trainer_sim:defaults(), Limits),
    ?assertEqual(#{}, Envelope).

redeclare_with_the_same_base_keeps_overrides_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, base()),
    {ok, W1} = mcl_sec_trainer_sim:apply(W0, <<"p">>, #{per_caller_max => 5},
                                         #{tier => guardian, caller => <<"g">>}),
    W2 = mcl_sec_trainer_sim:declare(W1, <<"p">>, base()),
    #{limits := Limits} = mcl_sec_trainer_sim:get(W2, <<"p">>),
    ?assertEqual(5, maps:get(per_caller_max, Limits)).

guardian_set_is_envelope_clamped_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, base()),
    {ok, W1} = mcl_sec_trainer_sim:apply(W0, <<"p">>, #{per_caller_max => 7},
                                         #{tier => guardian, caller => <<"g">>}),
    #{limits := Limits} = mcl_sec_trainer_sim:get(W1, <<"p">>),
    ?assertEqual(7, maps:get(per_caller_max, Limits)),
    ?assertEqual({error, {envelope_exceeded, per_caller_max, 11}},
                 mcl_sec_trainer_sim:apply(W0, <<"p">>, #{per_caller_max => 11},
                                           #{tier => guardian})),
    ?assertEqual({error, {envelope_exceeded, window_ms, 5000}},
                 mcl_sec_trainer_sim:apply(W0, <<"p">>, #{window_ms => 5000},
                                           #{tier => guardian})),
    ?assertEqual({error, envelope_operator_only},
                 mcl_sec_trainer_sim:apply(W0, <<"p">>,
                                           #{envelope => #{per_caller_max => #{min => 1, max => 99}}},
                                           #{tier => guardian})),
    ?assertEqual({error, {unknown_procedure, <<"q">>}},
                 mcl_sec_trainer_sim:apply(W0, <<"q">>, #{per_caller_max => 5},
                                           #{tier => guardian})).

operator_set_may_move_the_envelope_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, base()),
    {ok, W1} = mcl_sec_trainer_sim:apply(
                 W0, <<"p">>,
                 #{per_caller_max => 20,
                   envelope => #{per_caller_max => #{min => 1, max => 30}}},
                 #{tier => operator, caller => <<"human">>}),
    #{limits := Limits, envelope := Envelope} = mcl_sec_trainer_sim:get(W1, <<"p">>),
    ?assertEqual(20, maps:get(per_caller_max, Limits)),
    ?assertEqual(#{min => 1, max => 30}, maps:get(per_caller_max, Envelope)),
    ?assertEqual({error, {envelope_exceeded, per_caller_max, 31}},
                 mcl_sec_trainer_sim:apply(W1, <<"p">>, #{per_caller_max => 31},
                                           #{tier => guardian})).

reset_returns_to_the_declared_base_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, base()),
    {ok, W1} = mcl_sec_trainer_sim:apply(W0, <<"p">>, #{per_caller_max => 3},
                                         #{tier => guardian}),
    {ok, W2} = mcl_sec_trainer_sim:reset(W1, <<"p">>),
    #{limits := Limits} = mcl_sec_trainer_sim:get(W2, <<"p">>),
    ?assertEqual(10, maps:get(per_caller_max, Limits)).

changed_set_records_an_audit_entry_and_unchanged_does_not_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, base()),
    {ok, W1} = mcl_sec_trainer_sim:apply(W0, <<"p">>, #{per_caller_max => 6},
                                         #{tier => guardian, caller => <<"node-id">>}),
    Audit1 = maps:get(audit, mcl_sec_trainer_sim:stats(W1, <<"p">>)),
    ?assertEqual(1, length(Audit1)),
    [Change] = Audit1,
    ?assertEqual(guardian, maps:get(tier, Change)),
    ?assertEqual(<<"6e6f64652d6964">>, maps:get(caller, Change)),
    ?assertEqual(10, maps:get(per_caller_max, maps:get(limits, maps:get(before, Change)))),
    ?assertEqual(6, maps:get(per_caller_max, maps:get(limits, maps:get('after', Change)))),
    {ok, W2} = mcl_sec_trainer_sim:apply(W1, <<"p">>, #{per_caller_max => 6},
                                         #{tier => guardian, caller => <<"node-id">>}),
    ?assertEqual(1, length(maps:get(audit, mcl_sec_trainer_sim:stats(W2, <<"p">>)))).

validation_rules_test() ->
    ?assertEqual({error, {unknown_key, nope}},
                 mcl_sec_trainer_sim:validate_limits(#{nope => 1})),
    ?assertEqual({error, {not_a_positive_integer, window_ms, -1}},
                 mcl_sec_trainer_sim:validate_limits(
                   #{window_ms => -1, per_caller_max => 1, global_max => 2})),
    ?assertEqual({error, {per_caller_above_global, 9, 8}},
                 mcl_sec_trainer_sim:validate_limits(#{per_caller_max => 9, global_max => 8})),
    ?assertEqual({error, {not_a_map, [1]}},
                 mcl_sec_trainer_sim:validate_limits([1])),
    ?assertEqual({error, {unknown_key, nope}},
                 mcl_sec_trainer_sim:validate_envelope(
                   #{nope => #{min => 1, max => 2}})),
    ?assertEqual({error, {bad_envelope_clamp, per_caller_max, #{min => 9, max => 2}}},
                 mcl_sec_trainer_sim:validate_envelope(
                   #{per_caller_max => #{min => 9, max => 2}})).

%% ---- the call stages ----

oversized_payloads_are_denied_before_the_rate_counter_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, base()),
    {{deny, payload_too_large}, W1} =
        mcl_sec_trainer_sim:call(W0, <<"p">>, <<"c1">>, big()),
    Stats = mcl_sec_trainer_sim:stats(W1, <<"p">>),
    ?assertEqual(1, maps:get(denied_size, Stats)),
    ?assertEqual(0, maps:get(denied_rate, Stats)),
    ?assertEqual(0, maps:get(global_count, Stats)),
    ?assertEqual(0, maps:get(distinct_callers, Stats)).

rate_stage_enforces_the_per_caller_budget_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, base()),
    {Verdicts, W1} = calls(W0, <<"p">>, <<"c1">>, small(), 11),
    ?assertEqual(lists:duplicate(10, allow) ++ [{deny, rate_limited}], Verdicts),
    Stats = mcl_sec_trainer_sim:stats(W1, <<"p">>),
    ?assertEqual(1, maps:get(denied_rate, Stats)),
    ?assertEqual(1, maps:get(callers_over_limit, Stats)),
    ?assertEqual(0, maps:get(global_count, Stats)),
    ?assertEqual(1, maps:get(distinct_callers, Stats)).

the_global_bucket_takes_the_shared_budget_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, base()),
    {Verdicts, W1} = calls(W0, <<"p">>, '$global', small(), 101),
    ?assertEqual(lists:duplicate(100, allow) ++ [{deny, rate_limited}], Verdicts),
    Stats = mcl_sec_trainer_sim:stats(W1, <<"p">>),
    %% The real bucket_check counts the denied call too — the bucket
    %% reads 101 after the refusal.
    ?assertEqual(101, maps:get(global_count, Stats)),
    ?assertEqual(1, maps:get(denied_rate, Stats)).

distinct_bound_denies_new_callers_only_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, tight_distinct()),
    %% Three named callers fit under the bound of 3...
    {V1, W1} = calls(W0, <<"p">>, <<"a">>, small(), 1),
    {V2, W2} = calls(W1, <<"p">>, <<"b">>, small(), 1),
    {V3, W3} = calls(W2, <<"p">>, <<"c">>, small(), 1),
    %% ...a fourth NEW caller is denied before its bucket exists...
    {V4, W4} = calls(W3, <<"p">>, <<"d">>, small(), 1),
    %% ...and a caller the window already knows keeps its budget.
    {V5, _W5} = calls(W4, <<"p">>, <<"a">>, small(), 9),
    ?assertEqual([allow], V1),
    ?assertEqual([allow], V2),
    ?assertEqual([allow], V3),
    ?assertEqual([{deny, rate_limited}], V4),
    ?assertEqual(lists:duplicate(9, allow), V5).

the_global_bucket_bumps_the_distinct_counter_like_the_real_one_test() ->
    %% mcl_om 0.37.6's bucket_check bumps the window's distinct counter
    %% when ANY bucket is created, '$global' included — the sim mirrors
    %% the real behaviour exactly, quirk and all.
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, tight_distinct()),
    {_, W1} = calls(W0, <<"p">>, '$global', small(), 1),
    {_, W2} = calls(W1, <<"p">>, <<"a">>, small(), 1),
    {_, W3} = calls(W2, <<"p">>, <<"b">>, small(), 1),
    {V4, _W4} = calls(W3, <<"p">>, <<"c">>, small(), 1),
    {V5, _W5} = calls(W3, <<"p">>, <<"c2">>, small(), 1),
    ?assertEqual([{deny, rate_limited}], V4),
    ?assertEqual([{deny, rate_limited}], V5).

denial_counters_are_per_window_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, base()),
    {_, W1} = calls(W0, <<"p">>, <<"c1">>, small(), 11),
    ?assertEqual(1, maps:get(denied_rate, mcl_sec_trainer_sim:stats(W1, <<"p">>))),
    W2 = mcl_sec_trainer_sim:advance(W1, <<"p">>),
    ?assertEqual(0, maps:get(denied_rate, mcl_sec_trainer_sim:stats(W2, <<"p">>))),
    {_, W3} = calls(W2, <<"p">>, <<"c1">>, small(), 11),
    ?assertEqual(1, maps:get(denied_rate, mcl_sec_trainer_sim:stats(W3, <<"p">>))).

top_callers_are_sorted_hex_encoded_and_bounded_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"p">>, base()),
    %% 12 callers, counts 1..12: only the top ten survive, heaviest
    %% first, ids hex-encoded.
    W1 = lists:foldl(
           fun({Caller, Count}, W) ->
                   {_, WAcc} = calls(W, <<"p">>, Caller, small(), Count),
                   WAcc
           end, W0, [{<<I>>, I + 1} || I <- lists:seq(0, 11)]),
    Top = maps:get(top_callers, mcl_sec_trainer_sim:stats(W1, <<"p">>)),
    ?assertEqual(10, length(Top)),
    ?assertEqual(#{caller => <<"0b">>, count => 12}, hd(Top)),
    [First | Rest] = Top,
    Counts = [maps:get(count, Entry) || Entry <- [First | Rest]],
    ?assertEqual(lists:reverse(lists:sort(Counts)), Counts),
    ?assertEqual(<<"0b">>, maps:get(caller, First)).

windows_advance_per_procedure_test() ->
    W0 = mcl_sec_trainer_sim:declare(world(), <<"a">>, base()),
    W1 = mcl_sec_trainer_sim:declare(W0, <<"b">>, base()),
    ?assertEqual(0, mcl_sec_trainer_sim:current_window(W1, <<"a">>)),
    W2 = mcl_sec_trainer_sim:advance(W1, <<"a">>),
    ?assertEqual(1, mcl_sec_trainer_sim:current_window(W2, <<"a">>)),
    ?assertEqual(0, mcl_sec_trainer_sim:current_window(W2, <<"b">>)).

%% ---- helpers ----

world() ->
    mcl_sec_trainer_sim:new().

base() ->
    mcl_sec_trainer_scenarios:limits(calm).

tight_distinct() ->
    B = base(),
    maps:merge(B, #{max_distinct_callers => 3,
                    envelope => maps:merge(maps:get(envelope, B),
                                           #{max_distinct_callers => #{min => 1, max => 3}})}).

small() ->
    binary:copy(<<0>>, 256).

big() ->
    binary:copy(<<1>>, 8192).

calls(World, Proc, Caller, Payload, N) ->
    calls_loop(World, Proc, Caller, Payload, N, []).

calls_loop(World, _Proc, _Caller, _Payload, 0, Acc) ->
    {lists:reverse(Acc), World};
calls_loop(World, Proc, Caller, Payload, N, Acc) ->
    {Verdict, W1} = mcl_sec_trainer_sim:call(World, Proc, Caller, Payload),
    calls_loop(W1, Proc, Caller, Payload, N - 1, [Verdict | Acc]).
